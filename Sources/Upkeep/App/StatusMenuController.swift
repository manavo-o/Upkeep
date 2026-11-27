import AppKit
import Observation

/// Rebuilds commands when the menu opens. Only the fixed-width status row updates during tracking.
@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let coordinator: HUDCoordinator
    private var statusItem: NSStatusItem?
    private let keepAwake = KeepAwakeManager.shared
    private let cleaning = CleaningModeManager.shared
    private let updater = UpdateManager.shared
    private let recovery = IdleMemoryRecovery.shared
    private var vm: TrayViewModel { coordinator.trayViewModel }
    private var countdownField: NSTextField?
    private var countdownTimer: Timer?
    private var isTracking = false

    public init(coordinator: HUDCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    public func install() {
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        self.statusItem = statusItem
        menuNeedsUpdate(menu)
        observeStatusItem()
    }

    private func observeStatusItem() {
        guard let statusItem else { return }
        withObservationTracking {
            statusItem.isVisible = recovery.isStatusItemInserted
            let symbol = keepAwake.isActive ? "cup.and.saucer.fill" : "arrow.up.circle"
            statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            statusItem.button?.setAccessibilityLabel(keepAwake.isActive ? "Upkeep, Caffeinate active" : "Upkeep")
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatusItem() }
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isTracking else { return }
        menu.removeAllItems()
        let identity = NSMenuItem(title: "Upkeep v\(updater.currentVersion)", action: nil, keyEquivalent: "")
        identity.isEnabled = false
        menu.addItem(identity)
        countdownField = nil
        if keepAwake.isActive {
            menu.addItem(makeCountdownItem())
        }
        if !cleaning.hasAccessibility || cleaning.permissionDenied {
            menu.addItem(command("Grant Accessibility Access…") { controller in
                controller.cleaning.openAccessibilitySettings()
            })
        }
        if let release = updater.availableRelease {
            menu.addItem(command("Update Available (v\(release.version))…") { controller in
                controller.coordinator.showMainWindow(section: .updates)
            })
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Caffeinate", items: caffeinateCommands()))
        let cleanKeysTitle = cleaning.isLocked ? "Clean Keys (\(cleaning.remainingSeconds)s)" : "Clean Keys"
        menu.addItem(submenu(cleanKeysTitle, items: cleanKeysCommands()))
        menu.addItem(command("Search Homebrew…") { controller in controller.coordinator.showHomebrewHUD() })
        if vm.isUpgradingBrew {
            menu.addItem(command("View Homebrew Upgrade…") { controller in
                controller.coordinator.showMainWindowForHomebrewActivity()
            })
        } else if vm.brewOutdatedCount > 0 {
            menu.addItem(command("Upgrade \(vm.brewOutdatedCount) Outdated Packages…", enabled: !vm.isHomebrewBusy) { controller in
                controller.coordinator.showHomebrewUpgrade()
            })
        }
        menu.addItem(.separator())

        menu.addItem(command("Cleaner…") { controller in controller.coordinator.showMainWindow(section: .cleaner) })
        menu.addItem(command("Uninstaller…") { controller in controller.coordinator.showMainWindow(section: .uninstaller) })
        menu.addItem(.separator())

        menu.addItem(command("Open Upkeep…", key: ",", symbol: "gearshape") { controller in
            controller.coordinator.showMainWindow()
        })
        menu.addItem(command("Check for Updates…") { controller in
            controller.coordinator.showMainWindow(section: .updates, triggerUpdateCheck: true)
        })
        menu.addItem(.separator())

        menu.addItem(command("Restart Upkeep") { controller in controller.coordinator.restartApp() })
        menu.addItem(command("Quit Upkeep", key: "q") { controller in controller.coordinator.quitApp() })
    }

    public func menuWillOpen(_ menu: NSMenu) {
        isTracking = true
        recovery.cancel()
        guard countdownField != nil, keepAwake.expiresAt != nil else { return }
        updateCountdown()
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCountdown() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        countdownTimer = timer
    }

    public func menuDidClose(_ menu: NSMenu) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isTracking = false
        recovery.schedule()
    }

    private func makeCountdownItem() -> NSMenuItem {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        field.textColor = .secondaryLabelColor
        field.frame = NSRect(x: 14, y: 3, width: 166, height: 16)
        field.lineBreakMode = .byTruncatingTail
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 194, height: 22))
        row.addSubview(field)
        countdownField = field
        updateCountdown()
        let item = NSMenuItem(title: "Caffeinate status", action: nil, keyEquivalent: "")
        item.view = row
        return item
    }

    private func updateCountdown() {
        guard let countdownField else { return }
        let title: String
        if !keepAwake.isActive || keepAwake.remainingSeconds == 0 {
            title = "Caffeinate ended"
        } else if let seconds = keepAwake.remainingSeconds {
            title = String(format: "Awake for %02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        } else {
            title = "Awake indefinitely"
        }
        if countdownField.stringValue != title {
            countdownField.stringValue = title
        }
    }

    private func caffeinateCommands() -> [NSMenuItem] {
        let primary = keepAwake.isActive
            ? command("Turn Off Caffeinate") { controller in controller.keepAwake.stop() }
            : command("Start Caffeinate (1 Hour)") { controller in controller.startCaffeinate(minutes: 60) }
        let durations: [(String, Int?)] = [("30 Minutes", 30), ("1 Hour", 60), ("2 Hours", 120), ("Indefinitely", nil)]
        let choices = durations.map { title, minutes in
            let selected: Bool
            if let minutes, let seconds = keepAwake.remainingSeconds {
                selected = abs(seconds - minutes * 60) <= 60
            } else {
                selected = keepAwake.isActive && minutes == nil && keepAwake.expiresAt == nil
            }
            return command(title, checked: selected) { controller in controller.startCaffeinate(minutes: minutes) }
        }
        let displayAwake = command("Keep Display Awake", checked: vm.selectedAwakeMode == .displayAndSystem) { controller in
            let mode: KeepAwakeMode = controller.vm.selectedAwakeMode == .displayAndSystem ? .systemOnly : .displayAndSystem
            controller.vm.selectedAwakeMode = mode
            if controller.keepAwake.isActive {
                controller.keepAwake.restoreSession(isActive: true, mode: mode, expiresAt: controller.keepAwake.expiresAt)
            }
        }
        let closedLid = keepAwake.closedLid.state
        let lidCommand = command(
            closedLid == .active ? "Keep Awake With Lid Closed" : "Keep Awake With Lid Closed…",
            enabled: closedLid != .authorizing && closedLid != .stopping,
            checked: closedLid == .active
        ) { controller in
            controller.keepAwake.toggleClosedLid(mode: controller.vm.selectedAwakeMode)
        }
        var options = [displayAwake, lidCommand]
        if case .failed(let message) = closedLid {
            options.append(command(message, enabled: false) { _ in })
        }
        return [primary, .separator()] + choices + [.separator()] + options
    }

    private func startCaffeinate(minutes: Int?) {
        keepAwake.start(durationMinutes: minutes, mode: vm.selectedAwakeMode)
    }

    private func cleanKeysCommands() -> [NSMenuItem] {
        let primary: NSMenuItem
        if cleaning.permissionDenied || !cleaning.hasAccessibility {
            primary = command("Grant Accessibility Access…") { controller in controller.cleaning.openAccessibilitySettings() }
        } else if cleaning.isLocked {
            primary = command("Unlock Keyboard") { controller in controller.cleaning.stop() }
        } else {
            let duration = vm.cleaningDuration == 120 ? "2m" : "\(vm.cleaningDuration)s"
            primary = command("Lock Keyboard (\(duration))") { controller in
                controller.cleaning.start(
                    durationSeconds: controller.vm.cleaningDuration,
                    dimScreen: controller.vm.cleaningDimScreen,
                    lockPointer: controller.vm.cleaningLockPointer
                )
            }
        }
        let durations = [("30 Seconds", 30), ("60 Seconds", 60), ("2 Minutes", 120)]
        let choices = durations.map { title, seconds in
            command(title, checked: vm.cleaningDuration == seconds) { controller in controller.vm.cleaningDuration = seconds }
        }
        return [primary, .separator()] + choices + [
            .separator(),
            command("Dim Screen While Locked", checked: vm.cleaningDimScreen) { controller in controller.vm.cleaningDimScreen.toggle() },
            command("Lock Pointer", checked: vm.cleaningLockPointer) { controller in controller.vm.cleaningLockPointer.toggle() }
        ]
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private func command(
        _ title: String, key: String = "", symbol: String? = nil,
        enabled: Bool = true, checked: Bool = false, action: @escaping @MainActor (StatusMenuController) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = action
        item.isEnabled = enabled
        item.state = checked ? .on : .off
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func performCommand(_ item: NSMenuItem) {
        (item.representedObject as? @MainActor (StatusMenuController) -> Void)?(self)
    }
}
