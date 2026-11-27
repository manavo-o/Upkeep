import AppKit
import Observation

/// Rebuilds commands on open and updates Caffeinate in place while the menu tracks.
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
    private var durationControl: CaffeinateDurationControl?
    private weak var caffeinatePrimary: NSMenuItem?
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
        countdownField = nil
        durationControl = nil
        if #available(macOS 27.0, *) {
            let control = makeDurationControl()
            durationControl = control
            let item = NSMenuItem(title: "Caffeinate duration", action: nil, keyEquivalent: "")
            item.view = control
            menu.addItem(item)
            menu.addItem(.separator())
        } else if keepAwake.isActive {
            menu.addItem(makeCountdownItem())
        }
        caffeinatePrimary = nil
        if durationControl == nil {
            let primary = command(caffeinatePrimaryTitle) { controller in
                controller.applyCaffeinateDuration(controller.keepAwake.isActive ? 0 : 60)
            }
            caffeinatePrimary = primary
            menu.addItem(primary)
        }
        menu.addItem(cleanKeysPrimaryCommand())
        menu.addItem(command("Search Homebrew…") { controller in controller.coordinator.showHomebrewHUD() })
        if let release = updater.availableRelease {
            menu.addItem(command("Update Available (v\(release.version))…") { controller in
                controller.coordinator.showMainWindow(section: .updates)
            })
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Clean Keys Options", items: cleanKeysCommands()))
        if vm.isUpgradingBrew {
            menu.addItem(command("View Homebrew Upgrade…") { controller in
                controller.coordinator.showMainWindowForHomebrewActivity()
            })
        } else if vm.brewOutdatedCount > 0 {
            menu.addItem(command("Upgrade \(vm.brewOutdatedCount) Outdated Packages…", enabled: !vm.isHomebrewBusy) { controller in
                controller.coordinator.showHomebrewUpgrade()
            })
        }
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
        updateCountdown()
        updateCountdownTimer()
    }

    private func updateCountdownTimer() {
        let needsTimer = isTracking && keepAwake.expiresAt != nil
        guard needsTimer else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        guard countdownTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateCountdown()
                self?.updateCountdownTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        countdownTimer = timer
    }

    public func menuDidClose(_ menu: NSMenu) {
        isTracking = false
        updateCountdownTimer()
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
        let title = caffeinateStatus
        if let countdownField, countdownField.stringValue != title {
            countdownField.stringValue = title
        }
        durationControl?.setStatus(title, isActive: keepAwake.isActive)
        if let caffeinatePrimary, caffeinatePrimary.title != caffeinatePrimaryTitle {
            caffeinatePrimary.title = caffeinatePrimaryTitle
        }
    }

    private var caffeinatePrimaryTitle: String {
        keepAwake.isActive ? "Turn Off Caffeinate" : "Start Caffeinate (1 Hour)"
    }

    private var caffeinateStatus: String {
        if !keepAwake.isActive || keepAwake.remainingSeconds == 0 {
            return "Off"
        } else if let seconds = keepAwake.remainingSeconds {
            return String(format: "Awake for %02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        } else {
            return "Awake indefinitely"
        }
    }

    private func makeDurationControl() -> CaffeinateDurationControl {
        let control = CaffeinateDurationControl(currentMinutes: { [weak self] in
            guard let awake = self?.keepAwake, awake.isActive else { return 0 }
            return awake.remainingSeconds.map { max(15, ($0 + 59) / 60) } ?? 60
        }) { [weak self] minutes in
            guard let self, self.isTracking else { return }
            self.applyCaffeinateDuration(minutes)
        }
        control.setStatus(caffeinateStatus, isActive: keepAwake.isActive)
        return control
    }

    private func applyCaffeinateDuration(_ minutes: Int) {
        if minutes == 0 {
            keepAwake.stop()
        } else {
            keepAwake.applyDuration(minutes: minutes, mode: vm.selectedAwakeMode)
        }
        updateCountdown()
        updateCountdownTimer()
    }

    private func cleanKeysPrimaryCommand() -> NSMenuItem {
        if cleaning.isLocked {
            return command("Unlock Keyboard") { controller in controller.cleaning.stop() }
        }
        if cleaning.permissionDenied || !cleaning.hasAccessibility {
            return command("Grant Accessibility Access…") { controller in controller.cleaning.openAccessibilitySettings() }
        }
        let duration = vm.cleaningDuration == 120 ? "2m" : "\(vm.cleaningDuration)s"
        return command("Lock Keyboard (\(duration))") { controller in
            controller.cleaning.start(
                durationSeconds: controller.vm.cleaningDuration,
                dimScreen: controller.vm.cleaningDimScreen,
                lockPointer: controller.vm.cleaningLockPointer
            )
        }
    }

    private func cleanKeysCommands() -> [NSMenuItem] {
        let durations = [("30 Seconds", 30), ("60 Seconds", 60), ("2 Minutes", 120)]
        let choices = durations.map { title, seconds in
            command(title, checked: vm.cleaningDuration == seconds) { controller in controller.vm.cleaningDuration = seconds }
        }
        return choices + [
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
