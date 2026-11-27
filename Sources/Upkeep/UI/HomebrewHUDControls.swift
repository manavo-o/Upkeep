import AppKit

@MainActor
enum BrewHUDControls {
    static func add(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
    }

    static func pin(_ child: NSView, inside parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    static func glass(around content: NSView, radius: CGFloat, interactive: Bool = false) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            if #available(macOS 27.0, *) {
                // The public macOS 27 property is accessed through KVC so macOS 26 SDK builds remain supported.
                glass.setValue(interactive, forKey: "effectIsInteractive")
            }
            glass.contentView = content
            pin(content, inside: glass)
            return glass
        }

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = radius
        backdrop.layer?.masksToBounds = true
        add(content, to: backdrop)
        pin(content, inside: backdrop)
        return backdrop
    }

    static func label(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
    }

    static func configure(_ button: NSButton, title: String, icon: String? = nil, target: AnyObject, action: Selector) {
        button.title = title
        button.image = icon.flatMap { symbol($0, size: 13) }
        button.imagePosition = .imageLeading
        button.target = target
        button.action = action
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = NSColor.separatorColor.withAlphaComponent(0.22)
        return box
    }

    static func spinner(_ size: NSControl.ControlSize) -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = size
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        return spinner
    }

    static func setSpinning(_ spinner: NSProgressIndicator, _ spinning: Bool) {
        guard spinner.isHidden == spinning else { return }
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    static func actionTitle(for package: BrewPackageItem) -> String {
        if package.isOutdated && package.isInstalled { return "Upgrade" }
        return package.isInstalled ? "Uninstall" : "Install"
    }

    static func actionIcon(for package: BrewPackageItem) -> String {
        if package.isOutdated && package.isInstalled { return "arrow.up.circle.fill" }
        return package.isInstalled ? "trash" : "arrow.down.circle.fill"
    }

    static func packageIcon(for package: BrewPackageItem) -> String {
        package.isCask ? "app.dashed" : "terminal"
    }
}

@MainActor
final class BrewHUDDetailView: NSView {
    let primary = NSButton()
    let copy = NSButton()
    let homepage = NSButton()
    let homepageIcon = NSButton()

    private let icon = NSImageView()
    private let name = BrewHUDControls.label(size: 16, weight: .semibold)
    private let version = BrewHUDControls.label(size: 10, color: .secondaryLabelColor)
    private let descriptionLabel = BrewHUDControls.label(size: 12.5, color: .secondaryLabelColor)
    private let badges = NSStackView()
    private let installationBadge = BrewHUDBadge()
    private let pinnedBadge = BrewHUDBadge()
    private let operationProgress = BrewHUDControls.spinner(.small)

    init() {
        super.init(frame: .zero)
        let title = NSStackView(views: [name, version])
        title.orientation = .vertical
        title.alignment = .leading
        title.spacing = 2
        title.distribution = .fill
        for label in [name, version] {
            label.widthAnchor.constraint(equalTo: title.widthAnchor).isActive = true
        }
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        version.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let header = NSStackView(views: [icon, title])
        header.alignment = .centerY
        header.spacing = 10
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

        badges.spacing = 6
        badges.addArrangedSubview(installationBadge)
        badges.addArrangedSubview(pinnedBadge)
        let badgeSpacer = NSView()
        badgeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badges.addArrangedSubview(badgeSpacer)
        descriptionLabel.maximumNumberOfLines = 4
        descriptionLabel.preferredMaxLayoutWidth = 251
        homepage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let overview = NSStackView(views: [header, badges, descriptionLabel, homepage])
        overview.orientation = .vertical
        overview.alignment = .width
        overview.spacing = 12
        for view in overview.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: overview.widthAnchor).isActive = true
        }

        let primaryRow = NSView()
        BrewHUDControls.add(primary, to: primaryRow)
        BrewHUDControls.pin(primary, inside: primaryRow)
        BrewHUDControls.add(operationProgress, to: primaryRow)
        NSLayoutConstraint.activate([
            operationProgress.leadingAnchor.constraint(equalTo: primary.leadingAnchor, constant: 16),
            operationProgress.centerYAnchor.constraint(equalTo: primary.centerYAnchor)
        ])
        let secondary = NSStackView(views: [copy, homepageIcon])
        secondary.spacing = 8
        secondary.alignment = .centerY
        copy.setContentHuggingPriority(.defaultLow, for: .horizontal)
        homepageIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        homepageIcon.heightAnchor.constraint(equalTo: copy.heightAnchor).isActive = true
        let buttons = NSStackView(views: [primaryRow, secondary])
        buttons.orientation = .vertical
        buttons.alignment = .width
        buttons.spacing = 8
        for view in buttons.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: buttons.widthAnchor).isActive = true
        }

        BrewHUDControls.add(overview, to: self)
        BrewHUDControls.add(buttons, to: self)
        NSLayoutConstraint.activate([
            overview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            overview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            overview.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            buttons.leadingAnchor.constraint(equalTo: overview.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: overview.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: overview.bottomAnchor, constant: 8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(for package: BrewPackageItem, operationID: String?, copiedID: String?) {
        icon.image = BrewHUDControls.symbol(BrewHUDControls.packageIcon(for: package), size: 23)
        icon.contentTintColor = package.isOutdated ? .systemOrange : .systemIndigo
        name.stringValue = package.name
        let kind = package.isCask ? "Cask" : "Formula"
        let build = package.displayVersion
        version.stringValue = build.isEmpty ? kind : "\(kind) · \(build)"

        let isInstalled = package.isInstalled || package.isOutdated
        badges.isHidden = !isInstalled && !package.isPinned
        installationBadge.isHidden = !isInstalled
        pinnedBadge.isHidden = !package.isPinned
        if isInstalled {
            if package.isOutdated {
                installationBadge.update("Update Available", icon: "arrow.up.circle.fill", color: .systemOrange)
            } else {
                installationBadge.update("Installed", icon: "checkmark.circle.fill", color: .systemGreen)
            }
        }
        if package.isPinned { pinnedBadge.update("Pinned", icon: "pin.fill", color: .systemOrange) }

        descriptionLabel.stringValue = package.description.isEmpty ? "No description available." : package.description
        homepage.isHidden = package.homepage.isEmpty
        homepage.title = package.homepage
        homepage.image = BrewHUDControls.symbol("safari", size: 11)
        homepageIcon.isHidden = homepage.isHidden

        let isOperating = package.id == operationID
        let action = BrewHUDControls.actionTitle(for: package)
        if isOperating {
            switch action {
            case "Upgrade": primary.title = "Upgrading…"
            case "Uninstall": primary.title = "Uninstalling…"
            default: primary.title = "Installing…"
            }
        } else {
            primary.title = action
        }
        primary.image = isOperating ? nil : BrewHUDControls.symbol(BrewHUDControls.actionIcon(for: package), size: 13.5)
        primary.contentTintColor = package.isOutdated ? .systemOrange : (package.isInstalled ? .systemRed : .controlAccentColor)
        primary.isEnabled = operationID == nil
        BrewHUDControls.setSpinning(operationProgress, isOperating)

        let copied = package.id == copiedID
        copy.title = copied ? "Copied" : "Copy CLI"
        copy.image = BrewHUDControls.symbol(copied ? "checkmark" : "doc.on.doc", size: 12)
    }

    func clear() {
        name.stringValue = ""
        version.stringValue = ""
        descriptionLabel.stringValue = ""
        homepage.title = ""
        BrewHUDControls.setSpinning(operationProgress, false)
    }
}

@MainActor
private final class BrewHUDBadge: NSView {
    private let text = BrewHUDControls.label(size: 10, weight: .semibold)
    private let image = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        let stack = NSStackView(views: [image, text])
        stack.alignment = .centerY
        stack.spacing = 4
        BrewHUDControls.add(stack, to: self)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ title: String, icon: String, color: NSColor) {
        text.stringValue = title
        text.textColor = color
        image.image = BrewHUDControls.symbol(icon, size: 10)
        image.contentTintColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
    }
}

@MainActor
final class BrewHUDPackageCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = BrewHUDControls.label(size: 13.5, weight: .medium)
    private let version = BrewHUDControls.label(size: 10, color: .secondaryLabelColor)
    private let descriptionLabel = BrewHUDControls.label(size: 10, color: .secondaryLabelColor)
    private let status = BrewHUDControls.label(size: 10, weight: .medium)
    private let progress = BrewHUDControls.spinner(.small)

    init() {
        super.init(frame: .zero)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let title = NSStackView(views: [name, version])
        title.spacing = 6
        title.alignment = .firstBaseline
        for label in [name, version, descriptionLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let labels = NSStackView(views: [title, descriptionLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        for view in labels.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: [icon, labels, status, progress])
        stack.spacing = 12
        stack.alignment = .centerY
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        BrewHUDControls.add(stack, to: self)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = name
        imageView = icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        BrewHUDControls.setSpinning(progress, false)
        name.stringValue = ""
        version.stringValue = ""
        descriptionLabel.stringValue = ""
    }

    func update(for package: BrewPackageItem, isOperating: Bool) {
        icon.image = BrewHUDControls.symbol(BrewHUDControls.packageIcon(for: package), size: 14.5)
        name.stringValue = package.name
        version.stringValue = package.displayVersion
        version.isHidden = version.stringValue.isEmpty
        descriptionLabel.stringValue = package.description
        descriptionLabel.isHidden = package.description.isEmpty
        status.isHidden = isOperating
        status.stringValue = package.isOutdated ? "Update" : (package.isInstalled ? "Installed" : "Install")
        status.textColor = package.isOutdated ? .systemOrange : (package.isInstalled ? .tertiaryLabelColor : .secondaryLabelColor)
        BrewHUDControls.setSpinning(progress, isOperating)
    }
}

@MainActor
final class BrewHUDTableRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        let rect = bounds.insetBy(dx: 1, dy: 1)
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
    }
}
