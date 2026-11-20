import AppKit
import SwiftUI
import UpkeepCore

@main
struct UpkeepApp: App {
    @State private var keepAwake = KeepAwakeManager.shared
    private let coordinator = HUDCoordinator.shared

    init() {
        Task { @MainActor in
            CleaningModeManager.shared.refreshPermissionStatus()
            HUDCoordinator.shared.trayViewModel.refreshOverview()
            UpdateManager.shared.checkIfDue()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "arrow.up.circle")
                .renderingMode(.template)
                .accessibilityLabel(keepAwake.isActive ? "Upkeep: Caffeinated" : "Upkeep")
        }
        .menuBarExtraStyle(.menu)
    }
}
