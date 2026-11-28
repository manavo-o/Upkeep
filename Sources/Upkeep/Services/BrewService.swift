import Darwin
import Foundation
import Observation
import Synchronization

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
    private var liveOperationID: UUID?

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
    nonisolated static let maxOutputBytes = 64 * 1024

    func beginLive(command: String, operationID: UUID) {
        liveOperationID = operationID
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

    func appendLiveOutput(_ output: String, latestLine: String, operationID: UUID) {
        guard liveOperationID == operationID, let current = lastLog else { return }
        liveStatusLine = latestLine
        if !liveOutputBuffer.isEmpty { liveOutputBuffer.append("\n") }
        liveOutputBuffer.append(output)
        liveOutputBuffer = CLIExecutor.boundedTail(liveOutputBuffer, maxBytes: Self.maxOutputBytes)
        self.lastLog = BrewOperationLog(
            command: current.command,
            output: liveOutputBuffer,
            succeeded: current.succeeded,
            exitCode: current.exitCode,
            timestamp: current.timestamp
        )
    }

    public func record(command: String, stdout: String, stderr: String, exitCode: Int32) {
        liveOutputBuffer = ""
        self.isRunning = false
        liveOperationID = nil
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
        let boundedOutput = CLIExecutor.boundedTail(combined, maxBytes: Self.maxOutputBytes)
        let entry = BrewOperationLog(
            command: command,
            output: boundedOutput,
            succeeded: exitCode == 0,
            exitCode: exitCode,
            timestamp: Date()
        )
        self.lastLog = entry
        persist(entry)
    }

    public func clear() {
        guard !isRunning else { return }
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
    public let commandName: String
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
        homepage: String = "",
        commandName: String? = nil
    ) {
        self.id = "\(isCask ? "cask" : "formula"):\(name)"
        self.name = name
        self.commandName = commandName ?? name
        self.description = description
        self.version = version
        self.isCask = isCask
        self.isInstalled = isInstalled
        self.isOutdated = isOutdated
        self.isPinned = isPinned
        self.homepage = homepage
    }
}

/// Fuzzy matcher that delegates to Rust through UpkeepEngine.
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
    private var isRunningCommand = false
    private var inFlightLoadTask: Task<[BrewPackageItem], Error>? {
        didSet { updateCatalogActivity() }
    }
    private var installedCatalogRevision = 0

    // Cached full Homebrew API catalog (~15k formulae + casks) for sub-ms remote search without spawning Ruby `brew search`
    private var lastRemoteCatalogFetch: Date?
    private var inFlightRemoteCatalogTask: Task<Bool, Never>? {
        didSet { updateCatalogActivity() }
    }
    private var catalogSearchCount = 0 {
        didSet { updateCatalogActivity() }
    }
    private let catalogActivity = Mutex(false)
    private var remoteCatalogRevision = 0
    private var idleEvictionTask: Task<Void, Never>?

    private let rustRemoteIndex = UpkeepEngine.RustBrewIndex()

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
        if let rustItems = UpkeepEngine.scanBrewDirs(prefix: prefix) {
            return rustItems
        }
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
    }

    private struct InstalledPackages: Decodable {
        struct Formula: Decodable {
            struct Keg: Decodable { let version: String }

            let name: String
            let fullName: String?
            let desc: String?
            let installed: [Keg]
            let linkedKeg: String?
            let pinned: Bool
            let homepage: String?
        }

        struct Cask: Decodable {
            let token: String
            let fullToken: String?
            let desc: String?
            let installed: String?
            let pinned: Bool?
            let homepage: String?
        }

        let formulae: [Formula]
        let casks: [Cask]
    }

    private struct OutdatedPackages: Decodable {
        struct Package: Decodable {
            let name: String
            let pinned: Bool?
        }

        let formulae: [Package]
        let casks: [Package]
    }

    private static func brewJSON<T: Decodable>(_ type: T.Type, arguments: [String]) async throws -> T {
        let command = "brew " + arguments.joined(separator: " ")
        let result = try await CLIExecutor.run(binary: "brew", arguments: arguments, environment: brewEnv)
        guard result.succeeded else {
            throw CLIError.executionFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = extractJSONObject(from: result.stdout),
              let decoded = try? decoder.decode(type, from: data) else {
            throw CLIError.invalidOutput(command: command)
        }
        return decoded
    }

    /// Uses Homebrew's own revision, HEAD, pin and cask upgrade rules.
    public func loadInstalledAndOutdated(forceRefresh: Bool = false) async throws -> [BrewPackageItem] {
        defer {
            if !Task.isCancelled { scheduleIdleEviction() }
        }

        let revision = installedCatalogRevision
        let task: Task<[BrewPackageItem], Error>
        if let existing = inFlightLoadTask {
            task = existing
        } else {
            if !forceRefresh, let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < 30 {
                return catalog
            }

            task = Task {
                defer {
                    if installedCatalogRevision == revision { inFlightLoadTask = nil }
                }

                async let installed = Self.brewJSON(InstalledPackages.self, arguments: ["info", "--json=v2", "--installed"])
                async let outdated = Self.brewJSON(OutdatedPackages.self, arguments: ["outdated", "--json=v2"])
                let (packages, upgrades) = try await (installed, outdated)
                let outdatedFormulae = Set(upgrades.formulae.filter { $0.pinned != true }.map(\.name))
                let outdatedCasks = Set(upgrades.casks.filter { $0.pinned != true }.map(\.name))

                let formulae = packages.formulae.map { formula in
                    let commandName = formula.fullName ?? formula.name
                    let installedVersion = formula.linkedKeg ?? formula.installed.map(\.version).max {
                        $0.localizedStandardCompare($1) == .orderedAscending
                    }
                    return BrewPackageItem(
                        name: formula.name, description: formula.desc ?? "", version: installedVersion ?? "",
                        isCask: false, isInstalled: true,
                        isOutdated: !formula.pinned && outdatedFormulae.contains(commandName),
                        isPinned: formula.pinned, homepage: formula.homepage ?? "", commandName: commandName
                    )
                }
                let casks = packages.casks.map { cask in
                    BrewPackageItem(
                        name: cask.token, description: cask.desc ?? "", version: cask.installed ?? "",
                        isCask: true, isInstalled: true,
                        isOutdated: cask.pinned != true && outdatedCasks.contains(cask.token),
                        isPinned: cask.pinned == true, homepage: cask.homepage ?? "", commandName: cask.fullToken
                    )
                }
                let items = (formulae + casks).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                if installedCatalogRevision == revision { updateLocalCatalog(items) }
                return items
            }
            inFlightLoadTask = task
        }

        let result = await task.result
        try Task.checkCancellation()
        if installedCatalogRevision != revision { return try await loadInstalledAndOutdated() }
        return try result.get()
    }

    private func invalidateInstalledCatalog() {
        installedCatalogRevision += 1
        inFlightLoadTask?.cancel()
        inFlightLoadTask = nil
        lastLoadedAt = nil
    }

    // MARK: - Fast Disk-Cached Homebrew Public JSON API Index

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
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = try? String(contentsOf: etagURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        // Use a cacheless ephemeral session + download(for:) so 30 MB formula/cask JSON never enters URLCache or Swift RAM.
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (tempFileURL, response) = try await session.download(for: request)
            defer { try? fm.removeItem(at: tempFileURL) }
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 304 {
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dataURL.path)
                    return (fm.fileExists(atPath: dataURL.path) ? dataURL : nil, true)
                }
                if (200..<300).contains(http.statusCode),
                   let attrs = try? fm.attributesOfItem(atPath: tempFileURL.path),
                   let size = attrs[.size] as? NSNumber, size.intValue > 0 {
                    _ = try? fm.replaceItemAt(dataURL, withItemAt: tempFileURL)
                    if !fm.fileExists(atPath: dataURL.path) {
                        try? fm.moveItem(at: tempFileURL, to: dataURL)
                    }
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
    nonisolated var hasPendingCatalogWork: Bool {
        catalogActivity.withLock { $0 }
    }

    private func updateCatalogActivity() {
        let busy = inFlightLoadTask != nil || inFlightRemoteCatalogTask != nil || catalogSearchCount != 0
        let becameIdle = catalogActivity.withLock {
            let wasBusy = $0
            $0 = busy
            return wasBusy && !busy
        }
        if becameIdle {
            NotificationCenter.default.post(name: IdleMemoryRecovery.workDidBecomeIdle, object: nil)
        }
    }

    public func prewarmIfNeeded() async {
        guard !Task.isCancelled, Self.isInstalled() else { return }
        cancelIdleEviction()
        _ = await ensureRemoteCatalogLoaded()
    }

    /// Cancels any pending idle-eviction timer (called when the HUD or Homebrew pane becomes active).
    public func cancelIdleEviction() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
    }

    /// Schedules automatic RAM eviction of the 15k-package catalog after `afterSeconds` of inactivity.
    /// Reloading `catalog.bin` takes ~3ms on the next open, keeping menu-bar idle RSS near zero.
    public func scheduleIdleEviction(afterSeconds seconds: Int = 5) {
        idleEvictionTask?.cancel()
        idleEvictionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.evictRemoteCatalogIfIdle()
        }
    }

    /// Immediately frees the in-memory 15k Homebrew catalog slab and returns freed pages to macOS.
    public func evictRemoteCatalogIfIdle() {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        guard !hasPendingCatalogWork else {
            scheduleIdleEviction(afterSeconds: 5)
            return
        }
        rustRemoteIndex.clear()
        lastRemoteCatalogFetch = nil
        URLCache.shared.removeAllCachedResponses()
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Returns true when the remote Homebrew catalog is already warm in memory (zero debounce needed).
    public func hasWarmRemoteIndex() -> Bool {
        rustRemoteIndex.count > 0
    }

    private func ensureRemoteCatalogLoaded() async -> Bool {
        guard !Task.isCancelled else { return false }
        cancelIdleEviction()
        if rustRemoteIndex.count > 0,
           let last = lastRemoteCatalogFetch,
           Date().timeIntervalSince(last) < 6 * 3600 {
            return true
        }

        let revision = remoteCatalogRevision
        if let inFlight = inFlightRemoteCatalogTask {
            let didLoad = await inFlight.value
            return revision == remoteCatalogRevision && didLoad
        }

        let rustIndex = self.rustRemoteIndex

        let task = Task<Bool, Never> {
            let fm = FileManager.default
            let binURL = Self.catalogBinURL
            let hasBinCache = fm.fileExists(atPath: binURL.path)
            // Ultra-fast <5ms cold-start path: load compact binary cache directly into Rust's byte slab.
            if hasBinCache,
               let attrs = try? fm.attributesOfItem(atPath: binURL.path),
               let modDate = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modDate) < 6 * 3600 {
                if rustIndex.loadBinaryCache(path: binURL.path) > 0 {
                    return true
                }
            }

            async let formulaeFetch = Self.ensureCachedJSONFile(
                urlString: "https://formulae.brew.sh/api/formula.json",
                cacheFileName: "formula.json"
            )
            async let casksFetch = Self.ensureCachedJSONFile(
                urlString: "https://formulae.brew.sh/api/cask.json",
                cacheFileName: "cask.json"
            )

            let (fRes, cRes) = await (formulaeFetch, casksFetch)

            // If both ETags returned 304 Not Modified and catalog.bin exists, load binary cache directly.
            if fRes.notModified && cRes.notModified && hasBinCache {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: binURL.path)
                if rustIndex.loadBinaryCache(path: binURL.path) > 0 {
                    return true
                }
            }
            // Stream directly from disk into Rust's contiguous byte slab (avoids 30 MB Swift Data spike).
            let loadedCount = rustIndex.loadAPIFiles(formulaePath: fRes.url?.path, casksPath: cRes.url?.path)
            if loadedCount > 0 {
                rustIndex.saveBinaryCache(path: binURL.path)
                return true
            }

            return false
        }

        inFlightRemoteCatalogTask = task
        let loaded = await task.value
        guard revision == remoteCatalogRevision else { return false }
        inFlightRemoteCatalogTask = nil

        if loaded { lastRemoteCatalogFetch = Date() }
        return loaded
    }

    public func searchRemote(query: String, filterCasks: Bool? = nil) async throws -> [BrewPackageItem] {
        try Task.checkCancellation()
        catalogSearchCount += 1
        defer {
            catalogSearchCount -= 1
            scheduleIdleEviction()
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fuzzySearchLocal(query: "", filterCasks: filterCasks) }

        while true {
            let revision = remoteCatalogRevision
            async let remoteReady = ensureRemoteCatalogLoaded()
            _ = try await loadInstalledAndOutdated()
            let hasRemote = await remoteReady
            try Task.checkCancellation()
            guard revision == remoteCatalogRevision else { continue }
            if hasRemote {
                let hits = try await rustRemoteIndex.searchCancellable(query: trimmed, filterCasks: filterCasks, limit: 40)
                try Task.checkCancellation()
                guard revision == remoteCatalogRevision else { continue }
                if !hits.isEmpty { return hits.map(withInstalledState) }
            }
            let results = try await searchConfiguredTaps(query: trimmed, filterCasks: filterCasks)
            try Task.checkCancellation()
            if revision == remoteCatalogRevision { return results }
        }
    }

    private func searchConfiguredTaps(query trimmed: String, filterCasks: Bool?) async throws -> [BrewPackageItem] {
        // The description search also covers packages in locally configured taps.
        let result = try await CLIExecutor.run(
            binary: "brew",
            arguments: ["search", "--desc", "--", trimmed],
            environment: Self.brewEnv
        )
        try Task.checkCancellation()
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
            let packageName = name.split(separator: "/").last.map(String.init) ?? name
            let item = BrewPackageItem(
                name: packageName, description: desc, version: "",
                isCask: isCaskSection, commandName: name
            )
            results.append(withInstalledState(item))
        }

        let filtered = results.filter { item in
            guard let filterCasks else { return true }
            return item.isCask == filterCasks
        }
        return filtered.isEmpty ? fuzzySearchLocal(query: trimmed, filterCasks: filterCasks) : filtered
    }

    private func withInstalledState(_ package: BrewPackageItem) -> BrewPackageItem {
        if let installed = catalogLookup[package.id],
           package.commandName == package.name || package.commandName == installed.commandName {
            return installed
        }
        // The Rust search index can carry a snapshot of an earlier local scan.
        return BrewPackageItem(
            name: package.name, description: package.description,
            version: package.isInstalled ? "" : package.version,
            isCask: package.isCask, homepage: package.homepage, commandName: package.commandName
        )
    }

    private func invalidateRemoteCatalog() async {
        _ = await inFlightRemoteCatalogTask?.value
        remoteCatalogRevision += 1
        inFlightRemoteCatalogTask = nil
        lastRemoteCatalogFetch = nil
        rustRemoteIndex.clear()
        for file in ["formula.json", "cask.json", "catalog.bin"] {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date.distantPast],
                ofItemAtPath: Self.cacheDirURL.appendingPathComponent(file).path
            )
        }
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

    public func fuzzySearchLocal(query: String, filterCasks: Bool?, outdatedOnly: Bool = false) -> [BrewPackageItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let pool = outdatedOnly ? catalog.filter(\.isOutdated) : catalog
        if trimmed.isEmpty {
            guard let filterCasks else { return pool }
            return pool.filter { $0.isCask == filterCasks }
        }
        return scorePool(pool, query: trimmed, filterCasks: filterCasks, limit: 120)
    }

    private struct CommandInProgress: LocalizedError {
        var errorDescription: String? { "Wait for the current Homebrew command to finish." }
    }

    private final class LiveBrewOutput: Sendable {
        private struct Pending {
            var output = ""
            var latestLine: String?
        }

        private let pending = Mutex(Pending())
        private let operationID: UUID

        init(operationID: UUID) {
            self.operationID = operationID
        }

        func append(_ lines: [String]) {
            guard let latestLine = lines.last else { return }
            let batch = lines.joined(separator: "\n")
            let shouldFlush = pending.withLock { state in
                let needsFlush = state.latestLine == nil
                if !state.output.isEmpty { state.output.append("\n") }
                state.output.append(batch)
                state.output = CLIExecutor.boundedTail(state.output, maxBytes: BrewLogStore.maxOutputBytes)
                state.latestLine = latestLine
                return needsFlush
            }
            if shouldFlush {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    let batch = pending.withLock { state in
                        let batch = state
                        state = Pending()
                        return batch
                    }
                    if let latestLine = batch.latestLine {
                        BrewLogStore.shared.appendLiveOutput(batch.output, latestLine: latestLine, operationID: operationID)
                    }
                }
            }
        }
    }

    private func runBrewStreaming(arguments: [String], retainOutput: Bool = true) async throws -> CLIResult {
        guard !isRunningCommand else { throw CommandInProgress() }
        isRunningCommand = true
        defer { isRunningCommand = false }

        let command = "brew " + arguments.joined(separator: " ")
        let operationID = UUID()
        await BrewLogStore.shared.beginLive(command: command, operationID: operationID)
        let result: CLIResult
        do {
            let liveOutput = LiveBrewOutput(operationID: operationID)
            result = try await CLIExecutor.runStreamingBatches(
                binary: "brew",
                arguments: arguments,
                environment: Self.brewEnv,
                capture: retainOutput ? .full : .tail(maxBytes: BrewLogStore.maxOutputBytes),
                liveLineLimit: BrewLogStore.maxOutputBytes,
                onLines: liveOutput.append
            )
        } catch {
            await BrewLogStore.shared.record(
                command: command, stdout: "", stderr: error.localizedDescription, exitCode: 1
            )
            throw error
        }

        // A failed bulk operation can still have changed some installed packages.
        if arguments.first != "doctor" { invalidateInstalledCatalog() }
        if arguments.first == "update", result.succeeded { await invalidateRemoteCatalog() }
        await BrewLogStore.shared.record(
            command: command, stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode
        )
        return result
    }

    private func runPackageCommand(_ arguments: [String], retainOutput: Bool) async throws -> String {
        let result = try await runBrewStreaming(arguments: arguments, retainOutput: retainOutput)
        guard result.succeeded else {
            let command = "brew " + arguments.joined(separator: " ")
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw CLIError.executionFailed(command: command, exitCode: result.exitCode, stderr: CLIExecutor.stripANSI(detail))
        }
        return retainOutput ? CLIExecutor.stripANSI(result.stdout) : ""
    }

    public func install(name: String, isCask: Bool, retainOutput: Bool = true) async throws -> String {
        try await runPackageCommand(["install", isCask ? "--cask" : "--formula", name], retainOutput: retainOutput)
    }

    public func uninstall(name: String, isCask: Bool, zap: Bool = false, retainOutput: Bool = true) async throws -> String {
        var args = ["uninstall", isCask ? "--cask" : "--formula"]
        if isCask && zap { args.append("--zap") }
        args.append(name)
        return try await runPackageCommand(args, retainOutput: retainOutput)
    }

    public func upgrade(name: String? = nil, isCask: Bool? = nil, retainOutput: Bool = true) async throws -> String {
        var args = ["upgrade"]
        if let name {
            if let isCask { args.append(isCask ? "--cask" : "--formula") }
            args.append(name)
        }
        return try await runPackageCommand(args, retainOutput: retainOutput)
    }

    public func pin(name: String, retainOutput: Bool = true) async throws -> String {
        try await runPackageCommand(["pin", name], retainOutput: retainOutput)
    }

    public func unpin(name: String, retainOutput: Bool = true) async throws -> String {
        try await runPackageCommand(["unpin", name], retainOutput: retainOutput)
    }

    public func updateBrew(retainOutput: Bool = true) async throws -> String {
        try await runPackageCommand(["update"], retainOutput: retainOutput)
    }

    public func runDoctor() async throws -> String {
        let res = try await runBrewStreaming(arguments: ["doctor"])
        return CLIExecutor.stripANSI(res.stdout + "\n" + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
