import AppIntents
import AppKit
import SwiftUI

@main
struct UpkeepApp: App {
    @State private var keepAwake = KeepAwakeManager.shared
    private let coordinator = HUDCoordinator.shared

    init() {
        UpkeepShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "sparkles")
                .renderingMode(.template)
                .accessibilityLabel(keepAwake.isActive ? "Upkeep: Caffeinated" : "Upkeep")
        }
        .menuBarExtraStyle(.menu)
    }
}
