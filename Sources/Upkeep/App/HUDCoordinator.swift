import AppKit
import Darwin
import SwiftUI

@MainActor
public final class HUDCoordinator: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    public static let shared = HUDCoordinator()

    public let trayViewModel = TrayViewModel()
    public let homebrewModel = HomebrewHUDModel()
    let settingsSearch = UpkeepSearchEngine()

    private var mainWindowController: NSWindowController?
    private weak var settingsSearchItem: NSSearchToolbarItem?
    private weak var settingsBackItem: NSToolbarItem?
    private weak var settingsForwardItem: NSToolbarItem?
    private var settingsBackStack: [TraySection] = []
    private var settingsForwardStack: [TraySection] = []
    private var homebrewPanel: LiquidGlassPanel?
    private var homebrewHUD: HomebrewHUDView?
    private var homebrewPrewarmTask: Task<Void, Never>?
    private var homebrewGlobalClickMonitor: Any?
    private var homebrewLocalClickMonitor: Any?
    private var cleaningPanel: LiquidGlassPanel?
    private var dimmingWindows: [NSWindow] = []

    private override init() {
        super.init()
        homebrewModel.onCatalogChanged = { [weak self] in
            self?.trayViewModel.refreshOverview(force: true)
        }
        homebrewModel.onOpenInSettings = { [weak self] in
            self?.hideHomebrewHUD()
            self?.showMainWindow(section: .homebrew)
        }
        CleaningModeManager.shared.setStateHandler { [weak self] isLocked in
            if isLocked {
                self?.showCleaningHUD()
            } else {
                self?.hideCleaningHUD()
            }
        }
        // Evict any initial launch-check catalog slab after 10s so idle menu-bar RSS stays minimal.
        Task(priority: .background) {
            try? await Task.sleep(for: .seconds(10))
            if self.mainWindowController == nil && self.homebrewPanel?.isVisible != true {
                await BrewService.shared.evictRemoteCatalogIfIdle()
            }
        }
    }

    var hasOpenUserWindows: Bool {
        mainWindowController != nil || homebrewPanel != nil || cleaningPanel != nil
    }

    // MARK: - Dedicated macOS 27 Native Window (Upkeep)

    public func showMainWindow(section: TraySection? = nil, triggerUpdateCheck: Bool = false) {
        hideHomebrewHUD()
        IdleMemoryRecovery.shared.cancel()
        if let section {
            selectSettingsSection(section)
        }

        let isNewWindow = mainWindowController == nil
        if isNewWindow {
            let rootView = MainWindowView(vm: trayViewModel, coordinator: self)
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.sizingOptions = []
            let initialSize = NSSize(width: 1018, height: 720)

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: initialSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentMinSize = NSSize(width: 918, height: 600)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.title = trayViewModel.activeSection.settingsTitle
            window.subtitle = trayViewModel.activeSection.subtitle
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = false
            window.toolbarStyle = .unified
            let toolbar = NSToolbar(identifier: "UpkeepSettings")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar

            window.setContentSize(initialSize)
            if !window.setFrameUsingName("UpkeepSettingsWindow") {
                window.center()
            }
            window.setFrameAutosaveName("UpkeepSettingsWindow")
            mainWindowController = NSWindowController(window: window)
            installMainMenuIfNeeded()
        }

        NSApp.setActivationPolicy(.regular)
        mainWindowController?.window?.animationBehavior =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()

        if !isNewWindow {
            trayViewModel.refreshOverview()
            CleaningModeManager.shared.refreshPermissionStatus()
        }

        if triggerUpdateCheck {
            Task {
                await UpdateManager.shared.checkForUpdates()
            }
        }
    }

    public func showHomebrewUpgrade() {
        showMainWindowForHomebrewActivity()
        trayViewModel.upgradeAllBrew()
    }

    func showMainWindowForHomebrewActivity() {
        trayViewModel.homebrewActivityRequest += 1
        showMainWindow(section: .homebrew)
        settingsSearch.reveal("brew.log", in: .homebrew)
    }

    public func closeMainWindow() {
        mainWindowController?.close()
    }

    public func restartApp() {
        KeepAwakeManager.shared.stop()
        CleaningModeManager.shared.stop()
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    @objc public func quitApp() {
        KeepAwakeManager.shared.stop()
        CleaningModeManager.shared.stop()
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == mainWindowController?.window {
            NSApp.setActivationPolicy(.regular)
            CleaningModeManager.shared.refreshPermissionStatus()
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == homebrewPanel, homebrewHUD?.isTrackingActions != true {
            hideHomebrewHUD()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == mainWindowController?.window else { return }
        // Release NSWindow, NSHostingController, Retina backing layers, and transient scan caches.
        window.makeFirstResponder(nil)
        settingsSearch.clear()
        settingsSearchItem = nil
        settingsBackItem = nil
        settingsForwardItem = nil
        settingsBackStack.removeAll()
        settingsForwardStack.removeAll()
        window.delegate = nil
        window.contentViewController = nil
        mainWindowController = nil
        trayViewModel.releaseTransientCaches()
        AppIconView.clearCache()
        if homebrewPanel?.isVisible != true {
            Task { await BrewService.shared.scheduleIdleEviction(afterSeconds: 5) }
        }
        NSApp.setActivationPolicy(.accessory)
        IdleMemoryRecovery.shared.schedule()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    // MARK: - NSToolbarDelegate

    func updateSettingsTitle(section: TraySection, resultCount: Int?) {
        guard let window = mainWindowController?.window else { return }
        if let resultCount {
            window.title = "Search Results"
            window.subtitle = resultCount == 1 ? "1 match" : "\(resultCount) matches"
        } else {
            window.title = section.settingsTitle
            window.subtitle = section.subtitle
        }
    }

    private static let findSettingsItem = NSToolbarItem.Identifier("FindSettings")
    private static let settingsHistoryItem = NSToolbarItem.Identifier("SettingsHistory")

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.settingsHistoryItem, .flexibleSpace, Self.findSettingsItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if identifier == Self.settingsHistoryItem {
            return makeSettingsHistoryItem()
        }
        guard identifier == Self.findSettingsItem else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        let field = NSSearchField(frame: .zero)
        field.placeholderString = "Search Settings"
        field.setAccessibilityLabel("Search Settings")
        field.setAccessibilityHelp("Use the up and down arrow keys to choose a result, then press Return.")
        field.delegate = self
        field.allowsExpansionToolTips = true
        item.label = "Search Settings"
        item.toolTip = "Find a setting (⌘F)"
        item.preferredWidthForSearchField = 224
        item.searchField = field
        settingsSearchItem = item
        return item
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField,
              field === settingsSearchItem?.searchField else { return }
        settingsSearch.query = field.stringValue
    }

    public func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if sender === settingsSearchItem?.searchField, sender.stringValue.isEmpty {
            settingsSearch.query = ""
        }
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === settingsSearchItem?.searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            dismissSettingsSearch()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let item = settingsSearch.highlightedItem ?? settingsSearch.results.first {
                revealSettingsItem(item)
            }
            return true
        case #selector(NSResponder.moveDown(_:)) where settingsSearch.isSearching:
            highlightSettingsResult(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)) where settingsSearch.isSearching:
            highlightSettingsResult(by: -1)
            return true
        default:
            return false
        }
    }

    func dismissSettingsSearch() {
        settingsSearch.clear()
        guard let item = settingsSearchItem else { return }
        item.searchField.stringValue = ""
        item.endSearchInteraction()
    }

    func revealSettingsItem(_ item: UpkeepSearchItem) {
        selectSettingsSection(item.tab)
        let isMissingBrewTarget = item.tab == .homebrew
            && ["brew.hud", "brew.outdated", "brew.log", "brew.diagnostics"].contains(item.id)
            && !BrewService.isInstalled()
        settingsSearch.reveal(isMissingBrewTarget ? "brew.unavailable" : item.id, in: item.tab)
        announceSettingsResult(item)
    }

    private func highlightSettingsResult(by offset: Int) {
        let previous = settingsSearch.highlightedItem
        settingsSearch.moveHighlight(by: offset)
        if let item = settingsSearch.highlightedItem, item != previous {
            announceSettingsResult(item)
        }
    }

    private func announceSettingsResult(_ item: UpkeepSearchItem) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        AccessibilityNotification.Announcement("\(item.title), \(item.tab.settingsTitle)").post()
    }

    func selectSettingsSection(_ section: TraySection) {
        dismissSettingsSearch()
        guard section != trayViewModel.activeSection else { return }
        if mainWindowController != nil {
            settingsBackStack.append(trayViewModel.activeSection)
            settingsForwardStack.removeAll()
        }
        trayViewModel.activeSection = section
        updateSettingsHistoryButtons()
    }

    private func makeSettingsHistoryItem() -> NSToolbarItemGroup {
        let back = makeSettingsHistoryButton("Back", symbol: "chevron.backward", action: #selector(goBackInSettings))
        let forward = makeSettingsHistoryButton("Forward", symbol: "chevron.forward", action: #selector(goForwardInSettings))
        let group = NSToolbarItemGroup(itemIdentifier: Self.settingsHistoryItem)
        group.label = "Settings History"
        group.isNavigational = true
        group.subitems = [back, forward]
        settingsBackItem = back
        settingsForwardItem = forward
        updateSettingsHistoryButtons()
        return group
    }

    private func makeSettingsHistoryButton(_ title: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Settings" + title))
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.label = title
        item.toolTip = title
        item.target = self
        item.action = action
        item.autovalidates = false
        return item
    }

    private func updateSettingsHistoryButtons() {
        settingsBackItem?.isEnabled = !settingsBackStack.isEmpty
        settingsForwardItem?.isEnabled = !settingsForwardStack.isEmpty
    }

    @objc private func goBackInSettings() {
        guard let section = settingsBackStack.popLast() else { return }
        dismissSettingsSearch()
        settingsForwardStack.append(trayViewModel.activeSection)
        trayViewModel.activeSection = section
        updateSettingsHistoryButtons()
    }

    @objc private func goForwardInSettings() {
        guard let section = settingsForwardStack.popLast() else { return }
        dismissSettingsSearch()
        settingsBackStack.append(trayViewModel.activeSection)
        trayViewModel.activeSection = section
        updateSettingsHistoryButtons()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackInSettings):
            !settingsBackStack.isEmpty
        case #selector(goForwardInSettings):
            !settingsForwardStack.isEmpty
        default:
            true
        }
    }

    @objc private func focusSettingsSearch() {
        if mainWindowController == nil { showMainWindow() }
        settingsSearchItem?.beginSearchInteraction()
    }

    @objc private func openSettingsFromMenu() {
        showMainWindow()
    }

    public func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "Upkeep")
        let settings = appMenu.addItem(withTitle: "Open Upkeep…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit Upkeep", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find Settings", action: #selector(focusSettingsSearch), keyEquivalent: "f")
        find.target = self
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Back", action: #selector(goBackInSettings), keyEquivalent: "[").target = self
        viewMenu.addItem(withTitle: "Forward", action: #selector(goForwardInSettings), keyEquivalent: "]").target = self
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Homebrew Floating HUD (Click-Outside Dismissal + Settings Handoff)

    public func showHomebrewHUD(initialQuery: String? = nil, initialTab: BrewHUDTab? = nil) {
        IdleMemoryRecovery.shared.cancel()
        // Pre-warm catalog.bin (~3-5ms) immediately on HUD open so the first keystroke is instant.
        homebrewPrewarmTask?.cancel()
        homebrewPrewarmTask = Task(priority: .userInitiated) { await BrewService.shared.prewarmIfNeeded() }
        homebrewModel.prepareForShow(query: initialQuery ?? "", tab: initialTab)
        if homebrewPanel == nil {
            let hud = HomebrewHUDView(model: homebrewModel) { [weak self] in
                self?.hideHomebrewHUD()
            } onCategoryChange: { [weak self] isCategory in
                self?.updateHomebrewPanelHeight(isCategoryMenu: isCategory)
            }
            let panel = LiquidGlassPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                level: .floating,
                content: hud
            )
            panel.hudShortcut = { [weak hud] event in hud?.handleShortcut(event) ?? false }
            panel.delegate = self
            homebrewHUD = hud
            homebrewPanel = panel
        }
        homebrewHUD?.prepareForShow()
        homebrewPanel?.presentCenteredAtHUDHeight()
        homebrewHUD?.focusSearch()
        installHomebrewClickOutsideMonitors()
    }

    public func hideHomebrewHUD() {
        guard let panel = homebrewPanel, let hud = homebrewHUD, hud.isPresented else { return }
        // Detach ownership before ending editing or closing, which can re-enter window delegates.
        homebrewPanel = nil
        homebrewHUD = nil
        homebrewPrewarmTask?.cancel()
        homebrewPrewarmTask = nil
        removeHomebrewClickOutsideMonitors()
        homebrewModel.resetForHide()
        hud.prepareForHide()
        panel.endEditing(for: nil)
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.hudShortcut = nil
        panel.delegate = nil
        panel.contentView = nil
        panel.isReleasedWhenClosed = false
        panel.close()
        IdleMemoryRecovery.shared.schedule()

        // Reuse the index for quick reopenings, then reclaim it even while Settings remains open.
        Task { await BrewService.shared.scheduleIdleEviction(afterSeconds: 2) }
    }

    private func installHomebrewClickOutsideMonitors() {
        guard homebrewLocalClickMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        homebrewGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissHomebrewIfClickOutside() }
        }

        homebrewLocalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            self?.dismissHomebrewIfClickOutside()
            return event
        }
    }

    private func dismissHomebrewIfClickOutside() {
        guard let panel = homebrewPanel, panel.isVisible, homebrewHUD?.isTrackingActions != true else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) {
            hideHomebrewHUD()
        }
    }

    private func removeHomebrewClickOutsideMonitors() {
        if let monitor = homebrewGlobalClickMonitor {
            NSEvent.removeMonitor(monitor)
            homebrewGlobalClickMonitor = nil
        }
        if let monitor = homebrewLocalClickMonitor {
            NSEvent.removeMonitor(monitor)
            homebrewLocalClickMonitor = nil
        }
    }

    public func updateHomebrewPanelHeight(isCategoryMenu: Bool) {
        guard let panel = homebrewPanel else { return }
        let targetHeight: CGFloat = isCategoryMenu ? 344 : 520
        var frame = panel.frame
        if frame.height != targetHeight {
            let dy = frame.height - targetHeight
            frame.origin.y += dy
            frame.size.height = targetHeight
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    public func toggleHomebrewHUD() {
        if homebrewPanel?.isVisible == true {
            hideHomebrewHUD()
        } else {
            showHomebrewHUD()
        }
    }

    // MARK: - Cleaning Mode Lock HUD

    public func showCleaningHUD() {
        IdleMemoryRecovery.shared.cancel()
        hideDimmingWindows()
        let manager = CleaningModeManager.shared
        if manager.dimScreen {
            for screen in NSScreen.screens {
                let backdrop = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                backdrop.level = .screenSaver
                backdrop.isOpaque = false
                backdrop.backgroundColor = NSColor.black.withAlphaComponent(0.76)
                backdrop.ignoresMouseEvents = !manager.lockPointer
                backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                backdrop.orderFrontRegardless()
                dimmingWindows.append(backdrop)
            }
        }

        let hudWidth: CGFloat = 508
        let hudHeight: CGFloat = 172
        if cleaningPanel == nil {
            let panel = LiquidGlassPanel(
                contentRect: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight),
                level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1),
                useWindowGlass: false
            ) {
                CleaningModeHUDView(manager: CleaningModeManager.shared)
            }
            cleaningPanel = panel
        }

        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - hudWidth / 2,
            y: screenFrame.midY - hudHeight / 2
        )
        cleaningPanel?.setFrame(NSRect(origin: origin, size: NSSize(width: hudWidth, height: hudHeight)), display: true)
        NSApp.activate(ignoringOtherApps: true)
        cleaningPanel?.makeKeyAndOrderFront(nil)
    }

    public func hideCleaningHUD() {
        cleaningPanel?.orderOut(nil)
        cleaningPanel?.contentView = nil
        cleaningPanel = nil
        hideDimmingWindows()
        IdleMemoryRecovery.shared.schedule()
    }

    private func hideDimmingWindows() {
        for win in dimmingWindows {
            win.orderOut(nil)
        }
        dimmingWindows.removeAll()
    }
}
