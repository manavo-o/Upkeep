import AppKit
import Foundation

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

public struct MoleInstalledApp: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public let name: String
    public let bundleId: String?
    public let source: String?
    public let uninstallName: String?
    public let path: String
    public let size: Int64?

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
    }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleId = "bundle_id"
        case source
        case uninstallName = "uninstall_name"
        case path
        case size
    }

    public var formattedSize: String {
        guard let size, size > 0 else { return "App" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

public actor MoleService {
    public static let shared = MoleService()
    private var cachedApps: [MoleInstalledApp] = []
    private var lastAppFetch: Date?

    public static func isInstalled() -> Bool {
        CLIExecutor.resolveBinary("mo") != nil
    }

    public static func parseCleanOutput(_ raw: String, isDryRun: Bool) -> MoleCleanSummary {
        SpotlightEngine.parseMoleCleanOutput(raw, isDryRun: isDryRun)
    }

    public func dryRunClean() async throws -> MoleCleanSummary {
        let result = try await CLIExecutor.run(binary: "mo", arguments: ["clean", "--dry-run"])
        guard result.succeeded else {
            throw CLIError.executionFailed(command: "mo clean --dry-run", exitCode: result.exitCode, stderr: result.stderr)
        }
        return Self.parseCleanOutput(result.stdout, isDryRun: true)
    }

    public func runClean() async throws -> MoleCleanSummary {
        let result = try await CLIExecutor.run(binary: "mo", arguments: ["clean"])
        guard result.succeeded else {
            throw CLIError.executionFailed(command: "mo clean", exitCode: result.exitCode, stderr: result.stderr)
        }
        return Self.parseCleanOutput(result.stdout, isDryRun: false)
    }

    public func updateMole() async throws -> String {
        let result = try await CLIExecutor.run(binary: "mo", arguments: ["update"])
        guard result.succeeded else {
            throw CLIError.executionFailed(command: "mo update", exitCode: result.exitCode, stderr: result.stderr)
        }
        return CLIExecutor.stripANSI(result.stdout)
    }

    public func listInstalledApps(forceRefresh: Bool = false) async throws -> [MoleInstalledApp] {
        if !forceRefresh, let last = lastAppFetch, Date().timeIntervalSince(last) < 60, !cachedApps.isEmpty {
            return cachedApps
        }

        // Fast parallel scan across /Applications and ~/Applications computing real bundle sizes
        let apps = await SpotlightEngine.scanInstalledApplications()
        cachedApps = apps
        lastAppFetch = Date()
        return apps
    }

    /// Uninstalls an application using Mole's full uninstaller (`mo uninstall`) via a POSIX PTY
    /// so Mole's leftover rules, receipt scans, and safety protections run natively after the user
    /// confirms in Upkeep's UI. Falls back to native macOS Trash if `mo` is not installed.
    public func uninstallApp(_ app: MoleInstalledApp, withData: Bool = false, dryRun: Bool = false) async throws -> String {
        if Self.isInstalled() {
            var args = ["uninstall"]
            if withData { args.append("--with-data") }
            if dryRun { args.append("--dry-run") }
            args.append(app.uninstallName ?? app.name)

            let result: CLIResult
            if dryRun {
                result = try await CLIExecutor.run(binary: "mo", arguments: args)
            } else {
                result = try await CLIExecutor.runInPTY(
                    binary: "mo",
                    arguments: args,
                    autoConfirmTrigger: "ESC cancel",
                    autoConfirmInput: "y\n",
                    confirmDelayMs: 200
                )
            }

            if result.succeeded || (dryRun && !result.stdout.isEmpty) {
                if !dryRun {
                    cachedApps.removeAll { $0.path == app.path || $0.name.caseInsensitiveCompare(app.name) == .orderedSame }
                }
                return dryRun ? CLIExecutor.stripANSI(result.stdout) : "Moved \(app.name) to Trash via Mole"
            }

            let detail = CLIExecutor.stripANSI(result.stderr.isEmpty ? result.stdout : result.stderr)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty }) ?? "Exit status \(result.exitCode)"
            throw CLIError.executionFailed(command: "mo " + args.joined(separator: " "), exitCode: result.exitCode, stderr: detail)
        }

        return try await uninstallAppNativeFallback(app, withData: withData, dryRun: dryRun)
    }

    private func uninstallAppNativeFallback(_ app: MoleInstalledApp, withData: Bool = false, dryRun: Bool = false) async throws -> String {
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
            targets.append(contentsOf: Self.discoverLeftoverURLs(for: app))
        }

        if dryRun {
            return targets.map(\.path).joined(separator: "\n")
        }

        // Gracefully quit the app if it is currently running
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
                // Only fail hard if the primary .app bundle itself could not be moved to Trash
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
            "Containers"
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
