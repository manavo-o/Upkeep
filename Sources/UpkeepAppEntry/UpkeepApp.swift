import AppKit
import UpkeepCore

@main
@MainActor
enum UpkeepApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let recovery = IdleMemoryRecovery.shared
        recovery.start()
        let coordinator = HUDCoordinator.shared
        let appDelegate = UpkeepApplicationDelegate(coordinator: coordinator)
        app.delegate = appDelegate
        coordinator.installMainMenuIfNeeded()
        let statusMenu = StatusMenuController(coordinator: coordinator)
        statusMenu.install()
        Task { @MainActor in
            await recovery.finishRestoration()
            CleaningModeManager.shared.refreshPermissionStatus()
            coordinator.trayViewModel.refreshOverview()
            UpdateManager.shared.checkIfDue()
        }

        withExtendedLifetime((appDelegate, statusMenu)) {
            app.run()
        }
    }
}

@MainActor
private final class UpkeepApplicationDelegate: NSObject, NSApplicationDelegate {
    private let coordinator: HUDCoordinator

    init(coordinator: HUDCoordinator) {
        self.coordinator = coordinator
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.showMainWindow()
        return false
    }
}
