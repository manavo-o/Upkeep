import AppKit
import Darwin
import Observation

/// Retires process-lifetime UI caches once the app is idle. A replacement acquires
/// any active power assertion before the old process is allowed to terminate.
@MainActor
@Observable
public final class IdleMemoryRecovery: NSObject {
    public static let shared = IdleMemoryRecovery()
    public var isStatusItemInserted = ProcessInfo.processInfo.environment[handoffKey] == nil

    private static let handoffKey = "UPKEEP_MEMORY_HANDOFF"
    private static let idleBudget: UInt64 = 24 * 1024 * 1024

    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var trackingMenus = 0
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var replacement: Process?
    @ObservationIgnored private var handoffDirectory: URL?
    @ObservationIgnored private var restoredSession: Session?
    @ObservationIgnored private var handoffToken: UUID?

    private struct Session: Codable {
        let parentPID: Int32
        let statusItemInserted: Bool
        let awakeActive: Bool
        let awakeMode: String
        let awakeExpiry: Date?
        let selectedAwakeMode: String
        let activeSection: String
        let promptedForAccessibility: Bool
        let accessibilityDenied: Bool
        let cleaningDuration: Int
        let cleaningDimScreen: Bool
        let cleaningLockPointer: Bool
        let appQuery: String
        let appSortOrder: String
        let includePersonalData: Bool
        let lastCleanResult: CleanExecutionResult?
        let cleanError: String?
        let uninstallStatus: String?
        let uninstallError: String?
        let brewStatus: String?
        let brewError: String?
        let updateRelease: AppReleaseInfo?
        let updateStatus: String?
        let updateError: String?

        @MainActor init() {
            let awake = KeepAwakeManager.shared
            let vm = HUDCoordinator.shared.trayViewModel
            let updater = UpdateManager.shared
            parentPID = getpid()
            statusItemInserted = IdleMemoryRecovery.shared.isStatusItemInserted
            awakeActive = awake.isActive
            awakeMode = awake.mode.rawValue
            awakeExpiry = awake.expiresAt
            selectedAwakeMode = vm.selectedAwakeMode.rawValue
            activeSection = vm.activeSection.rawValue
            promptedForAccessibility = CleaningModeManager.shared.hasPromptedThisSession
            accessibilityDenied = CleaningModeManager.shared.permissionDenied
            cleaningDuration = vm.cleaningDuration
            cleaningDimScreen = vm.cleaningDimScreen
            cleaningLockPointer = vm.cleaningLockPointer
            appQuery = vm.appQuery
            appSortOrder = vm.appSortOrder.rawValue
            includePersonalData = vm.includePersonalData
            lastCleanResult = vm.lastCleanResult
            cleanError = vm.cleanError
            uninstallStatus = vm.uninstallStatus
            uninstallError = vm.uninstallError
            brewStatus = vm.brewStatusText
            brewError = vm.brewErrorText
            updateRelease = updater.availableRelease
            updateStatus = updater.statusMessage
            updateError = updater.errorMessage
        }

        @MainActor func restore() {
            let vm = HUDCoordinator.shared.trayViewModel
            vm.selectedAwakeMode = KeepAwakeMode(rawValue: selectedAwakeMode) ?? .displayAndSystem
            vm.activeSection = TraySection(rawValue: activeSection) ?? .general
            vm.cleaningDuration = cleaningDuration
            vm.cleaningDimScreen = cleaningDimScreen
            vm.cleaningLockPointer = cleaningLockPointer
            vm.appQuery = appQuery
            vm.appSortOrder = TrayViewModel.AppSortOrder(rawValue: appSortOrder) ?? .name
            vm.includePersonalData = includePersonalData
            vm.lastCleanResult = lastCleanResult
            vm.cleanError = cleanError
            vm.uninstallStatus = uninstallStatus
            vm.uninstallError = uninstallError
            vm.brewStatusText = brewStatus
            vm.brewErrorText = brewError
            UpdateManager.shared.restorePresentation(release: updateRelease, status: updateStatus, error: updateError)
            CleaningModeManager.shared.restorePromptState(prompted: promptedForAccessibility, denied: accessibilityDenied)
            KeepAwakeManager.shared.restoreSession(isActive: awakeActive, mode: KeepAwakeMode(rawValue: awakeMode) ?? .displayAndSystem, expiresAt: awakeExpiry)
        }

        @MainActor var powerStateStillMatches: Bool {
            let awake = KeepAwakeManager.shared
            return awake.isActive == awakeActive && awake.mode.rawValue == awakeMode && awake.expiresAt == awakeExpiry
        }
    }

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
    }

    /// Called by the app entry point, including in the replacement process.
    public func start() {
        enabled = true
        guard let rawToken = ProcessInfo.processInfo.environment[Self.handoffKey],
              let token = UUID(uuidString: rawToken) else {
            isStatusItemInserted = true
            return
        }
        let file = Self.directory(for: token).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: file),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.parentPID == getppid() else {
            // An invalid handoff must not create a second visible app instance.
            Foundation.exit(1)
        }
        restoredSession = session
        handoffToken = token
        unsetenv(Self.handoffKey)
        session.restore()
    }

    /// Keep the new status item hidden until the old process has exited.
    public func finishRestoration() async {
        guard let session = restoredSession, let token = handoffToken else { return }
        let directory = Self.directory(for: token)
        let ready = directory.appendingPathComponent("ready")
        do {
            try Data().write(to: ready, options: .atomic)
        } catch {
            NSApp.terminate(nil)
            return
        }
        for _ in 0..<100 {
            if getppid() != session.parentPID {
                let committed = FileManager.default.fileExists(atPath: directory.appendingPathComponent("commit").path)
                try? FileManager.default.removeItem(at: directory)
                guard committed else {
                    NSApp.terminate(nil)
                    return
                }
                restoredSession = nil
                handoffToken = nil
                isStatusItemInserted = session.statusItemInserted
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The original process still owns the session if the handoff did not commit.
        try? FileManager.default.removeItem(at: directory)
        NSApp.terminate(nil)
    }

    public func schedule() {
        guard enabled else { return }
        diagnostic("scheduled")
        cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            while true {
                let catalogBusy = await BrewService.shared.hasPendingCatalogWork
                guard !Task.isCancelled else { return }
                #if DEBUG
                self.diagnostic("eligible=\(self.canRecover) catalog=\(catalogBusy) open=\(HUDCoordinator.shared.hasOpenUserWindows) windows=\(NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }.map { $0.className }) menus=\(self.trackingMenus) cli=\(CLIExecutor.hasRunningCommands) footprint=\(Self.footprint)")
                #endif
                if self.canRecover && !catalogBusy { break }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            guard Self.footprint > Self.idleBudget else { return }
            HUDCoordinator.shared.trayViewModel.releaseTransientCaches()
            await self.replaceProcess()
        }
    }

    public func cancel() {
        recoveryTask?.cancel()
        recoveryTask = nil
        if let replacement, replacement.isRunning { replacement.terminate() }
        replacement = nil
        if let handoffDirectory { try? FileManager.default.removeItem(at: handoffDirectory) }
        handoffDirectory = nil
    }

    private var canRecover: Bool {
        let vm = HUDCoordinator.shared.trayViewModel
        let updater = UpdateManager.shared
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
        return !hasWindow && !HUDCoordinator.shared.hasOpenUserWindows
            && trackingMenus == 0 && NSApp.modalWindow == nil
            && !CleaningModeManager.shared.isLocked
            && !KeepAwakeManager.shared.closedLid.isEngaged
            && !CLIExecutor.hasRunningCommands && vm.pendingUninstallApp == nil
            && !BrewLogStore.shared.isRunning && !HUDCoordinator.shared.homebrewModel.isOperating
            && !vm.isRefreshingBrew && !vm.isHomebrewBusy
            && !vm.isScanningClean && !vm.isCleaning && !vm.isLoadingApps && !vm.isUpdatingAppSizes
            && !vm.isInspectingUninstall && !vm.isUninstallingApp
            && !updater.isChecking && !updater.isInstalling && !updater.isUpdatingHomebrew
    }

    private func replaceProcess() async {
        guard let executable = Bundle.main.executableURL else { return }
        let token = UUID()
        let directory = Self.directory(for: token)
        let process = Process()
        var committed = false
        defer {
            if replacement === process { replacement = nil }
            if handoffDirectory == directory { handoffDirectory = nil }
            if !committed { try? FileManager.default.removeItem(at: directory) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let session = Session()
            try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
            var environment = ProcessInfo.processInfo.environment
            environment[Self.handoffKey] = token.uuidString
            process.executableURL = executable
            process.environment = environment
            replacement = process
            handoffDirectory = directory
            try process.run()
            let ready = directory.appendingPathComponent("ready")
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(100))
                guard process.isRunning, canRecover, session.powerStateStillMatches else { break }
                if FileManager.default.fileExists(atPath: ready.path) {
                    // The replacement has restored the session and acquired its power assertion.
                    try Data().write(to: directory.appendingPathComponent("commit"), options: .atomic)
                    committed = true
                    replacement = nil
                    handoffDirectory = nil
                    NSApp.terminate(nil)
                    return
                }
            }
        } catch {
            diagnostic("handoff failed: \(error)")
            // Keep the original process and its services if startup or handoff fails.
        }
        if process.isRunning { process.terminate() }
    }

    private static func directory(for token: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("upkeep-memory-\(token.uuidString)", isDirectory: true)
    }

    private static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func diagnostic(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["UPKEEP_MEMORY_TEST_DIRECTORY"] != nil {
            FileHandle.standardError.write(Data("Memory recovery \(getpid()): \(message)\n".utf8))
        }
        #endif
    }

    @objc private func menuBegan() {
        trackingMenus += 1
        cancel()
    }

    @objc private func menuEnded() {
        trackingMenus = max(0, trackingMenus - 1)
        if trackingMenus == 0 && !HUDCoordinator.shared.hasOpenUserWindows { schedule() }
    }
    @objc private func applicationWillTerminate() { cancel() }
}
