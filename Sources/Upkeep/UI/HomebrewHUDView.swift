import AppKit
import Observation

/// Native HUD with reusable result cells during a presentation. Dismissal releases its view hierarchy.
@MainActor
final class HomebrewHUDView: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private struct Results: Equatable {
        var packages: [BrewPackageItem] = []
        var operationID: String?
    }

    private static let trayWidth: CGFloat = 688
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("HomebrewPackage")

    private let model: HomebrewHUDModel
    private let onDismiss: () -> Void
    private let search = HomebrewHUDSearchField(frame: .zero)
    private let scope = NSButton()
    private let clear = NSButton()
    private let mug = NSImageView()
    private let searchProgress = BrewHUDControls.spinner(.small)
    private let categories = NSStackView()
    private let resultsPane = NSView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let detail = BrewHUDDetailView()
    private let placeholder = NSStackView()
    private let placeholderIcon = NSImageView()
    private let placeholderTitle = BrewHUDControls.label(size: 16, weight: .semibold)
    private let placeholderMessage = BrewHUDControls.label(size: 12, color: .secondaryLabelColor)
    private let errorMessage = BrewHUDControls.label(size: 13, color: .systemRed)
    private let statusBar = NSStackView()
    private let statusBarSeparator = BrewHUDControls.separator()
    private let statusProgress = BrewHUDControls.spinner(.mini)
    private let statusLabel = BrewHUDControls.label(size: 11, color: .tertiaryLabelColor)
    private let actions = NSButton()
    private let actionMenu = NSMenu(title: "Homebrew Actions")

    private var trayHeight: NSLayoutConstraint!
    private var targetTrayHeight: CGFloat = 210
    private var targetPanelHeight: CGFloat = 520
    private var results = Results()
    private var isUpdatingTable = false
    private var observesContent = false
    private var observesStatus = false
    private(set) var isPresented = false
    private(set) var isTrackingActions = false

    init(model: HomebrewHUDModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        setUpView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepareForShow() {
        isPresented = true
        if observesContent { renderContent() } else { observeContent() }
        if observesStatus { renderStatus() } else { observeStatus() }
    }

    func focusSearch() {
        window?.makeFirstResponder(search)
    }

    func prepareForHide() {
        isPresented = false
        if isTrackingActions { actionMenu.cancelTracking() }
        updateTable(with: Results(), selectedID: nil)
        detail.clear()
        search.stringValue = ""
        statusLabel.stringValue = ""
        errorMessage.stringValue = ""
        BrewHUDControls.setSpinning(searchProgress, false)
        BrewHUDControls.setSpinning(statusProgress, false)
    }

    private func setUpView() {
        let searchPill = BrewHUDControls.glass(around: makeSearchBar(), radius: 30, interactive: true)
        let tray = BrewHUDControls.glass(around: makeTray(), radius: 20)

        let stack = NSStackView(views: [searchPill, tray])
        stack.orientation = .vertical
        stack.spacing = 12
        searchPill.heightAnchor.constraint(equalToConstant: 60).isActive = true
        trayHeight = tray.heightAnchor.constraint(equalToConstant: 210)
        trayHeight.isActive = true
        for view in [searchPill, tray] {
            view.widthAnchor.constraint(equalToConstant: Self.trayWidth).isActive = true
        }

        let surface: NSView
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = 12
            container.contentView = stack
            surface = container
        } else {
            surface = stack
        }
        BrewHUDControls.add(surface, to: self)
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: centerXAnchor),
            surface.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if surface !== stack {
            BrewHUDControls.pin(stack, inside: surface)
        }

        actionMenu.autoenablesItems = false
    }

    private func makeSearchBar() -> NSView {
        search.font = .systemFont(ofSize: 21)
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.isAutomaticTextCompletionEnabled = false
        search.delegate = self
        if let cell = search.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
            cell.maximumRecents = 0
        }
        search.setAccessibilityLabel("Search Homebrew")
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        BrewHUDControls.configure(scope, title: "", target: self, action: #selector(clearScope))
        BrewHUDControls.configure(clear, title: "", icon: "xmark.circle.fill", target: self, action: #selector(clearQuery))
        clear.imagePosition = .imageOnly
        clear.contentTintColor = .secondaryLabelColor
        clear.setAccessibilityLabel("Clear Search")
        mug.image = BrewHUDControls.symbol("mug", size: 18)
        mug.contentTintColor = .secondaryLabelColor

        let trailing = NSView()
        for view in [mug, clear, searchProgress] {
            BrewHUDControls.add(view, to: trailing)
            view.centerXAnchor.constraint(equalTo: trailing.centerXAnchor).isActive = true
            view.centerYAnchor.constraint(equalTo: trailing.centerYAnchor).isActive = true
        }
        trailing.widthAnchor.constraint(equalToConstant: 22).isActive = true
        trailing.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let stack = NSStackView(views: [scope, search, trailing])
        stack.spacing = 12
        stack.alignment = .centerY
        let container = NSView()
        BrewHUDControls.add(stack, to: container)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func makeTray() -> NSView {
        let container = NSView()
        categories.orientation = .vertical
        categories.alignment = .width
        categories.spacing = 2
        categories.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for tab in BrewHUDTab.allCases {
            let button = NSButton()
            BrewHUDControls.configure(button, title: tab.title, icon: tab.icon, target: self, action: #selector(selectCategory(_:)))
            button.tag = tab.rawValue
            button.alignment = .left
            button.font = .systemFont(ofSize: 16)
            button.setAccessibilityHelp(tab.shortcutLabel)

            let shortcut = BrewHUDControls.label(size: 14, color: .tertiaryLabelColor)
            shortcut.stringValue = tab.shortcutLabel
            let row = NSView()
            BrewHUDControls.add(button, to: row)
            // The whole row is the button. Draw the shortcut above it, within the same hit area.
            shortcut.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(shortcut, positioned: .above, relativeTo: button)
            shortcut.setAccessibilityElement(false)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 46),
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                button.topAnchor.constraint(equalTo: row.topAnchor),
                button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                shortcut.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                shortcut.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            categories.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: categories.widthAnchor, constant: -24).isActive = true
        }

        setUpResultsPane()
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 8
        placeholderIcon.contentTintColor = .tertiaryLabelColor
        for item in [placeholderIcon, placeholderTitle, placeholderMessage] as [NSView] {
            placeholder.addArrangedSubview(item)
        }
        errorMessage.maximumNumberOfLines = 3
        errorMessage.lineBreakMode = .byTruncatingTail

        let separator = statusBarSeparator
        setUpStatusBar()

        for view in [categories, resultsPane, placeholder, errorMessage, separator, statusBar] as [NSView] {
            BrewHUDControls.add(view, to: container)
        }
        NSLayoutConstraint.activate([
            categories.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            categories.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            categories.topAnchor.constraint(equalTo: container.topAnchor),
            resultsPane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resultsPane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resultsPane.topAnchor.constraint(equalTo: container.topAnchor),
            resultsPane.heightAnchor.constraint(equalToConstant: 336),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 20.5),
            errorMessage.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            errorMessage.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            errorMessage.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 20.5),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 40)
        ])
        return container
    }

    private func setUpResultsPane() {
        table.headerView = nil
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Homebrew Packages")
        let column = NSTableColumn(identifier: Self.rowIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table

        let divider = BrewHUDControls.separator()
        for view in [scroll, divider, detail] as [NSView] {
            BrewHUDControls.add(view, to: resultsPane)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: resultsPane.leadingAnchor, constant: 10),
            scroll.widthAnchor.constraint(equalToConstant: 380),
            scroll.topAnchor.constraint(equalTo: resultsPane.topAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: resultsPane.bottomAnchor, constant: -10),
            divider.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 10),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: resultsPane.topAnchor),
            divider.bottomAnchor.constraint(equalTo: resultsPane.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: resultsPane.trailingAnchor),
            detail.topAnchor.constraint(equalTo: resultsPane.topAnchor),
            detail.bottomAnchor.constraint(equalTo: resultsPane.bottomAnchor)
        ])

        BrewHUDControls.configure(detail.primary, title: "", target: self, action: #selector(performPrimaryAction))
        BrewHUDControls.configure(detail.copy, title: "", target: self, action: #selector(copyCommand))
        BrewHUDControls.configure(detail.homepage, title: "", target: self, action: #selector(openHomepage))
        BrewHUDControls.configure(detail.homepageIcon, title: "", icon: "safari", target: self, action: #selector(openHomepage))
        detail.homepageIcon.imagePosition = .imageOnly
        detail.homepageIcon.alignment = .center
        detail.homepageIcon.setAccessibilityLabel("Open Homepage")
        detail.homepageIcon.toolTip = "Open Homepage"
        for button in [detail.primary, detail.copy, detail.homepageIcon] {
            button.isBordered = true
            button.bezelStyle = .rounded
            if #available(macOS 26.0, *) { button.bezelStyle = .glass }
            button.controlSize = .large
            button.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        detail.homepage.alignment = .left
        detail.homepage.lineBreakMode = .byTruncatingMiddle
        detail.homepage.contentTintColor = .controlAccentColor
    }

    private func setUpStatusBar() {
        let settings = NSButton()
        BrewHUDControls.configure(settings, title: "Settings", icon: "macwindow", target: self, action: #selector(openSettings))
        settings.toolTip = "Open Homebrew in Upkeep Settings (⌘,)"
        BrewHUDControls.configure(actions, title: "Actions  ⌘K", target: self, action: #selector(showActions))
        actions.setAccessibilityLabel("Actions")
        for button in [settings, actions] {
            button.controlSize = .small
            button.isBordered = true
            button.bezelStyle = .rounded
            if #available(macOS 26.0, *) { button.bezelStyle = .glass }
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusBar.spacing = 10
        statusBar.alignment = .centerY
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        for view in [statusProgress, statusLabel, settings, actions] as [NSView] {
            statusBar.addArrangedSubview(view)
        }
    }

    // Re-arm the one-shot observation after the model writes finish. A pending observer can
    // survive a hide/show, so keep at most one registration per part of the HUD.
    private func observeContent() {
        guard isPresented else { return }
        observesContent = true
        withObservationTracking {
            renderContent()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observesContent = false
                self.observeContent()
            }
        }
    }

    private func observeStatus() {
        guard isPresented else { return }
        observesStatus = true
        withObservationTracking {
            renderStatus()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observesStatus = false
                self.observeStatus()
            }
        }
    }

    private func renderContent() {
        let query = model.query
        let tab = model.activeTab
        let loading = model.isLoading
        let isCategory = model.isShowingCategoryMenu
        let error = model.errorBanner
        let currentResults = Results(packages: Array(model.packages.prefix(40)), operationID: model.activeOperationPackageID)
        let selectedID = model.selectedID
        let copiedID = model.copiedPackageID

        if search.stringValue != query, (search.currentEditor() as? NSTextView)?.string != query {
            search.stringValue = query
        }
        scope.isHidden = tab == nil
        if let tab {
            scope.title = "\(tab.title)  ×"
            scope.image = BrewHUDControls.symbol(tab.icon, size: 12)
            scope.setAccessibilityLabel("Clear \(tab.title) scope")
            search.placeholderString = tab == .formulae || tab == .casks ? "Search \(tab.title)…" : "Filter \(tab.title)…"
        } else {
            search.placeholderString = "Search Homebrew"
        }
        clear.isHidden = loading || query.isEmpty
        mug.isHidden = loading || !query.isEmpty
        BrewHUDControls.setSpinning(searchProgress, loading)

        let showsResults = !isCategory && error == nil && !currentResults.packages.isEmpty
        categories.isHidden = !isCategory
        resultsPane.isHidden = !showsResults
        placeholder.isHidden = isCategory || showsResults || error != nil
        errorMessage.isHidden = isCategory || error == nil
        errorMessage.stringValue = error ?? ""
        statusBar.isHidden = isCategory
        statusBarSeparator.isHidden = isCategory

        if !placeholder.isHidden {
            if let tab, (tab == .formulae || tab == .casks),
               query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                placeholderIcon.image = BrewHUDControls.symbol(tab.icon, size: 28)
                placeholderTitle.stringValue = "Search Homebrew \(tab.title)"
                placeholderMessage.stringValue = "Start typing a name or keyword to search Homebrew \(tab.title.lowercased())."
                placeholderMessage.isHidden = false
            } else {
                placeholderIcon.image = BrewHUDControls.symbol("shippingbox", size: 28)
                placeholderTitle.stringValue = loading ? "Searching Homebrew…" : "No Matching Packages"
                placeholderMessage.isHidden = true
            }
        }

        updateTable(with: showsResults ? currentResults : Results(), selectedID: selectedID)
        if showsResults, let package = model.selectedPackage {
            detail.update(for: package, operationID: currentResults.operationID, copiedID: copiedID)
        } else {
            detail.clear()
        }

        let nextTrayHeight: CGFloat = isCategory ? 210 : (showsResults ? 377 : (error == nil ? 281 : 121))
        let nextPanelHeight: CGFloat = isCategory ? 344 : 520
        if targetTrayHeight != nextTrayHeight || targetPanelHeight != nextPanelHeight {
            targetTrayHeight = nextTrayHeight
            targetPanelHeight = nextPanelHeight
            updateGeometry(animated: error == nil && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    func updateGeometry(animated: Bool) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - targetPanelHeight
        frame.size.height = targetPanelHeight
        UpkeepMotion.animateAppKit(duration: animated ? UpkeepMotion.resizeDuration : 0) {
            trayHeight.animator().constant = targetTrayHeight
            if window.frame != frame {
                window.animator().setFrame(frame, display: true)
            }
            layoutSubtreeIfNeeded()
        }
    }

    private func renderStatus() {
        let log = BrewLogStore.shared
        let live = log.isRunning ? log.liveStatusLine : nil
        let banner = model.statusBanner
        let showProgress = live != nil && !model.isShowingCategoryMenu
        BrewHUDControls.setSpinning(statusProgress, showProgress)
        statusLabel.textColor = live != nil || banner != nil ? .secondaryLabelColor : .tertiaryLabelColor
        statusLabel.stringValue = (live ?? banner)?.replacingOccurrences(of: "`", with: "")
            ?? "⌘1 Installed · ⌘2 Formulae · ⌘3 Casks · ⌘4 Upgrades"
    }

    private func updateTable(with updated: Results, selectedID: String?) {
        isUpdatingTable = true
        defer { isUpdatingTable = false }
        if results != updated {
            let packagesChanged = results.packages != updated.packages
            results = updated
            table.reloadData()
            if packagesChanged {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        let row = results.packages.firstIndex { $0.id == selectedID } ?? (results.packages.isEmpty ? -1 : 0)
        if row != table.selectedRow {
            if row >= 0 {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            } else {
                table.deselectAll(nil)
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.packages.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("HomebrewSelection")
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? BrewHUDTableRow { return view }
        let view = BrewHUDTableRow()
        view.identifier = identifier
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? BrewHUDPackageCell)
            ?? BrewHUDPackageCell()
        cell.identifier = Self.rowIdentifier
        let package = results.packages[row]
        cell.update(for: package, isOperating: package.id == results.operationID)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingTable, results.packages.indices.contains(table.selectedRow) else { return }
        model.selectedID = results.packages[table.selectedRow].id
    }

    func controlTextDidChange(_ notification: Notification) {
        guard isPresented else { return }
        let query = (search.currentEditor() as? NSTextView)?.string ?? search.stringValue
        guard model.query != query else { return }
        model.query = query
        model.onQueryChanged()
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        guard isPresented, !isTrackingActions else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let number = Int(key), let tab = BrewHUDTab(rawValue: number) {
                model.selectTab(tab)
                focusSearch()
                return true
            }
            switch key {
            case "k": showActions()
            case ",": openSettings()
            default: return false
            }
            return true
        }

        guard modifiers.isEmpty, (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
        switch event.keyCode {
        case 125, 126: // Down and up arrows
            guard !model.isShowingCategoryMenu else { return false }
            model.moveSelection(delta: event.keyCode == 125 ? 1 : -1)
        case 36, 76: // Return and keypad Enter
            guard window?.firstResponder === search.currentEditor() || window?.firstResponder === table else { return false }
            if !event.isARepeat { performPrimaryAction() }
        case 53: // Escape
            if model.activeTab != nil || !model.query.isEmpty {
                replaceQuery("")
                model.selectTab(nil)
                focusSearch()
            } else {
                onDismiss()
            }
        default: return false
        }
        return true
    }

    private func replaceQuery(_ query: String) {
        if let editor = search.currentEditor() as? NSTextView {
            editor.string = query
        }
        search.stringValue = query
        model.query = query
    }

    @objc private func selectCategory(_ sender: NSButton) {
        model.selectTab(BrewHUDTab(rawValue: sender.tag))
        focusSearch()
    }

    @objc private func clearScope() {
        model.selectTab(nil)
        focusSearch()
    }

    @objc private func clearQuery() {
        replaceQuery("")
        model.onQueryChanged()
        focusSearch()
    }

    @objc private func performPrimaryAction() {
        guard model.errorBanner == nil, !model.isShowingCategoryMenu, let package = model.selectedPackage else { return }
        model.performPrimaryAction(for: package)
    }

    @objc private func copyCommand() {
        if let package = model.selectedPackage { model.copyInstallCommand(package) }
    }

    @objc private func openHomepage() {
        if let package = model.selectedPackage { model.openHomepage(package) }
    }

    @objc private func openSettings() { model.onOpenInSettings?() }

    @objc private func uninstallPackage() {
        if let package = model.selectedPackage { model.uninstall(package) }
    }

    @objc private func togglePin() {
        if let package = model.selectedPackage { model.togglePin(package) }
    }

    @objc private func runDoctor() { model.runBrewDoctor() }

    @objc private func showActions() {
        guard isPresented, !model.isShowingCategoryMenu, !isTrackingActions else { return }
        actionMenu.removeAllItems()
        if resultsPane.isHidden == false, let package = model.selectedPackage {
            addMenuItem("\(BrewHUDControls.actionTitle(for: package)) \(package.name)", icon: BrewHUDControls.actionIcon(for: package),
                        action: #selector(performPrimaryAction), key: "\r", modifiers: [], enabled: !model.isOperating)
            if package.isInstalled && !package.isCask {
                addMenuItem(package.isPinned ? "Unpin Formula" : "Pin Formula", icon: package.isPinned ? "pin.slash" : "pin",
                            action: #selector(togglePin), key: "p", enabled: !model.isOperating)
            }
            if package.isInstalled && package.isOutdated {
                addMenuItem("Uninstall \(package.name)", icon: "trash", action: #selector(uninstallPackage),
                            key: "\u{8}", enabled: !model.isOperating)
            }
            actionMenu.addItem(.separator())
            addMenuItem("Copy Install Command", icon: "doc.on.doc", action: #selector(copyCommand), key: "c")
            if !package.homepage.isEmpty {
                addMenuItem("Open Homepage", icon: "safari", action: #selector(openHomepage), key: "o")
            }
        }
        addMenuItem("Open in Upkeep Settings", icon: "macwindow", action: #selector(openSettings), key: ",")
        addMenuItem("Run Brew Doctor", icon: "stethoscope", action: #selector(runDoctor), key: "d", enabled: !model.isOperating)
        isTrackingActions = true
        actionMenu.popUp(positioning: nil, at: NSPoint(x: actions.bounds.minX, y: actions.bounds.maxY), in: actions)
        isTrackingActions = false
        actionMenu.removeAllItems()
        if isPresented {
            if window?.isKeyWindow == true { focusSearch() } else { onDismiss() }
        }
    }

    private func addMenuItem(_ title: String, icon: String, action: Selector, key: String,
                             modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = BrewHUDControls.symbol(icon, size: 13)
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        actionMenu.addItem(item)
    }
}
