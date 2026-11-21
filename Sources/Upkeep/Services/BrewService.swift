import Foundation
import Observation

public struct BrewOperationLog: Codable, Sendable, Equatable {
    public let command: String
    public let output: String
    public let succeeded: Bool
    public let exitCode: Int32
    public let timestamp: Date

    public init(command: String, output: String, succeeded: Bool, exitCode: Int32, timestamp: Date = Date()) {
        self.command = command
        self.output = output
        self.succeeded = succeeded
        self.exitCode = exitCode
        self.timestamp = timestamp
    }
}

@MainActor
@Observable
public final class BrewLogStore {
    public static let shared = BrewLogStore()
    public private(set) var lastLog: BrewOperationLog?

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.local.Upkeep/last_brew_log.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(BrewOperationLog.self, from: data) {
            self.lastLog = decoded
        }
    }

    public func record(command: String, stdout: String, stderr: String, exitCode: Int32) {
        let cleanOut = CLIExecutor.stripANSI(stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanErr = CLIExecutor.stripANSI(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        if cleanOut.isEmpty && cleanErr.isEmpty {
            combined = exitCode == 0 ? "Command completed with no output." : "Command failed with exit code \(exitCode)."
        } else if cleanErr.isEmpty {
            combined = cleanOut
        } else if cleanOut.isEmpty {
            combined = cleanErr
        } else {
            combined = cleanOut + "\n\n" + cleanErr
        }
        let entry = BrewOperationLog(
            command: command,
            output: combined,
            succeeded: exitCode == 0,
            exitCode: exitCode,
            timestamp: Date()
        )
        self.lastLog = entry
        persist(entry)
    }

    public func clear() {
        self.lastLog = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private func persist(_ entry: BrewOperationLog) {
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

public struct BrewPackageItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let description: String
    public let version: String
    public let isCask: Bool
    public let isInstalled: Bool
    public let isOutdated: Bool
    public let isPinned: Bool
    public let homepage: String

    public init(
        name: String,
        description: String,
        version: String,
        isCask: Bool,
        isInstalled: Bool = false,
        isOutdated: Bool = false,
        isPinned: Bool = false,
        homepage: String = ""
    ) {
        self.id = "\(isCask ? "cask" : "formula"):\(name)"
        self.name = name
        self.description = description
        self.version = version
        self.isCask = isCask
        self.isInstalled = isInstalled
        self.isOutdated = isOutdated
        self.isPinned = isPinned
        self.homepage = homepage
    }
}

/// Fast fuzzy matcher delegating to UpkeepEngine (Rust nucleo when linked, zero-alloc Swift otherwise).
public enum SwiftFuzzyMatcher {
    public static func score(query: String, candidate: String) -> Int? {
        UpkeepEngine.scoreFuzzy(query: query, candidate: candidate)
    }
}

public actor BrewService {
    public static let shared = BrewService()
    private var catalog: [BrewPackageItem] = []
    private var catalogLookup: [String: BrewPackageItem] = [:]
    private var lastLoadedAt: Date?
    private var inFlightLoadTask: Task<[BrewPackageItem], Error>?

    // Cached full Homebrew API catalog (~15k formulae + casks) for sub-ms remote search without spawning Ruby `brew search`
    private var remoteCatalog: [BrewPackageItem] = []
    private var lastRemoteCatalogFetch: Date?
    private var inFlightRemoteCatalogTask: Task<[BrewPackageItem], Never>?

    #if USE_RUST_UPKEEP_CORE
    private let rustLocalIndex = UpkeepEngine.RustBrewIndex()
    private let rustRemoteIndex = UpkeepEngine.RustBrewIndex()
    #endif

    private static let brewEnv: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ENV_HINTS": "1"
    ]

    private static let cacheDirURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.local.Upkeep/BrewAPI", isDirectory: true)
    }()

    public static func isInstalled() -> Bool {
        CLIExecutor.resolveBinary("brew") != nil
    }

    /// Extracts the JSON object payload even if Homebrew prints leading banner lines before `{` or trailing notes after `}`.
    public static func extractJSONObject(from raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end else { return nil }
        return Data(String(raw[start...end]).utf8)
    }

    /// Fast direct filesystem scan of `/opt/homebrew/Cellar`, `Caskroom`, and `var/homebrew/pinned`.
    public static func scanInstalledDirectories(prefix: String = "/opt/homebrew") -> [BrewPackageItem] {
        let fm = FileManager.default
        let resolvedPrefix = fm.fileExists(atPath: prefix) ? prefix : "/usr/local"
        let pinnedDir = (resolvedPrefix as NSString).appendingPathComponent("var/homebrew/pinned")
        let pinnedNames = Set(((try? fm.contentsOfDirectory(atPath: pinnedDir)) ?? []).filter { !$0.hasPrefix(".") })

        var items: [BrewPackageItem] = []
        for (subdir, isCask) in [("Cellar", false), ("Caskroom", true)] {
            let root = (resolvedPrefix as NSString).appendingPathComponent(subdir)
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in names where !name.hasPrefix(".") {
                let pkgDir = (root as NSString).appendingPathComponent(name)
                let versions = (try? fm.contentsOfDirectory(atPath: pkgDir))?.filter { !$0.hasPrefix(".") } ?? []
                let version = versions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.last ?? ""
                items.append(BrewPackageItem(
                    name: name,
                    description: isCask ? "Installed Cask" : "Installed Formula",
                    version: version,
                    isCask: isCask,
                    isInstalled: true,
                    isOutdated: false,
                    isPinned: !isCask && pinnedNames.contains(name),
                    homepage: ""
                ))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Matches an installed `.app` bundle against Homebrew's local Caskroom without spawning Ruby.
    public static func findInstalledCask(forAppName appName: String, appPath: String) -> String? {
        let fm = FileManager.default
        let prefix = fm.fileExists(atPath: "/opt/homebrew/Caskroom") ? "/opt/homebrew" : "/usr/local"
        let caskroom = (prefix as NSString).appendingPathComponent("Caskroom")
        guard let tokens = try? fm.contentsOfDirectory(atPath: caskroom) else { return nil }

        let appBundleName = (appPath as NSString).lastPathComponent
        let normalizedApp = normalizeToken(appName)
        var fallbackMatch: String? = nil

        for token in tokens where !token.hasPrefix(".") {
            let tokenDir = (caskroom as NSString).appendingPathComponent(token)
            if let entries = try? fm.contentsOfDirectory(atPath: tokenDir) {
                for entry in entries where !entry.hasPrefix(".") {
                    let versionDir = (tokenDir as NSString).appendingPathComponent(entry)
                    let directApp = (versionDir as NSString).appendingPathComponent(appBundleName)
                    if fm.fileExists(atPath: directApp) {
                        return token
                    }
                }
            }
            let metaDir = (tokenDir as NSString).appendingPathComponent(".metadata")
            if let enumerator = fm.enumerator(atPath: metaDir) {
                for case let rel as String in enumerator where rel.hasSuffix(".rb") || rel.hasSuffix(".json") {
                    let filePath = (metaDir as NSString).appendingPathComponent(rel)
                    if let content = try? String(contentsOfFile: filePath, encoding: .utf8),
                       content.localizedCaseInsensitiveContains(appBundleName) {
                        return token
                    }
                }
            }
            if fallbackMatch == nil && normalizeToken(token) == normalizedApp {
                fallbackMatch = token
            }
        }
        return fallbackMatch
    }

    private static func normalizeToken(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func updateLocalCatalog(_ items: [BrewPackageItem]) {
        catalog = items
        var map: [String: BrewPackageItem] = [:]
        map.reserveCapacity(items.count)
        for item in items {
            map[item.id] = item
        }
        catalogLookup = map
        lastLoadedAt = Date()
        #if USE_RUST_UPKEEP_CORE
        rustLocalIndex.load(items: items)
        #endif
    }

    /// Loads installed and outdated packages with 30s TTL caching and in-flight task coalescing
    /// to prevent redundant Ruby `brew` subprocess spawns.
    public func loadInstalledAndOutdated(forceRefresh: Bool = false) async throws -> [BrewPackageItem] {
        if !forceRefresh,
           !catalog.isEmpty,
           let last = lastLoadedAt,
           Date().timeIntervalSince(last) < 30 {
            return catalog
        }

        if !forceRefresh, let existing = inFlightLoadTask {
            return try await existing.value
        }

        let task = Task<[BrewPackageItem], Error> {
            async let installedTask = CLIExecutor.run(
                binary: "brew",
                arguments: ["info", "--json=v2", "--installed"],
                environment: Self.brewEnv
            )
            async let outdatedTask = CLIExecutor.run(
                binary: "brew",
                arguments: ["outdated", "--json=v2"],
                environment: Self.brewEnv
            )

            var outdatedNames = Set<String>()
            if let outRes = try? await outdatedTask,
               outRes.succeeded,
               let outData = Self.extractJSONObject(from: outRes.stdout),
               let outObj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] {
                if let f = outObj["formulae"] as? [[String: Any]] {
                    for item in f {
                        if let name = item["name"] as? String { outdatedNames.insert(name) }
                    }
                }
                if let c = outObj["casks"] as? [[String: Any]] {
                    for item in c {
                        if let token = (item["token"] as? String) ?? (item["name"] as? String) {
                            outdatedNames.insert(token)
                        }
                    }
                }
            }

            if let installedRes = try? await installedTask,
               installedRes.succeeded,
               let jsonData = Self.extractJSONObject(from: installedRes.stdout),
               let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                var items: [BrewPackageItem] = []
                if let formulae = root["formulae"] as? [[String: Any]] {
                    for f in formulae {
                        let name = f["name"] as? String ?? ""
                        let fullName = f["full_name"] as? String ?? ""
                        let desc = f["desc"] as? String ?? ""
                        let versions = f["versions"] as? [String: Any]
                        let version = versions?["stable"] as? String ?? ""
                        let pinned = f["pinned"] as? Bool ?? false
                        let homepage = f["homepage"] as? String ?? ""
                        let isOutdated = outdatedNames.contains(name) || outdatedNames.contains(fullName) || (f["outdated"] as? Bool == true)
                        items.append(BrewPackageItem(
                            name: name,
                            description: desc,
                            version: version,
                            isCask: false,
                            isInstalled: true,
                            isOutdated: isOutdated,
                            isPinned: pinned,
                            homepage: homepage
                        ))
                    }
                }
                if let casks = root["casks"] as? [[String: Any]] {
                    for c in casks {
                        let token = c["token"] as? String ?? ""
                        let desc = c["desc"] as? String ?? ""
                        let version = c["version"] as? String ?? ""
                        let homepage = c["homepage"] as? String ?? ""
                        let isOutdated = outdatedNames.contains(token) || (c["outdated"] as? Bool == true)
                        items.append(BrewPackageItem(
                            name: token,
                            description: desc,
                            version: version,
                            isCask: true,
                            isInstalled: true,
                            isOutdated: isOutdated,
                            isPinned: false,
                            homepage: homepage
                        ))
                    }
                }
                if !items.isEmpty {
                    return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }

            return Self.scanInstalledDirectories()
        }

        inFlightLoadTask = task
        do {
            let items = try await task.value
            inFlightLoadTask = nil
            updateLocalCatalog(items)
            return items
        } catch {
            inFlightLoadTask = nil
            throw error
        }
    }

    // MARK: - Fast Disk-Cached Homebrew Public JSON API Index

    private struct APIFormula: Decodable {
        struct Versions: Decodable { let stable: String? }
        let name: String
        let desc: String?
        let homepage: String?
        let versions: Versions?
    }

    private struct APICask: Decodable {
        let token: String
        let desc: String?
        let version: String?
        let homepage: String?
    }

    private static func fetchOrLoadCachedJSON(urlString: String, cacheFileName: String) async -> Data? {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDirURL, withIntermediateDirectories: true)
        let dataURL = cacheDirURL.appendingPathComponent(cacheFileName)
        let etagURL = cacheDirURL.appendingPathComponent(cacheFileName + ".etag")

        // Use on-disk cache immediately if fresher than 6 hours
        if let attrs = try? fm.attributesOfItem(atPath: dataURL.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < 6 * 3600,
           let cached = try? Data(contentsOf: dataURL), !cached.isEmpty {
            return cached
        }

        guard let url = URL(string: urlString) else {
            return try? Data(contentsOf: dataURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let etag = try? String(contentsOf: etagURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 304, let cached = try? Data(contentsOf: dataURL) {
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dataURL.path)
                    return cached
                }
                if (200..<300).contains(http.statusCode), !data.isEmpty {
                    try? data.write(to: dataURL, options: .atomic)
                    if let etag = http.value(forHTTPHeaderField: "ETag") {
                        try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
                    }
                    return data
                }
            }
        } catch {
            // Fall through to stale disk cache if offline
        }

        return try? Data(contentsOf: dataURL)
    }

    private func ensureRemoteCatalogLoaded() async -> [BrewPackageItem] {
        if !remoteCatalog.isEmpty,
           let last = lastRemoteCatalogFetch,
           Date().timeIntervalSince(last) < 6 * 3600 {
            return remoteCatalog
        }

        if let inFlight = inFlightRemoteCatalogTask {
            return await inFlight.value
        }

        let localMap = catalogLookup
        let task = Task<[BrewPackageItem], Never> {
            async let formulaeData = Self.fetchOrLoadCachedJSON(
                urlString: "https://formulae.brew.sh/api/formula.json",
                cacheFileName: "formula.json"
            )
            async let casksData = Self.fetchOrLoadCachedJSON(
                urlString: "https://formulae.brew.sh/api/cask.json",
                cacheFileName: "cask.json"
            )

            let (fData, cData) = await (formulaeData, casksData)
            var merged: [BrewPackageItem] = []
            merged.reserveCapacity(16_000)
            let decoder = JSONDecoder()

            if let fData, let formulae = try? decoder.decode([APIFormula].self, from: fData) {
                for f in formulae {
                    let key = "formula:\(f.name)"
                    let existing = localMap[key]
                    merged.append(BrewPackageItem(
                        name: f.name,
                        description: f.desc ?? "",
                        version: existing?.version ?? f.versions?.stable ?? "",
                        isCask: false,
                        isInstalled: existing?.isInstalled ?? false,
                        isOutdated: existing?.isOutdated ?? false,
                        isPinned: existing?.isPinned ?? false,
                        homepage: f.homepage ?? existing?.homepage ?? ""
                    ))
                }
            }

            if let cData, let casks = try? decoder.decode([APICask].self, from: cData) {
                for c in casks {
                    let key = "cask:\(c.token)"
                    let existing = localMap[key]
                    merged.append(BrewPackageItem(
                        name: c.token,
                        description: c.desc ?? "",
                        version: existing?.version ?? c.version ?? "",
                        isCask: true,
                        isInstalled: existing?.isInstalled ?? false,
                        isOutdated: existing?.isOutdated ?? false,
                        isPinned: false,
                        homepage: c.homepage ?? existing?.homepage ?? ""
                    ))
                }
            }

            return merged
        }

        inFlightRemoteCatalogTask = task
        let loaded = await task.value
        inFlightRemoteCatalogTask = nil
        if !loaded.isEmpty {
            remoteCatalog = loaded
            lastRemoteCatalogFetch = Date()
            #if USE_RUST_UPKEEP_CORE
            rustRemoteIndex.load(items: loaded)
            #endif
        }
        return loaded
    }

    public func searchRemote(query: String, filterCasks: Bool? = nil) async throws -> [BrewPackageItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fuzzySearchLocal(query: "", filterCasks: filterCasks) }

        // Fast path: search cached Homebrew JSON API in-memory (Rust nucleo when linked, zero-alloc Swift otherwise)
        let apiCatalog = await ensureRemoteCatalogLoaded()
        if !apiCatalog.isEmpty {
            #if USE_RUST_UPKEEP_CORE
            let rustHits = rustRemoteIndex.search(query: trimmed, filterCasks: filterCasks, limit: 80)
            if !rustHits.isEmpty { return rustHits }
            #else
            let hits = scorePool(apiCatalog, query: trimmed, filterCasks: filterCasks, limit: 80)
            if !hits.isEmpty { return hits }
            #endif
        }

        // Offline fallback when API cache is unavailable: shell out to `brew search --desc`
        let result = try await CLIExecutor.run(
            binary: "brew",
            arguments: ["search", "--desc", trimmed],
            environment: Self.brewEnv
        )
        if !result.succeeded {
            return fuzzySearchLocal(query: trimmed, filterCasks: filterCasks)
        }

        var results: [BrewPackageItem] = []
        var isCaskSection = false
        for line in result.stdout.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("==> Formulae") {
                isCaskSection = false
                continue
            }
            if clean.hasPrefix("==> Casks") {
                isCaskSection = true
                continue
            }
            guard let colon = clean.firstIndex(of: ":") else { continue }
            let name = String(clean[..<colon]).trimmingCharacters(in: .whitespaces)
            let desc = String(clean[clean.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let key = "\(isCaskSection ? "cask" : "formula"):\(name)"
            let existing = catalogLookup[key]
            results.append(BrewPackageItem(
                name: name,
                description: desc,
                version: existing?.version ?? "latest",
                isCask: isCaskSection,
                isInstalled: existing?.isInstalled ?? false,
                isOutdated: existing?.isOutdated ?? false,
                isPinned: existing?.isPinned ?? false,
                homepage: existing?.homepage ?? ""
            ))
        }

        let filtered = results.filter { item in
            guard let filterCasks else { return true }
            return item.isCask == filterCasks
        }
        return filtered.isEmpty ? fuzzySearchLocal(query: trimmed, filterCasks: filterCasks) : filtered
    }

    private func scorePool(_ pool: [BrewPackageItem], query: String, filterCasks: Bool?, limit: Int) -> [BrewPackageItem] {
        var scored: [(BrewPackageItem, Int)] = []
        scored.reserveCapacity(min(256, pool.count))
        for item in pool {
            if let filterCasks, item.isCask != filterCasks { continue }
            if let nameScore = UpkeepEngine.scoreFuzzy(query: query, candidate: item.name) {
                scored.append((item, nameScore + 500))
            } else if !item.description.isEmpty,
                      let descScore = UpkeepEngine.scoreFuzzy(query: query, candidate: item.description) {
                scored.append((item, descScore))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(limit).map(\.0))
    }

    public func fuzzySearchLocal(query: String, filterCasks: Bool?) -> [BrewPackageItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            guard let filterCasks else { return catalog }
            return catalog.filter { $0.isCask == filterCasks }
        }
        #if USE_RUST_UPKEEP_CORE
        return rustLocalIndex.search(query: trimmed, filterCasks: filterCasks, limit: 120)
        #else
        return scorePool(catalog, query: trimmed, filterCasks: filterCasks, limit: 120)
        #endif
    }

    public func install(name: String, isCask: Bool) async throws -> String {
        var args = ["install"]
        if isCask { args.append("--cask") }
        args.append(name)
        let cmd = "brew " + args.joined(separator: " ")
        let res = try await CLIExecutor.run(binary: "brew", arguments: args, environment: Self.brewEnv)
        await BrewLogStore.shared.record(command: cmd, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        _ = try? await loadInstalledAndOutdated(forceRefresh: true)
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func uninstall(name: String, isCask: Bool) async throws -> String {
        var args = ["uninstall"]
        if isCask { args.append("--cask") }
        args.append(name)
        let cmd = "brew " + args.joined(separator: " ")
        let res = try await CLIExecutor.run(binary: "brew", arguments: args, environment: Self.brewEnv)
        await BrewLogStore.shared.record(command: cmd, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        let updated = catalog.filter { !($0.name == name && $0.isCask == isCask) }
        updateLocalCatalog(updated)
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func upgrade(name: String? = nil) async throws -> String {
        var args = ["upgrade"]
        if let name { args.append(name) }
        let cmd = "brew " + args.joined(separator: " ")
        let res = try await CLIExecutor.run(binary: "brew", arguments: args, environment: Self.brewEnv)
        await BrewLogStore.shared.record(command: cmd, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        _ = try? await loadInstalledAndOutdated(forceRefresh: true)
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func pin(name: String) async throws -> String {
        let cmd = "brew pin \(name)"
        let res = try await CLIExecutor.run(binary: "brew", arguments: ["pin", name], environment: Self.brewEnv)
        await BrewLogStore.shared.record(command: cmd, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        _ = try? await loadInstalledAndOutdated(forceRefresh: true)
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func unpin(name: String) async throws -> String {
        let cmd = "brew unpin \(name)"
        let res = try await CLIExecutor.run(binary: "brew", arguments: ["unpin", name], environment: Self.brewEnv)
        await BrewLogStore.shared.record(command: cmd, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        _ = try? await loadInstalledAndOutdated(forceRefresh: true)
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func updateBrew() async throws -> String {
        let cmd = "brew update"
        let res = try await CLIExecutor.run(binary: "brew", arguments: ["update"], environment: Self.brewEnv)
        await BrewLogStore.shared.record(command: cmd, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func runDoctor() async throws -> String {
        let cmd = "brew doctor"
        let res = try await CLIExecutor.run(binary: "brew", arguments: ["doctor"], environment: Self.brewEnv)
        await BrewLogStore.shared.record(command: cmd, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        return CLIExecutor.stripANSI(res.stdout + "\n" + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
