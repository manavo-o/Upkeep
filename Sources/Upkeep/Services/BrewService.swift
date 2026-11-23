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
    public private(set) var isRunning: Bool = false
    public private(set) var activeCommand: String? = nil
    public private(set) var liveStatusLine: String? = nil

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.local.Upkeep/last_brew_log.json")
    }()

    private init() {
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(BrewOperationLog.self, from: data) else {
                return
            }
            await MainActor.run {
                if BrewLogStore.shared.lastLog == nil {
                    BrewLogStore.shared.lastLog = decoded
                }
            }
        }
    }

    private var liveOutputBuffer: String = ""
    private var pendingLiveLines: [String] = []
    private var liveFlushTask: Task<Void, Never>?

    public func beginLive(command: String) {
        liveFlushTask?.cancel()
        liveFlushTask = nil
        pendingLiveLines.removeAll(keepingCapacity: true)
        liveOutputBuffer = ""
        self.isRunning = true
        self.activeCommand = command
        self.liveStatusLine = "Starting `\(command)`…"
        self.lastLog = BrewOperationLog(
            command: command,
            output: "Running `\(command)`…",
            succeeded: true,
            exitCode: 0,
            timestamp: Date()
        )
    }

    public func appendLiveLine(_ line: String) {
        guard lastLog != nil else { return }
        let cleanedLine = CLIExecutor.stripANSI(line).trimmingCharacters(in: .whitespacesAndNewlines)
        pendingLiveLines.append(cleanedLine.isEmpty ? line : cleanedLine)
        if liveFlushTask == nil {
            liveFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled, let self else { return }
                self.flushPendingLiveLines()
            }
        }
    }

    private static let maxLiveBufferUTF8Bytes = 64 * 1024

    private func flushPendingLiveLines() {
        liveFlushTask = nil
        guard !pendingLiveLines.isEmpty, let current = lastLog else { return }
        if let latest = pendingLiveLines.last(where: { !$0.isEmpty }) {
            self.liveStatusLine = latest
        }
        let batch = pendingLiveLines.joined(separator: "\n")
        pendingLiveLines.removeAll(keepingCapacity: true)
        if liveOutputBuffer.isEmpty {
            liveOutputBuffer = batch
        } else {
            liveOutputBuffer.append("\n")
            liveOutputBuffer.append(batch)
        }
        // Cap live buffer to the latest 64 KB so long upgrades never bloat RAM or SwiftUI diffs.
        if liveOutputBuffer.utf8.count > Self.maxLiveBufferUTF8Bytes {
            let dropCount = liveOutputBuffer.utf8.count - Self.maxLiveBufferUTF8Bytes
            let cutIdx = liveOutputBuffer.utf8.index(liveOutputBuffer.utf8.startIndex, offsetBy: dropCount)
            let trimmed = String(liveOutputBuffer[cutIdx...])
            if let firstNL = trimmed.firstIndex(of: "\n") {
                liveOutputBuffer = "… (earlier output truncated)\n" + String(trimmed[trimmed.index(after: firstNL)...])
            } else {
                liveOutputBuffer = trimmed
            }
        }
        self.lastLog = BrewOperationLog(
            command: current.command,
            output: liveOutputBuffer,
            succeeded: current.succeeded,
            exitCode: current.exitCode,
            timestamp: current.timestamp
        )
    }

    public func record(command: String, stdout: String, stderr: String, exitCode: Int32) {
        liveFlushTask?.cancel()
        liveFlushTask = nil
        pendingLiveLines.removeAll()
        liveOutputBuffer = ""
        self.isRunning = false
        self.activeCommand = nil
        self.liveStatusLine = nil
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
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func persist(_ entry: BrewOperationLog) {
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(entry) {
                try? data.write(to: url, options: .atomic)
            }
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

    /// Clean, human-readable version string (trims trailing cask build hashes/UUIDs after commas).
    public var displayVersion: String {
        guard !version.isEmpty else { return "" }
        if let comma = version.firstIndex(of: ",") {
            let prefix = String(version[..<comma])
            if !prefix.isEmpty { return prefix }
        }
        return version
    }

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
    private var idleEvictionTask: Task<Void, Never>?

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
        #if USE_RUST_UPKEEP_CORE
        if let rustItems = UpkeepEngine.scanBrewDirs(prefix: prefix) {
            return rustItems
        }
        #endif
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
        // Skip double JSON round-trip when rustRemoteIndex is loaded; keep rustLocalIndex only as offline fallback.
        if rustRemoteIndex.count == 0 {
            rustLocalIndex.load(items: items)
        }
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
            #if USE_RUST_UPKEEP_CORE
            // Fast path: zero Ruby subprocess spawns when Rust API + local Cellar/Caskroom merge succeeds.
            if await self.ensureRemoteCatalogLoaded() {
                if forceRefresh {
                    // 5ms in-place Cellar/Caskroom rescan without re-parsing formula.json/cask.json
                    self.rustRemoteIndex.refreshLocal()
                }
                let fastInstalled = self.rustRemoteIndex.installedPackages()
                if !fastInstalled.isEmpty {
                    return fastInstalled
                }
            }
            #endif

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

    private static var catalogBinURL: URL {
        cacheDirURL.appendingPathComponent("catalog.bin")
    }

    /// Ensures the cached Homebrew JSON API file is fresh on disk without loading 30 MB into Swift RAM.
    private static func ensureCachedJSONFile(urlString: String, cacheFileName: String) async -> (url: URL?, notModified: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDirURL, withIntermediateDirectories: true)
        let dataURL = cacheDirURL.appendingPathComponent(cacheFileName)
        let etagURL = cacheDirURL.appendingPathComponent(cacheFileName + ".etag")

        // Use on-disk cache immediately if fresher than 6 hours
        if let attrs = try? fm.attributesOfItem(atPath: dataURL.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) < 6 * 3600,
           let fileSize = attrs[.size] as? NSNumber, fileSize.intValue > 0 {
            return (dataURL, true)
        }

        guard let url = URL(string: urlString) else {
            return (fm.fileExists(atPath: dataURL.path) ? dataURL : nil, false)
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
                if http.statusCode == 304 {
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dataURL.path)
                    return (fm.fileExists(atPath: dataURL.path) ? dataURL : nil, true)
                }
                if (200..<300).contains(http.statusCode), !data.isEmpty {
                    try? data.write(to: dataURL, options: .atomic)
                    if let etag = http.value(forHTTPHeaderField: "ETag") {
                        try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
                    }
                    return (dataURL, false)
                }
            }
        } catch {
            // Fall through to stale disk cache if offline
        }

        return (fm.fileExists(atPath: dataURL.path) ? dataURL : nil, false)
    }

    /// Pre-warms the 15k-package Rust Homebrew index on demand.
    public func prewarmIfNeeded() async {
        guard Self.isInstalled() else { return }
        cancelIdleEviction()
        _ = await ensureRemoteCatalogLoaded()
    }

    /// Cancels any pending idle-eviction timer (called when the HUD or Homebrew pane becomes active).
    public func cancelIdleEviction() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
    }

    /// Schedules automatic RAM eviction of the 15k-package catalog after `afterSeconds` of inactivity.
    /// Reloading `catalog.bin` takes <5ms on the next open, keeping menu-bar idle RSS near zero.
    public func scheduleIdleEviction(afterSeconds seconds: Int = 120) {
        idleEvictionTask?.cancel()
        idleEvictionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.evictRemoteCatalogIfIdle()
        }
    }

    /// Immediately frees the in-memory 15k Homebrew catalog slab back to the OS.
    public func evictRemoteCatalogIfIdle() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        guard inFlightRemoteCatalogTask == nil else { return }
        #if USE_RUST_UPKEEP_CORE
        rustRemoteIndex.clear()
        rustLocalIndex.clear()
        #endif
        remoteCatalog.removeAll()
        lastRemoteCatalogFetch = nil
    }

    /// Returns true when the remote Homebrew catalog is already warm in memory (zero debounce needed).
    public func hasWarmRemoteIndex() -> Bool {
        #if USE_RUST_UPKEEP_CORE
        if rustRemoteIndex.count > 0 { return true }
        #endif
        return !remoteCatalog.isEmpty
    }

    private func ensureRemoteCatalogLoaded() async -> Bool {
        cancelIdleEviction()
        #if USE_RUST_UPKEEP_CORE
        if rustRemoteIndex.count > 0,
           let last = lastRemoteCatalogFetch,
           Date().timeIntervalSince(last) < 6 * 3600 {
            return true
        }
        #else
        if !remoteCatalog.isEmpty,
           let last = lastRemoteCatalogFetch,
           Date().timeIntervalSince(last) < 6 * 3600 {
            return true
        }
        #endif

        if let inFlight = inFlightRemoteCatalogTask {
            let items = await inFlight.value
            #if USE_RUST_UPKEEP_CORE
            return rustRemoteIndex.count > 0 || !items.isEmpty
            #else
            return !items.isEmpty
            #endif
        }

        let localMap = catalogLookup
        #if USE_RUST_UPKEEP_CORE
        let rustIndex = self.rustRemoteIndex
        #endif

        let task = Task<[BrewPackageItem], Never> {
            #if USE_RUST_UPKEEP_CORE
            let fm = FileManager.default
            let binURL = Self.catalogBinURL
            let hasBinCache = fm.fileExists(atPath: binURL.path)
            // Ultra-fast <5ms cold-start path: load compact binary cache directly into Rust's byte slab.
            if hasBinCache,
               let attrs = try? fm.attributesOfItem(atPath: binURL.path),
               let modDate = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modDate) < 6 * 3600 {
                if rustIndex.loadBinaryCache(path: binURL.path) > 0 {
                    return []
                }
            }
            #endif

            async let formulaeFetch = Self.ensureCachedJSONFile(
                urlString: "https://formulae.brew.sh/api/formula.json",
                cacheFileName: "formula.json"
            )
            async let casksFetch = Self.ensureCachedJSONFile(
                urlString: "https://formulae.brew.sh/api/cask.json",
                cacheFileName: "cask.json"
            )

            let (fRes, cRes) = await (formulaeFetch, casksFetch)

            #if USE_RUST_UPKEEP_CORE
            // If both ETags returned 304 Not Modified and catalog.bin exists, load binary cache directly.
            if fRes.notModified && cRes.notModified && hasBinCache {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: binURL.path)
                if rustIndex.loadBinaryCache(path: binURL.path) > 0 {
                    return []
                }
            }
            // Stream directly from disk into Rust's contiguous byte slab (avoids 30 MB Swift Data spike).
            let loadedCount = rustIndex.loadAPIFiles(formulaePath: fRes.url?.path, casksPath: cRes.url?.path)
            if loadedCount > 0 {
                rustIndex.saveBinaryCache(path: binURL.path)
                return []
            }
            #endif

            let fData = fRes.url.flatMap { try? Data(contentsOf: $0) }
            let cData = cRes.url.flatMap { try? Data(contentsOf: $0) }

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

        #if USE_RUST_UPKEEP_CORE
        if rustRemoteIndex.count > 0 {
            lastRemoteCatalogFetch = Date()
            return true
        }
        #endif

        if !loaded.isEmpty {
            remoteCatalog = loaded
            lastRemoteCatalogFetch = Date()
            return true
        }
        return false
    }

    public func searchRemote(query: String, filterCasks: Bool? = nil) async throws -> [BrewPackageItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fuzzySearchLocal(query: "", filterCasks: filterCasks) }

        // Fast path: search cached Homebrew JSON API in-memory (Rust nucleo when linked, zero-alloc Swift otherwise)
        let hasRemote = await ensureRemoteCatalogLoaded()
        if hasRemote {
            #if USE_RUST_UPKEEP_CORE
            let rustHits = rustRemoteIndex.searchJSON(query: trimmed, filterCasks: filterCasks, limit: 80)
            if !rustHits.isEmpty { return rustHits }
            #else
            let hits = scorePool(remoteCatalog, query: trimmed, filterCasks: filterCasks, limit: 80)
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
        let qLower = query.lowercased()
        var scored: [(BrewPackageItem, Int)] = []
        scored.reserveCapacity(min(256, pool.count))
        for item in pool {
            if let filterCasks, item.isCask != filterCasks { continue }
            let nameLower = item.name.lowercased()
            let installedBonus = item.isInstalled ? 180 : 0

            if nameLower == qLower {
                scored.append((item, 200_000 + installedBonus))
            } else if nameLower.hasPrefix(qLower) {
                let extra = min(4_000, nameLower.count - qLower.count)
                scored.append((item, 120_000 - extra * 10 + installedBonus))
            } else if let range = nameLower.range(of: qLower) {
                let pos = nameLower.distance(from: nameLower.startIndex, to: range.lowerBound)
                let extra = min(500, nameLower.count - qLower.count)
                scored.append((item, 75_000 - min(500, pos) * 40 - extra * 15 + installedBonus))
            } else if let nameScore = UpkeepEngine.scoreFuzzy(query: query, candidate: item.name) {
                scored.append((item, 25_000 + nameScore - min(200, nameLower.count) * 10 + installedBonus))
            } else if !item.description.isEmpty {
                if item.description.localizedCaseInsensitiveContains(query) {
                    let descScore = UpkeepEngine.scoreFuzzy(query: query, candidate: item.description) ?? 100
                    scored.append((item, 8_000 + descScore + installedBonus))
                } else if qLower.count >= 4,
                          let descScore = UpkeepEngine.scoreFuzzy(query: query, candidate: item.description),
                          descScore >= qLower.count * 28 {
                    scored.append((item, min(4_000, descScore) + installedBonus))
                }
            }
        }
        scored.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }
        return Array(scored.prefix(limit).map(\.0))
    }

    public func fuzzySearchLocal(query: String, filterCasks: Bool?) -> [BrewPackageItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            guard let filterCasks else { return catalog }
            return catalog.filter { $0.isCask == filterCasks }
        }
        #if USE_RUST_UPKEEP_CORE
        if rustRemoteIndex.count > 0 {
            return rustRemoteIndex.searchJSON(query: trimmed, filterCasks: filterCasks, limit: 120, installedOnly: true)
        }
        return rustLocalIndex.search(query: trimmed, filterCasks: filterCasks, limit: 120)
        #else
        return scorePool(catalog, query: trimmed, filterCasks: filterCasks, limit: 120)
        #endif
    }

    private func runBrewStreaming(arguments: [String], commandLabel: String) async throws -> CLIResult {
        await BrewLogStore.shared.beginLive(command: commandLabel)
        let res = try await CLIExecutor.runStreaming(
            binary: "brew",
            arguments: arguments,
            environment: Self.brewEnv
        ) { line in
            Task { @MainActor in
                BrewLogStore.shared.appendLiveLine(line)
            }
        }
        await BrewLogStore.shared.record(command: commandLabel, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        return res
    }

    public func install(name: String, isCask: Bool) async throws -> String {
        var args = ["install"]
        if isCask { args.append("--cask") }
        args.append(name)
        let cmd = "brew " + args.joined(separator: " ")
        let res = try await runBrewStreaming(arguments: args, commandLabel: cmd)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        _ = try? await loadInstalledAndOutdated(forceRefresh: true)
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func uninstall(name: String, isCask: Bool, zap: Bool = false) async throws -> String {
        var args = ["uninstall"]
        if isCask {
            args.append("--cask")
            if zap { args.append("--zap") }
        }
        args.append(name)
        let cmd = "brew " + args.joined(separator: " ")
        let res = try await runBrewStreaming(arguments: args, commandLabel: cmd)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        let updated = catalog.filter { !($0.name == name && $0.isCask == isCask) }
        #if USE_RUST_UPKEEP_CORE
        if rustRemoteIndex.count > 0 { rustRemoteIndex.refreshLocal() }
        #endif
        updateLocalCatalog(updated)
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func upgrade(name: String? = nil) async throws -> String {
        var args = ["upgrade"]
        if let name { args.append(name) }
        let cmd = "brew " + args.joined(separator: " ")
        let res = try await runBrewStreaming(arguments: args, commandLabel: cmd)
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
        // Update in-memory immediately instead of spawning two Ruby brew processes
        let updated = catalog.map { item -> BrewPackageItem in
            guard item.name == name && !item.isCask else { return item }
            return BrewPackageItem(
                name: item.name,
                description: item.description,
                version: item.version,
                isCask: false,
                isInstalled: item.isInstalled,
                isOutdated: false,
                isPinned: true,
                homepage: item.homepage
            )
        }
        #if USE_RUST_UPKEEP_CORE
        if rustRemoteIndex.count > 0 { rustRemoteIndex.refreshLocal() }
        #endif
        updateLocalCatalog(updated)
        return CLIExecutor.stripANSI(res.stdout)
    }

    public func unpin(name: String) async throws -> String {
        let cmd = "brew unpin \(name)"
        let res = try await CLIExecutor.run(binary: "brew", arguments: ["unpin", name], environment: Self.brewEnv)
        await BrewLogStore.shared.record(command: cmd, stdout: res.stdout, stderr: res.stderr, exitCode: res.exitCode)
        guard res.succeeded else {
            throw CLIError.executionFailed(command: cmd, exitCode: res.exitCode, stderr: res.stderr)
        }
        let updated = catalog.map { item -> BrewPackageItem in
            guard item.name == name && !item.isCask else { return item }
            return BrewPackageItem(
                name: item.name,
                description: item.description,
                version: item.version,
                isCask: false,
                isInstalled: item.isInstalled,
                isOutdated: item.isOutdated,
                isPinned: false,
                homepage: item.homepage
            )
        }
        #if USE_RUST_UPKEEP_CORE
        if rustRemoteIndex.count > 0 { rustRemoteIndex.refreshLocal() }
        #endif
        updateLocalCatalog(updated)
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
