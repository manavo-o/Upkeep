import AppKit
import Foundation

// MARK: - Native Cleaner Models

public struct CleanerItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let category: String
    public let name: String
    public let path: String
    public let displayPath: String
    public let sizeBytes: Int64
    public let defaultSelected: Bool
    public let holdbackReason: String?
    public let requiresAdmin: Bool
    public let formattedSize: String

    public init(
        id: String,
        category: String,
        name: String,
        path: String,
        displayPath: String,
        sizeBytes: Int64,
        defaultSelected: Bool,
        holdbackReason: String?,
        requiresAdmin: Bool = false
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.path = path
        self.displayPath = displayPath
        self.sizeBytes = sizeBytes
        self.defaultSelected = defaultSelected
        self.holdbackReason = holdbackReason
        self.requiresAdmin = requiresAdmin
        self.formattedSize = sizeBytes > 0
            ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            : "< 1 KB"
    }
}

public struct CleanerCategory: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let totalBytes: Int64
    public let items: [CleanerItem]
    public let formattedTotalSize: String

    public init(id: String, title: String, totalBytes: Int64, items: [CleanerItem]) {
        self.id = id
        self.title = title
        self.totalBytes = totalBytes
        self.items = items
        self.formattedTotalSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

public struct CleanerScanResult: Sendable, Equatable {
    public let totalBytes: Int64
    public let selectedBytes: Int64
    public let itemCount: Int
    public let scanDurationMs: Int
    public let categories: [CleanerCategory]
    public let formattedTotalSize: String

    public static let empty = CleanerScanResult(
        totalBytes: 0,
        selectedBytes: 0,
        itemCount: 0,
        scanDurationMs: 0,
        categories: []
    )

    public init(
        totalBytes: Int64,
        selectedBytes: Int64,
        itemCount: Int,
        scanDurationMs: Int,
        categories: [CleanerCategory]
    ) {
        self.totalBytes = totalBytes
        self.selectedBytes = selectedBytes
        self.itemCount = itemCount
        self.scanDurationMs = scanDurationMs
        self.categories = categories
        self.formattedTotalSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    public var allItems: [CleanerItem] {
        categories.flatMap(\.items)
    }

    public var defaultSelectedPaths: Set<String> {
        Set(allItems.filter(\.defaultSelected).map(\.path))
    }

    public func toSummary() -> MoleCleanSummary {
        var lines: [String] = []
        for cat in categories {
            lines.append("➤ \(cat.title)")
            for item in cat.items {
                let prefix = item.defaultSelected ? "○" : "◎"
                lines.append("\(prefix) \(item.name) · \(item.formattedSize)")
            }
        }
        return MoleCleanSummary(
            totalReclaimed: formattedTotalSize,
            itemCount: itemCount,
            lines: lines,
            isDryRun: true
        )
    }
}

public struct CleanFailedItem: Identifiable, Sendable, Hashable, Codable {
    public var id: String { path }
    public let path: String
    public let error: String

    public init(path: String, error: String) {
        self.path = path
        self.error = error
    }
}

public struct CleanExecutionResult: Sendable, Equatable, Codable {
    public let reclaimedBytes: Int64
    public let removedCount: Int
    public let failedItems: [CleanFailedItem]
    public let durationMs: Int
    public let dryRun: Bool
    public let formattedReclaimedSize: String

    public static func empty(dryRun: Bool) -> CleanExecutionResult {
        CleanExecutionResult(reclaimedBytes: 0, removedCount: 0, failedItems: [], durationMs: 0, dryRun: dryRun)
    }

    public init(
        reclaimedBytes: Int64,
        removedCount: Int,
        failedItems: [CleanFailedItem],
        durationMs: Int,
        dryRun: Bool
    ) {
        self.reclaimedBytes = reclaimedBytes
        self.removedCount = removedCount
        self.failedItems = failedItems
        self.durationMs = durationMs
        self.dryRun = dryRun
        self.formattedReclaimedSize = ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file)
    }
}

public struct MoleCleanSummary: Sendable, Equatable {
    public let totalReclaimed: String
    public let itemCount: Int
    public let lines: [String]
    public let isDryRun: Bool

    public init(totalReclaimed: String, itemCount: Int, lines: [String], isDryRun: Bool) {
        self.totalReclaimed = totalReclaimed
        self.itemCount = itemCount
        self.lines = lines
        self.isDryRun = isDryRun
    }
}

// MARK: - Uninstaller Models (Pre-Formatted Sizes)

public struct MoleInstalledApp: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public let name: String
    public let bundleId: String?
    public let source: String?
    public let uninstallName: String?
    public let path: String
    public let size: Int64?
    public let formattedSize: String

    public init(
        name: String,
        bundleId: String?,
        source: String?,
        uninstallName: String?,
        path: String,
        size: Int64?
    ) {
        self.name = name
        self.bundleId = bundleId
        self.source = source
        self.uninstallName = uninstallName
        self.path = path
        self.size = size
        if let size, size > 0 {
            self.formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        } else {
            self.formattedSize = "App"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
        let source = try container.decodeIfPresent(String.self, forKey: .source)
        let uninstallName = try container.decodeIfPresent(String.self, forKey: .uninstallName)
        let path = try container.decode(String.self, forKey: .path)
        let size = try container.decodeIfPresent(Int64.self, forKey: .size)
        self.init(
            name: name,
            bundleId: bundleId,
            source: source,
            uninstallName: uninstallName,
            path: path,
            size: size
        )
    }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleId = "bundle_id"
        case source
        case uninstallName = "uninstall_name"
        case path
        case size
    }
}

public struct UninstallLeftoverItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let displayPath: String
    public let category: String
    public let sizeBytes: Int64
    public let isSystem: Bool
    public let defaultSelected: Bool
    public let holdbackReason: String?
    public let formattedSize: String

    public init(
        path: String,
        displayPath: String,
        category: String,
        sizeBytes: Int64,
        isSystem: Bool = false,
        defaultSelected: Bool = true,
        holdbackReason: String? = nil
    ) {
        self.path = path
        self.displayPath = displayPath
        self.category = category
        self.sizeBytes = sizeBytes
        self.isSystem = isSystem
        self.defaultSelected = defaultSelected
        self.holdbackReason = holdbackReason
        self.formattedSize = sizeBytes > 0
            ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
            : "< 1 KB"
    }
}

public struct UninstallInspection: Sendable, Equatable {
    public let app: MoleInstalledApp
    public let leftovers: [UninstallLeftoverItem]
    public let homebrewCaskToken: String?
    public let hasSiblingApp: Bool
    public let officialUninstallerVendor: String?

    public init(
        app: MoleInstalledApp,
        leftovers: [UninstallLeftoverItem],
        homebrewCaskToken: String?,
        hasSiblingApp: Bool = false,
        officialUninstallerVendor: String? = nil
    ) {
        self.app = app
        self.leftovers = leftovers
        self.homebrewCaskToken = homebrewCaskToken
        self.hasSiblingApp = hasSiblingApp
        self.officialUninstallerVendor = officialUninstallerVendor
    }

    public var leftoversTotalBytes: Int64 {
        leftovers.reduce(0) { $0 + $1.sizeBytes }
    }

    public var totalSizeBytes: Int64 {
        (app.size ?? 0) + leftoversTotalBytes
    }

    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }
}

// MARK: - Native Cleaner & Uninstaller Service

public typealias CleanerService = MoleService

public actor MoleService {
    public static let shared = MoleService()
    private var cachedApps: [MoleInstalledApp] = []
    private var lastAppFetch: Date?

    public static func parseCleanOutput(_ raw: String, isDryRun: Bool) -> MoleCleanSummary {
        UpkeepEngine.parseMoleCleanOutput(raw, isDryRun: isDryRun)
    }

    /// Runs the native Rust parallel APFS dry-run scanner across caches, developer tools, logs, and temp files.
    public func scanCleanerNative() async -> CleanerScanResult {
        await UpkeepEngine.scanCleanerNative()
    }

    /// Executes safe parallel cleanup of the selected user paths via Rust and optional allowlisted
    /// system paths via a single native macOS administrator authorization prompt.
    public func executeNativeClean(
        paths: [String],
        adminPaths: [String] = [],
        dryRun: Bool = false
    ) async -> CleanExecutionResult {
        let userResult: CleanExecutionResult = paths.isEmpty
            ? .empty(dryRun: dryRun)
            : await UpkeepEngine.cleanPathsNative(paths, dryRun: dryRun)

        guard !adminPaths.isEmpty else {
            return userResult
        }

        let adminResult = await executeAdminClean(paths: adminPaths, dryRun: dryRun)
        return CleanExecutionResult(
            reclaimedBytes: userResult.reclaimedBytes + adminResult.reclaimedBytes,
            removedCount: userResult.removedCount + adminResult.removedCount,
            failedItems: userResult.failedItems + adminResult.failedItems,
            durationMs: userResult.durationMs + adminResult.durationMs,
            dryRun: dryRun
        )
    }

    private static let allowedAdminDirRoots: Set<String> = [
        "/Library/Developer/CoreSimulator/Caches/dyld",
        "/Library/Logs/DiagnosticReports",
        "/private/var/db/diagnostics/Special",
        "/private/var/db/diagnostics/Persist",
        "/private/var/db/DiagnosticPipeline",
        "/private/var/db/reportmemoryexception"
    ]

    private static let allowedAdminFilePrefixes: [String] = [
        "/private/var/log/",
        "/private/var/db/powerlog/",
        "/Library/Caches/",
        "/private/tmp/",
        "/private/var/tmp/",
        "/Library/LaunchDaemons/",
        "/Library/LaunchAgents/"
    ]

    private static func isAllowedAdminTarget(_ rawPath: String) -> (allowed: Bool, preserveParent: Bool) {
        guard rawPath.hasPrefix("/"),
              !rawPath.contains("/../"),
              !rawPath.hasSuffix("/.."),
              !rawPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return (false, false)
        }
        let trimmed = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        if allowedAdminDirRoots.contains(trimmed) {
            return (true, true)
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("/private/var/db/powerlog/") {
            let base = (lower as NSString).lastPathComponent
            if base.hasPrefix("current") || base.hasSuffix("-wal") || base.hasSuffix("-shm") {
                return (false, false)
            }
        }
        if lower.hasPrefix("/library/launchdaemons/") || lower.hasPrefix("/library/launchagents/") {
            let base = (lower as NSString).lastPathComponent
            if base.hasPrefix("com.apple.") || !base.hasSuffix(".plist") {
                return (false, false)
            }
        }
        for prefix in allowedAdminFilePrefixes where trimmed.hasPrefix(prefix) && trimmed.count > prefix.count {
            return (true, false)
        }
        return (false, false)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func executeAdminClean(paths: [String], dryRun: Bool) async -> CleanExecutionResult {
        let started = Date()
        var validTargets: [(path: String, preserveParent: Bool, size: Int64)] = []
        var failed: [CleanFailedItem] = []

        for path in Set(paths) {
            let check = Self.isAllowedAdminTarget(path)
            guard check.allowed else {
                failed.append(CleanFailedItem(path: path, error: "System path is outside allowed admin targets"))
                continue
            }
            let size = UpkeepEngine.calculatePathSize(atPath: path)
            validTargets.append((path, check.preserveParent, size))
        }

        guard !validTargets.isEmpty else {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return CleanExecutionResult(reclaimedBytes: 0, removedCount: 0, failedItems: failed, durationMs: elapsed, dryRun: dryRun)
        }

        if dryRun {
            let total = validTargets.reduce(Int64(0)) { $0 + $1.size }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return CleanExecutionResult(reclaimedBytes: total, removedCount: validTargets.count, failedItems: failed, durationMs: elapsed, dryRun: true)
        }

        var commands: [String] = []
        for target in validTargets {
            let q = Self.shellQuote(target.path)
            if target.preserveParent {
                commands.append("if [ -d \(q) ] && [ ! -L \(q) ]; then find \(q) -mindepth 1 -maxdepth 1 ! -type l -exec rm -rf {} + 2>/dev/null || true; fi")
            } else {
                commands.append("if [ ! -L \(q) ]; then rm -rf \(q) 2>/dev/null || true; fi")
            }
        }
        let shellScript = commands.joined(separator: "; ")
        let escapedForAppleScript = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"

        do {
            let res = try await CLIExecutor.run(binary: "/usr/bin/osascript", arguments: ["-e", appleScript])
            if res.exitCode != 0 {
                let errText = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = errText.isEmpty ? "Administrator authorization was cancelled" : errText
                for target in validTargets {
                    failed.append(CleanFailedItem(path: target.path, error: msg))
                }
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                return CleanExecutionResult(reclaimedBytes: 0, removedCount: 0, failedItems: failed, durationMs: elapsed, dryRun: false)
            }
        } catch {
            for target in validTargets {
                failed.append(CleanFailedItem(path: target.path, error: error.localizedDescription))
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return CleanExecutionResult(reclaimedBytes: 0, removedCount: 0, failedItems: failed, durationMs: elapsed, dryRun: false)
        }

        var reclaimed: Int64 = 0
        var removed = 0
        for target in validTargets {
            let afterSize = UpkeepEngine.calculatePathSize(atPath: target.path)
            let delta = max(0, target.size - afterSize)
            if delta > 0 || !FileManager.default.fileExists(atPath: target.path) {
                reclaimed += delta > 0 ? delta : target.size
                removed += 1
            } else {
                failed.append(CleanFailedItem(path: target.path, error: "Could not remove protected system item"))
            }
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return CleanExecutionResult(reclaimedBytes: reclaimed, removedCount: removed, failedItems: failed, durationMs: elapsed, dryRun: false)
    }

    public func listInstalledApps(forceRefresh: Bool = false) async throws -> [MoleInstalledApp] {
        if !forceRefresh, let last = lastAppFetch, Date().timeIntervalSince(last) < 60, !cachedApps.isEmpty {
            return cachedApps
        }

        let apps = await UpkeepEngine.scanInstalledApplications()
        cachedApps = apps
        lastAppFetch = Date()
        return apps
    }

    /// Moves an application (and optionally its discovered leftovers) to Trash natively without external CLIs.
    public func uninstallApp(_ app: MoleInstalledApp, withData: Bool = false, dryRun: Bool = false) async throws -> String {
        let appURL = URL(fileURLWithPath: app.path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: app.path) else {
            throw NSError(
                domain: "Upkeep.Uninstaller",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "\(app.name) was not found at \(app.path)."]
            )
        }

        var targets: [URL] = [appURL]
        if withData {
            let inspection = await inspectAppForUninstall(app)
            let safeLeftovers = inspection.leftovers
                .filter { $0.defaultSelected && !$0.isSystem }
                .map { URL(fileURLWithPath: $0.path) }
            targets.append(contentsOf: safeLeftovers)
        }

        if dryRun {
            return targets.map(\.path).joined(separator: "\n")
        }

        if let bundleId = app.bundleId, !bundleId.isEmpty {
            await MainActor.run {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
                    running.terminate()
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        var trashedCount = 0
        for url in targets where fm.fileExists(atPath: url.path) {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashedCount += 1
            } catch {
                if url == appURL {
                    throw NSError(
                        domain: "Upkeep.Uninstaller",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not move \(app.name) to Trash: \(error.localizedDescription)"]
                    )
                }
            }
        }

        cachedApps.removeAll { $0.path == app.path || $0.name.caseInsensitiveCompare(app.name) == .orderedSame }
        let extraCount = max(0, trashedCount - 1)
        if extraCount > 0 {
            return "Moved \(app.name) and \(extraCount) support \(extraCount == 1 ? "item" : "items") to Trash"
        }
        return "Moved \(app.name) to Trash"
    }

    /// Inspects an installed app before removal: discovers exact `~/Library` leftover files with sizes
    /// and cross-checks Homebrew's Caskroom in parallel (Rust `getattrlistbulk` + Rayon when linked).
    public func inspectAppForUninstall(_ app: MoleInstalledApp) async -> UninstallInspection {
        if let rustInspection = await UpkeepEngine.inspectAppForUninstallRust(app: app) {
            return rustInspection
        }

        async let caskTokenTask: String? = Task.detached(priority: .userInitiated) {
            BrewService.isInstalled()
                ? BrewService.findInstalledCask(forAppName: app.name, appPath: app.path)
                : nil
        }.value

        let urls = await Task.detached(priority: .userInitiated) {
            Self.discoverLeftoverURLs(for: app)
        }.value

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let leftovers: [UninstallLeftoverItem] = await withTaskGroup(of: UninstallLeftoverItem.self) { group in
            for url in urls {
                group.addTask {
                    let path = url.path
                    let display = path.hasPrefix(homePath)
                        ? "~" + path.dropFirst(homePath.count)
                        : path
                    let category = Self.categorizeLeftover(path: path)
                    let size = UpkeepEngine.calculatePathSize(atPath: path)
                    return UninstallLeftoverItem(path: path, displayPath: display, category: category, sizeBytes: size)
                }
            }
            var items: [UninstallLeftoverItem] = []
            items.reserveCapacity(urls.count)
            for await item in group {
                items.append(item)
            }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }

        let caskToken = await caskTokenTask
        return UninstallInspection(app: app, leftovers: leftovers, homebrewCaskToken: caskToken)
    }

    private static let allowedSystemUninstallPrefixes: [String] = [
        "/Library/Application Support/",
        "/Library/Caches/",
        "/Library/Logs/",
        "/Library/Preferences/",
        "/Library/LaunchAgents/",
        "/Library/LaunchDaemons/",
        "/Library/PrivilegedHelperTools/",
        "/Users/Shared/",
        "/private/var/db/receipts/"
    ]

    private static func isAllowedSystemUninstallTarget(_ rawPath: String) -> Bool {
        guard rawPath.hasPrefix("/"),
              !rawPath.contains("/../"),
              !rawPath.hasSuffix("/.."),
              !rawPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        let trimmed = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        let lower = trimmed.lowercased()
        let base = (lower as NSString).lastPathComponent
        guard !base.isEmpty, !base.hasPrefix("com.apple.") else {
            return false
        }
        if lower.hasPrefix("/library/launchdaemons/") || lower.hasPrefix("/library/launchagents/") {
            guard base.hasSuffix(".plist") else { return false }
        }
        for prefix in allowedSystemUninstallPrefixes where trimmed.hasPrefix(prefix) && trimmed.count > prefix.count {
            return true
        }
        return false
    }

    private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Removes an app with explicit user-reviewed leftover paths (including optional allowlisted
    /// system leftovers via a single native admin prompt) and optional Homebrew cask uninstallation.
    public func uninstallReviewedApp(
        _ app: MoleInstalledApp,
        selectedLeftoverPaths: Set<String>,
        homebrewCaskToken: String?,
        hasSiblingApp: Bool = false
    ) async throws -> String {
        let fm = FileManager.default

        if let bundleId = app.bundleId, !bundleId.isEmpty {
            await MainActor.run {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
                    running.terminate()
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        let systemLeftovers = selectedLeftoverPaths.filter {
            $0.hasPrefix("/Library/") || $0.hasPrefix("/private/") || $0.hasPrefix("/Users/Shared/")
        }
        let userLeftovers = selectedLeftoverPaths.subtracting(systemLeftovers)

        // Unload any selected user LaunchAgents cleanly via launchctl bootout before trashing
        let uid = getuid()
        for path in userLeftovers
        where path.contains("/Library/LaunchAgents/") && path.hasSuffix(".plist") && fm.fileExists(atPath: path) {
            _ = try? await CLIExecutor.run(
                binary: "launchctl",
                arguments: ["bootout", "gui/\(uid)", path]
            )
        }

        var usedHomebrew = false
        if let token = homebrewCaskToken, !token.isEmpty, BrewService.isInstalled() {
            _ = try await BrewService.shared.uninstall(name: token, isCask: true, zap: !hasSiblingApp)
            usedHomebrew = true
        } else {
            let appURL = URL(fileURLWithPath: app.path)
            if fm.fileExists(atPath: app.path) {
                do {
                    try fm.trashItem(at: appURL, resultingItemURL: nil)
                } catch {
                    throw NSError(
                        domain: "Upkeep.Uninstaller",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not move \(app.name) to Trash: \(error.localizedDescription)"]
                    )
                }
            }
        }

        // Unregister only the removed app bundle from LaunchServices (never rebuild the whole domain)
        if fm.isExecutableFile(atPath: Self.lsregisterPath) {
            _ = try? await CLIExecutor.run(binary: Self.lsregisterPath, arguments: ["-u", app.path])
        }

        var removedLeftovers = 0
        for path in userLeftovers where fm.fileExists(atPath: path) {
            if (try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil {
                removedLeftovers += 1
            }
        }

        var skippedSystemCount = 0
        let validSystemTargets = systemLeftovers
            .filter { Self.isAllowedSystemUninstallTarget($0) && fm.fileExists(atPath: $0) }
            .sorted()
        if !validSystemTargets.isEmpty {
            var commands: [String] = []
            for path in validSystemTargets {
                let q = Self.shellQuote(path)
                let lower = path.lowercased()
                if (lower.hasPrefix("/library/launchdaemons/") || lower.hasPrefix("/library/launchagents/"))
                    && lower.hasSuffix(".plist") {
                    commands.append("launchctl bootout system \(q) 2>/dev/null || true")
                }
                commands.append("if [ ! -L \(q) ]; then rm -rf \(q) 2>/dev/null || true; fi")
            }
            let shellScript = commands.joined(separator: "; ")
            let escapedForAppleScript = shellScript
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"

            if let res = try? await CLIExecutor.run(binary: "/usr/bin/osascript", arguments: ["-e", appleScript]),
               res.exitCode == 0 {
                for path in validSystemTargets {
                    if !fm.fileExists(atPath: path) {
                        removedLeftovers += 1
                    } else {
                        skippedSystemCount += 1
                    }
                }
            } else {
                skippedSystemCount = validSystemTargets.count
            }
        }

        cachedApps.removeAll { $0.path == app.path || $0.name.caseInsensitiveCompare(app.name) == .orderedSame }

        let skippedSuffix = skippedSystemCount > 0
            ? " (\(skippedSystemCount) system \(skippedSystemCount == 1 ? "item" : "items") skipped)"
            : ""

        if usedHomebrew, let token = homebrewCaskToken {
            if removedLeftovers > 0 {
                return "Uninstalled cask `\(token)` via Homebrew and removed \(removedLeftovers) leftover \(removedLeftovers == 1 ? "item" : "items")\(skippedSuffix)"
            }
            return "Uninstalled cask `\(token)` via Homebrew\(skippedSuffix)"
        }
        if removedLeftovers > 0 {
            return "Removed \(app.name) and \(removedLeftovers) leftover \(removedLeftovers == 1 ? "item" : "items")\(skippedSuffix)"
        }
        return "Moved \(app.name) to Trash\(skippedSuffix)"
    }

    private static func categorizeLeftover(path: String) -> String {
        if path.contains("/Application Support/") { return "Application Support" }
        if path.contains("/Caches/") { return "Caches" }
        if path.contains("/Preferences/") { return "Preferences" }
        if path.contains("/Logs/") { return "Logs" }
        if path.contains("/Group Containers/") { return "Group Containers" }
        if path.contains("/Containers/") { return "Containers" }
        if path.contains("/Saved Application State/") { return "Saved State" }
        if path.contains("/LaunchAgents/") { return "Launch Agents" }
        if path.contains("/HTTPStorages/") || path.contains("/WebKit/") { return "Web & Network Data" }
        return "Library Data"
    }

    public func uninstallApp(name: String, withData: Bool = false, dryRun: Bool = false) async throws -> String {
        let apps = try await listInstalledApps()
        if let match = apps.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return try await uninstallApp(match, withData: withData, dryRun: dryRun)
        }
        throw NSError(
            domain: "Upkeep.Uninstaller",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Could not find installed application '\(name)'."]
        )
    }

    private static func discoverLeftoverURLs(for app: MoleInstalledApp) -> [URL] {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        var candidates: [URL] = []
        var seenPaths = Set<String>()

        func addIfExists(_ url: URL) {
            if seenPaths.insert(url.path).inserted, fm.fileExists(atPath: url.path) {
                candidates.append(url)
            }
        }

        let identifiers: [String] = [app.bundleId, app.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let standardSubdirs = [
            "Application Support",
            "Caches",
            "Logs",
            "HTTPStorages",
            "WebKit",
            "Containers",
            "Group Containers",
            "Application Scripts"
        ]

        for subdir in standardSubdirs {
            let dir = library.appendingPathComponent(subdir, isDirectory: true)
            for id in identifiers {
                addIfExists(dir.appendingPathComponent(id))
            }
        }

        if let bundleId = app.bundleId, !bundleId.isEmpty {
            let savedState = library.appendingPathComponent("Saved Application State/\(bundleId).savedState")
            addIfExists(savedState)

            let prefsDir = library.appendingPathComponent("Preferences", isDirectory: true)
            addIfExists(prefsDir.appendingPathComponent("\(bundleId).plist"))
            if let prefItems = try? fm.contentsOfDirectory(atPath: prefsDir.path) {
                for item in prefItems where item.hasPrefix(bundleId + ".") && item.hasSuffix(".plist") {
                    addIfExists(prefsDir.appendingPathComponent(item))
                }
            }

            let launchAgentsDir = library.appendingPathComponent("LaunchAgents", isDirectory: true)
            if let agentItems = try? fm.contentsOfDirectory(atPath: launchAgentsDir.path) {
                for item in agentItems where item.hasPrefix(bundleId) && item.hasSuffix(".plist") {
                    addIfExists(launchAgentsDir.appendingPathComponent(item))
                }
            }
        }

        return candidates
    }
}
