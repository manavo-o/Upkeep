import AppKit
import SwiftUI

@MainActor
public final class HUDCoordinator: NSObject, NSWindowDelegate, NSToolbarDelegate {
    public static let shared = HUDCoordinator()

    public let trayViewModel = TrayViewModel()
    public let homebrewModel = HomebrewHUDModel()

    private var mainWindowController: NSWindowController?
    private var homebrewPanel: LiquidGlassPanel?
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
        // Evict any initial launch-check catalog slab after 30s so idle menu-bar RSS stays minimal.
        Task(priority: .background) {
            try? await Task.sleep(for: .seconds(30))
            if self.mainWindowController == nil && self.homebrewPanel?.isVisible != true {
                await BrewService.shared.evictRemoteCatalogIfIdle()
            }
        }
    }

    // MARK: - Dedicated macOS 27 Native Window (Upkeep)

    public func showMainWindow(section: TraySection? = nil, triggerUpdateCheck: Bool = false) {
        if let section {
            trayViewModel.activeSection = section
        }

        let isNewWindow = mainWindowController == nil
        if isNewWindow {
            let rootView = MainWindowView(vm: trayViewModel, coordinator: self)
            let hostingController = NSHostingController(rootView: rootView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 700, height: 480)
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.toolbar = nil

            window.center()
            mainWindowController = NSWindowController(window: window)
            installMainMenuIfNeeded()
        }

        NSApp.setActivationPolicy(.regular)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        enforceSidebarWidth(on: mainWindowController?.window)

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

    public func quitApp() {
        KeepAwakeManager.shared.stop()
        CleaningModeManager.shared.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Sidebar Width Enforcement (DockDoor / Canapé clean proportions)

    private func enforceSidebarWidth(on window: NSWindow?) {
        guard let window else { return }
        func findSplitView(in view: NSView) -> NSSplitView? {
            if let splitView = view as? NSSplitView {
                return splitView
            }
            for subview in view.subviews {
                if let found = findSplitView(in: subview) {
                    return found
                }
            }
            return nil
        }

        DispatchQueue.main.async {
            guard let contentView = window.contentView,
                  let splitView = findSplitView(in: contentView),
                  let splitViewController = splitView.delegate as? NSSplitViewController,
                  let sidebarItem = splitViewController.splitViewItems.first
            else { return }

            sidebarItem.isCollapsed = false
            sidebarItem.canCollapse = false
            sidebarItem.holdingPriority = .defaultHigh
            sidebarItem.minimumThickness = 208
            sidebarItem.maximumThickness = 208
            splitView.setPosition(208, ofDividerAt: 0)
        }
    }

    // MARK: - NSWindowDelegate

    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == mainWindowController?.window {
            NSApp.setActivationPolicy(.regular)
            CleaningModeManager.shared.refreshPermissionStatus()
            enforceSidebarWidth(on: window)
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == homebrewPanel {
            // Keep open if the ⌘K action popover is currently presented as a child window
            let hasVisibleChildPopover = !(window.childWindows ?? []).filter(\.isVisible).isEmpty
            if !hasVisibleChildPopover {
                hideHomebrewHUD()
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == mainWindowController?.window else { return }
        // Release NSWindow, NSHostingController, Retina backing layers, and transient scan caches.
        window.delegate = nil
        window.contentViewController = nil
        mainWindowController = nil
        trayViewModel.releaseTransientCaches()
        AppIconView.clearCache()
        if homebrewPanel?.isVisible != true {
            Task { await BrewService.shared.scheduleIdleEviction(afterSeconds: 60) }
        }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "Upkeep")
        appMenu.addItem(withTitle: "Quit Upkeep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

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
        Task { await BrewService.shared.cancelIdleEviction() }
        if let query = initialQuery {
            homebrewModel.query = query
            homebrewModel.activeTab = initialTab
        } else if let initialTab {
            homebrewModel.query = ""
            homebrewModel.activeTab = initialTab
        } else {
            homebrewModel.query = ""
            homebrewModel.activeTab = nil
            homebrewModel.packages = []
            homebrewModel.selectedID = nil
            homebrewModel.statusBanner = nil
            homebrewModel.errorBanner = nil
            homebrewModel.showActionMenu = false
        }
        if homebrewPanel == nil {
            let panel = LiquidGlassPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                level: .floating,
                useWindowGlass: false
            ) {
                HomebrewHUDView(model: self.homebrewModel) { [weak self] in
                    self?.hideHomebrewHUD()
                }
            }
            panel.delegate = self
            homebrewPanel = panel
        }
        updateHomebrewPanelHeight(isCategoryMenu: homebrewModel.isShowingCategoryMenu)
        homebrewPanel?.presentCenteredAtHUDHeight()
        installHomebrewClickOutsideMonitors()
        if (initialQuery != nil && !(initialQuery?.isEmpty ?? true)) || initialTab != nil {
            homebrewModel.onQueryChanged()
        }
    }

    public func hideHomebrewHUD() {
        removeHomebrewClickOutsideMonitors()
        homebrewModel.showActionMenu = false
        homebrewModel.packages = []
        homebrewModel.selectedID = nil
        homebrewPanel?.orderOut(nil)
        if mainWindowController == nil {
            Task { await BrewService.shared.scheduleIdleEviction(afterSeconds: 120) }
        }
    }

    private func installHomebrewClickOutsideMonitors() {
        removeHomebrewClickOutsideMonitors()

        homebrewGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissHomebrewIfClickOutside()
            }
        }

        homebrewLocalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.homebrewPanel, panel.isVisible else { return event }
            let screenPoint = NSEvent.mouseLocation
            let insidePanel = panel.frame.contains(screenPoint)
            let insideChild = (panel.childWindows ?? []).contains { $0.isVisible && $0.frame.contains(screenPoint) }
            if !insidePanel && !insideChild {
                self.hideHomebrewHUD()
            }
            return event
        }
    }

    private func dismissHomebrewIfClickOutside() {
        guard let panel = homebrewPanel, panel.isVisible else { return }
        let screenPoint = NSEvent.mouseLocation
        let insidePanel = panel.frame.contains(screenPoint)
        let insideChild = (panel.childWindows ?? []).contains { $0.isVisible && $0.frame.contains(screenPoint) }
        if !insidePanel && !insideChild {
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
            panel.setFrame(frame, display: true, animate: true)
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
    }

    private func hideDimmingWindows() {
        for win in dimmingWindows {
            win.orderOut(nil)
        }
        dimmingWindows.removeAll()
    }
}
