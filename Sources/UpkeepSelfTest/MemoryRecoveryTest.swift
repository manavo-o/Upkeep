import AppKit
import Darwin
import SwiftUI
import UpkeepCore

/// An opt-in process-level regression. Run UpkeepSelfTest --memory-recovery.
/// It exercises deferred recovery, reopening, and the Caffeinate handoff across execs.
struct MemoryRecoveryTestApp: App {
    @State private var recovery = IdleMemoryRecovery.shared
    private let coordinator = HUDCoordinator.shared

    init() {
        let isReplacement = ProcessInfo.processInfo.environment["UPKEEP_MEMORY_HANDOFF"] != nil
        IdleMemoryRecovery.shared.start()
        Task { @MainActor in
            if isReplacement && ProcessInfo.processInfo.environment["UPKEEP_MEMORY_TEST_HANDOFF"] == "timeout" {
                try? await Task.sleep(for: .seconds(15))
                NSApp.terminate(nil)
                return
            }
            await IdleMemoryRecovery.shared.finishRestoration()
            if isReplacement {
                await MemoryRecoveryTest.verifyReplacement()
            } else {
                await MemoryRecoveryTest.runOriginal()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $recovery.isStatusItemInserted) {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(systemName: "cup.and.saucer")
        }.menuBarExtraStyle(.menu)
    }
}

@MainActor enum MemoryRecoveryTest {
    private struct Expected: Codable {
        let originalPID: Int32
        let expiry: Date?
        let awakeActive: Bool
    }

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["UPKEEP_MEMORY_TEST_DIRECTORY"]!, isDirectory: true)
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func record(_ name: String, _ values: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    static func runOriginal() async {
        await wait(2)
        let coordinator = HUDCoordinator.shared
        let vm = coordinator.trayViewModel
        KeepAwakeManager.shared.start(durationMinutes: 30, mode: .systemOnly)
        if ProcessInfo.processInfo.environment["UPKEEP_MEMORY_TEST_AWAKE"] == "0" {
            KeepAwakeManager.shared.stop()
        }
        let expected = Expected(originalPID: getpid(), expiry: KeepAwakeManager.shared.expiresAt, awakeActive: KeepAwakeManager.shared.isActive)
        try! JSONEncoder().encode(expected).write(to: directory.appendingPathComponent("expected.json"), options: .atomic)
        coordinator.showMainWindow(section: .homebrew)
        await wait(3)
        coordinator.closeMainWindow()

        // The idle timer must wait for an active operation.
        vm.isUpgradingBrew = true
        await wait(10)
        record("busy-guard", ["passed": true, "pid": getpid()])
        vm.isUpgradingBrew = false

        // Reopening must cancel the previously scheduled replacement.
        coordinator.showMainWindow(section: .homebrew)
        await wait(9)
        record("reopen-guard", ["passed": true, "pid": getpid()])
        let settingsWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }!
        settingsWindow.miniaturize(nil)
        IdleMemoryRecovery.shared.schedule()
        await wait(9)
        record("minimized-guard", ["passed": settingsWindow.isMiniaturized, "pid": getpid()])
        settingsWindow.deminiaturize(nil)
        await wait(1)
        vm.cleaningDuration = 120
        vm.cleaningDimScreen = false
        vm.cleaningLockPointer = true
        vm.selectedAwakeMode = .systemOnly
        vm.includePersonalData = true
        vm.appSortOrder = .size
        vm.lastCleanResult = .empty(dryRun: true)
        vm.cleanError = "Memory test status"
        coordinator.closeMainWindow()

        // This command outlives the idle grace period without a UI busy flag.
        let command = Task { try await CLIExecutor.run(binary: "sleep", arguments: ["11"]) }
        await wait(9)
        record("command-guard", ["passed": true, "pid": getpid()])
        _ = try? await command.value
        record("command-finished", ["pid": getpid()])
        await wait(20)
        if ProcessInfo.processInfo.environment["UPKEEP_MEMORY_TEST_HANDOFF"] == "timeout" {
            let awake = KeepAwakeManager.shared
            record("result", [
                "passed": getpid() == expected.originalPID && awake.isActive == expected.awakeActive
                    && awake.mode == .systemOnly && awake.expiresAt == expected.expiry,
                "originalRetained": true,
                "pid": getpid()
            ])
        } else {
            record("result", ["passed": false, "error": "Original process did not recover"])
        }
        KeepAwakeManager.shared.stop()
        NSApp.terminate(nil)
    }

    static func verifyReplacement() async {
        await wait(2)
        let expected = try! JSONDecoder().decode(Expected.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
        let vm = HUDCoordinator.shared.trayViewModel
        let awake = KeepAwakeManager.shared
        let checks: [String: Bool] = [
            "newProcess": getpid() != expected.originalPID,
            "oldProcessExited": getppid() != expected.originalPID,
            "awakeActive": awake.isActive == expected.awakeActive,
            "awakeMode": awake.mode == .systemOnly,
            "exactExpiry": awake.expiresAt == expected.expiry,
            "selectedMode": vm.selectedAwakeMode == .systemOnly,
            "selectedSection": vm.activeSection == .homebrew,
            "cleaningPreferences": vm.cleaningDuration == 120 && !vm.cleaningDimScreen && vm.cleaningLockPointer,
            "uninstallerPreferences": vm.includePersonalData && vm.appSortOrder == .size,
            "lastCleanResult": vm.lastCleanResult == .empty(dryRun: true),
            "operationStatus": vm.cleanError == "Memory test status",
            "busyGuard": FileManager.default.fileExists(atPath: directory.appendingPathComponent("busy-guard.json").path),
            "reopenGuard": FileManager.default.fileExists(atPath: directory.appendingPathComponent("reopen-guard.json").path),
            "minimizedGuard": FileManager.default.fileExists(atPath: directory.appendingPathComponent("minimized-guard.json").path),
            "commandGuard": FileManager.default.fileExists(atPath: directory.appendingPathComponent("command-guard.json").path),
            "commandFinished": FileManager.default.fileExists(atPath: directory.appendingPathComponent("command-finished.json").path),
            "statusItemRestored": IdleMemoryRecovery.shared.isStatusItemInserted,
            "handoffEnvironmentCleared": ProcessInfo.processInfo.environment["UPKEEP_MEMORY_HANDOFF"] == nil
        ]
        record("result", ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "pid": getpid(), "usingIOKit": awake.usingIOKitAssertion])
        await wait(12)
        awake.stop()
        NSApp.terminate(nil)
    }
}
