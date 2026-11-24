import AppKit
import Foundation
import Observation

public struct AppReleaseInfo: Sendable, Equatable, Codable {
    public let version: String
    public let releaseNotes: String
    public let downloadURL: URL?
    public let htmlURL: URL?
}

@MainActor
@Observable
public final class UpdateManager {
    public static let shared = UpdateManager()

    private static let repoDefaultsKey = "UpkeepUpdateRepo"
    private static let autoCheckDefaultsKey = "UpkeepAutoCheckUpdates"
    private static let lastCheckDefaultsKey = "UpkeepLastUpdateCheck"

    public var githubRepo: String {
        didSet {
            UserDefaults.standard.set(githubRepo, forKey: Self.repoDefaultsKey)
        }
    }

    public var autoCheckUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: Self.autoCheckDefaultsKey)
        }
    }

    public private(set) var isChecking: Bool = false
    public private(set) var isInstalling: Bool = false
    public private(set) var availableRelease: AppReleaseInfo?
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?
    public private(set) var lastCheckedAt: Date?

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    public var hasUpdateAvailable: Bool {
        availableRelease != nil
    }

    private init() {
        let infoRepo = Bundle.main.infoDictionary?["UpkeepUpdateRepo"] as? String ?? ""
        self.githubRepo = UserDefaults.standard.string(forKey: Self.repoDefaultsKey) ?? infoRepo
        if UserDefaults.standard.object(forKey: Self.autoCheckDefaultsKey) == nil {
            self.autoCheckUpdates = true
        } else {
            self.autoCheckUpdates = UserDefaults.standard.bool(forKey: Self.autoCheckDefaultsKey)
        }
        self.lastCheckedAt = UserDefaults.standard.object(forKey: Self.lastCheckDefaultsKey) as? Date
    }

    func restorePresentation(release: AppReleaseInfo?, status: String?, error: String?) {
        availableRelease = release
        statusMessage = status
        errorMessage = error
    }

    public func checkIfDue() {
        guard autoCheckUpdates, !githubRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < 6 * 3600 {
            return
        }
        Task { await checkForUpdates() }
    }

    public func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        statusMessage = "Checking for updates…"

        defer {
            isChecking = false
            let now = Date()
            lastCheckedAt = now
            UserDefaults.standard.set(now, forKey: Self.lastCheckDefaultsKey)
        }

        let trimmedRepo = githubRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty,
              let apiURL = URL(string: "https://api.github.com/repos/\(trimmedRepo)/releases/latest") else {
            availableRelease = nil
            statusMessage = "v\(currentVersion) · Set a GitHub repo (owner/repo) to check app releases, or update Homebrew below."
            return
        }

        do {
            var req = URLRequest(url: apiURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "Upkeep.Updater", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Could not reach GitHub Releases for \(trimmedRepo)."
                ])
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Upkeep.Updater", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid release manifest."
                ])
            }

            let rawTag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let body = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))

            var zipAssetURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.lowercased().hasSuffix(".zip"),
                       let urlStr = asset["browser_download_url"] as? String,
                       let url = URL(string: urlStr) {
                        zipAssetURL = url
                        break
                    }
                }
            }

            if Self.isVersion(rawTag, newerThan: currentVersion) {
                availableRelease = AppReleaseInfo(
                    version: rawTag,
                    releaseNotes: body,
                    downloadURL: zipAssetURL,
                    htmlURL: htmlURL
                )
                statusMessage = "Update v\(rawTag) available (current v\(currentVersion))."
            } else {
                availableRelease = nil
                statusMessage = "Upkeep v\(currentVersion) is up to date."
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    public func installAvailableUpdate() async {
        guard let release = availableRelease, !isInstalling else { return }

        guard let downloadURL = release.downloadURL else {
            if let htmlURL = release.htmlURL {
                NSWorkspace.shared.open(htmlURL)
                statusMessage = "Opened release page in browser."
            }
            return
        }

        isInstalling = true
        errorMessage = nil
        statusMessage = "Downloading v\(release.version)…"

        defer { isInstalling = false }

        do {
            let (tempZipURL, dlResponse) = try await URLSession.shared.download(from: downloadURL)
            guard let http = dlResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "Upkeep.Updater", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to download update archive."
                ])
            }

            let fm = FileManager.default
            let workDir = fm.temporaryDirectory.appendingPathComponent("UpkeepUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

            statusMessage = "Extracting & verifying update…"
            let dittoRes = try await CLIExecutor.run(binary: "ditto", arguments: ["-xk", tempZipURL.path, workDir.path])
            guard dittoRes.succeeded else {
                throw NSError(domain: "Upkeep.Updater", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to extract update archive: \(dittoRes.stderr)"
                ])
            }

            guard let newAppURL = Self.findAppBundle(in: workDir) else {
                throw NSError(domain: "Upkeep.Updater", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Downloaded archive does not contain Upkeep.app."
                ])
            }

            // Strip quarantine & verify code signature before swapping asynchronously
            _ = try? await CLIExecutor.run(binary: "xattr", arguments: ["-dr", "com.apple.quarantine", newAppURL.path])

            let verifyRes = try await CLIExecutor.run(binary: "codesign", arguments: ["--verify", "--deep", "--strict", newAppURL.path])
            guard verifyRes.succeeded else {
                throw NSError(domain: "Upkeep.Updater", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Downloaded app failed code signature verification."
                ])
            }

            let currentAppURL = Bundle.main.bundleURL
            guard currentAppURL.pathExtension == "app" else {
                NSWorkspace.shared.activateFileViewerSelecting([newAppURL])
                statusMessage = "Downloaded v\(release.version). Replace your binary manually."
                return
            }

            statusMessage = "Installing & relaunching…"
            // Hand off swap + relaunch to a detached shell process after current PID exits with safe rollback
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
            mv "$1" "$1.old" 2>/dev/null || true
            if mv "$2" "$1"; then
                rm -rf "$1.old" 2>/dev/null || true
                open -n "$1"
            else
                mv "$1.old" "$1" 2>/dev/null || true
            fi
            """
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            helper.arguments = ["-c", script, "sh", currentAppURL.path, newAppURL.path]
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    public func updateCLIUtilities() async {
        guard !isInstalling else { return }
        isInstalling = true
        errorMessage = nil
        statusMessage = "Updating Homebrew…"

        defer { isInstalling = false }

        guard BrewService.isInstalled() else {
            statusMessage = "Homebrew CLI not found."
            return
        }

        do {
            _ = try await BrewService.shared.updateBrew()
            statusMessage = "Homebrew index updated."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    private static func findAppBundle(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator where url.pathExtension == "app" {
            return url
        }
        return nil
    }

    public static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        func parse(_ raw: String) -> (nums: [Int], prerelease: String?) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
            let parts = trimmed.split(separator: "-", maxSplits: 1)
            let nums = parts[0].split(separator: ".").compactMap { Int($0) }
            let pre = parts.count > 1 ? String(parts[1]) : nil
            return (nums, pre)
        }
        let l = parse(lhs)
        let r = parse(rhs)
        let count = max(l.nums.count, r.nums.count)
        for i in 0..<count {
            let lv = i < l.nums.count ? l.nums[i] : 0
            let rv = i < r.nums.count ? r.nums[i] : 0
            if lv != rv { return lv > rv }
        }
        // Same numeric version: release (nil) > prerelease (non-nil)
        if l.prerelease == nil && r.prerelease != nil { return true }
        if l.prerelease != nil && r.prerelease == nil { return false }
        if let lp = l.prerelease, let rp = r.prerelease {
            return lp.localizedStandardCompare(rp) == .orderedDescending
        }
        return false
    }
}
