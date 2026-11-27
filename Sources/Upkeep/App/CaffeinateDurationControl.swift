import AppKit

@MainActor
final class CaffeinateDurationControl: NSView {
    private static let stops: [(minutes: Int, label: String)] = [(0, "Off"), (15, "15m"), (30, "30m"), (60, "1h"), (120, "2h")]
    private static let headerHeight: CGFloat = 34
    private static let controlsHeight: CGFloat = 61
    private let disclosure = NSButton()
    private let sliderContent = NSView(frame: NSRect(x: 0, y: 0, width: 248, height: controlsHeight))
    private let slider = NSSlider(frame: .zero)
    private let trackingCell = DurationSliderCell()
    private let valueLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let currentMinutes: () -> Int
    private let onCommit: (Int) -> Void
    private var committedMinutes: Int
    private var lastPreview: Int
    private var isExpanded = false

    init(currentMinutes: @escaping () -> Int, onCommit: @escaping (Int) -> Void) {
        let initialMinutes = Self.sliderMinutes(currentMinutes())
        committedMinutes = initialMinutes
        lastPreview = initialMinutes
        self.currentMinutes = currentMinutes
        self.onCommit = onCommit
        super.init(frame: NSRect(x: 0, y: 0, width: 248, height: Self.headerHeight))

        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.imagePosition = .imageLeading
        disclosure.target = self
        disclosure.action = #selector(toggleDisclosure)
        disclosure.frame = NSRect(x: 13, y: 4, width: 112, height: 26)
        disclosure.autoresizingMask = [.minYMargin]
        addSubview(disclosure)

        sliderContent.isHidden = true
        addSubview(sliderContent)
        updateDisclosureAppearance()

        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        valueLabel.frame = NSRect(x: 142, y: 45, width: 92, height: 16)
        valueLabel.setAccessibilityElement(false)
        sliderContent.addSubview(valueLabel)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.frame = NSRect(x: 125, y: 9, width: 109, height: 16)
        statusLabel.autoresizingMask = [.minYMargin]
        addSubview(statusLabel)

        slider.cell = trackingCell
        slider.minValue = 0
        slider.maxValue = Self.position(for: 120)
        slider.isContinuous = true
        slider.altIncrementValue = 0.05
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel("Caffeinate duration")
        slider.setAccessibilityHelp("Select Off to stop Caffeinate or a duration to start or reset the timer.")
        slider.frame = NSRect(x: 14, y: 24, width: 220, height: 24)
        sliderContent.addSubview(slider)

        for stop in Self.stops {
            let label = NSTextField(labelWithString: stop.label)
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.setAccessibilityElement(false)
            let track = slider.frame.insetBy(dx: 8, dy: 0)
            let proportion = Self.position(for: stop.minutes) / slider.maxValue
            let center = track.minX + proportion * track.width
            label.frame = NSRect(x: center - 15, y: 4, width: 30, height: 16)
            sliderContent.addSubview(label)
        }

        trackingCell.onTrackingEnd = { [weak self] released in
            self?.finishTracking(released: released)
        }
        renderValue(initialMinutes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isExpanded { setExpanded(false) }
    }

    @objc private func toggleDisclosure() {
        setExpanded(!isExpanded)
    }

    private func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if expanded {
            committedMinutes = Self.sliderMinutes(currentMinutes())
            renderValue(committedMinutes)
        } else if window?.firstResponder === slider {
            window?.makeFirstResponder(disclosure)
        }
        updateDisclosureAppearance()
        updateStatusVisibility()

        let size = NSSize(width: frame.width, height: Self.headerHeight + (expanded ? Self.controlsHeight : 0))
        let fadeIn = expanded && window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        sliderContent.alphaValue = fadeIn ? 0.65 : 1
        sliderContent.isHidden = !expanded
        // AppKit relays each frame change to the menu, so resize once and animate only the controls.
        setFrameSize(size)
        if fadeIn {
            UpkeepMotion.animateAppKit(duration: UpkeepMotion.entranceDuration, timing: .easeOut) {
                sliderContent.animator().alphaValue = 1
            }
        }
    }

    private func updateDisclosureAppearance() {
        let color: NSColor = isExpanded ? .labelColor : .secondaryLabelColor
        disclosure.attributedTitle = NSAttributedString(string: "Caffeinate", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: color
        ])
        disclosure.contentTintColor = color
        let symbol = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.forward", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        if let symbol {
            // Give both symbols the same layout metrics and leave five points after the icon slot.
            let size = NSSize(width: 16, height: 14)
            let origin = NSPoint(x: (11 - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2)
            let paddedSymbol = NSImage(size: size, flipped: false) { _ in
                symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            paddedSymbol.isTemplate = true
            disclosure.image = paddedSymbol
        }
        disclosure.setAccessibilityExpanded(isExpanded)
    }

    func setStatus(_ status: String, isActive: Bool) {
        if statusLabel.stringValue != status {
            statusLabel.stringValue = status
        }
        updateStatusVisibility()
        if !isActive, committedMinutes != 0, !trackingCell.isTrackingPointer {
            committedMinutes = 0
            renderValue(0)
        }
    }

    private func updateStatusVisibility() {
        statusLabel.isHidden = isExpanded && statusLabel.stringValue == "Off"
    }

    @objc private func sliderChanged() {
        guard isExpanded else { return }
        let position = slider.doubleValue
        var minutes = Self.minutes(at: position)
        let committedPosition = Self.position(for: committedMinutes)
        if !trackingCell.isTrackingPointer, minutes == committedMinutes, position != committedPosition {
            // A small native keyboard or VoiceOver adjustment can land in the same rounding interval.
            if committedMinutes == 0 {
                minutes = 15
            } else if committedMinutes == 15 && position < committedPosition {
                minutes = 0
            } else {
                let step = position > committedPosition ? 5 : -5
                minutes = Self.roundedTimedMinutes(Double(committedMinutes + step))
            }
        }
        if trackingCell.isTrackingPointer, minutes != lastPreview, Self.stops.contains(where: { $0.minutes == minutes }) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if trackingCell.isTrackingPointer {
            showPreview(minutes)
        } else if minutes != committedMinutes {
            commit(minutes)
        } else {
            renderValue(committedMinutes)
        }
    }

    private func finishTracking(released: Bool) {
        guard released, window?.isVisible == true else {
            renderValue(committedMinutes)
            return
        }
        commit(Self.minutes(at: slider.doubleValue))
    }

    private func commit(_ minutes: Int) {
        committedMinutes = minutes
        renderValue(minutes)
        onCommit(minutes)
    }

    private func renderValue(_ minutes: Int) {
        let position = Self.position(for: minutes)
        if slider.doubleValue != position { slider.doubleValue = position }
        showPreview(minutes)
    }

    private func showPreview(_ minutes: Int) {
        lastPreview = minutes
        valueLabel.isHidden = minutes == 0
        valueLabel.stringValue = Self.durationLabel(minutes)
        slider.setAccessibilityValueDescription(minutes == 0 ? "Off" : "\(minutes) minutes")
    }

    // Reserve one interval for Off, then give each doubling of the duration equal space.
    private static func position(for minutes: Int) -> Double {
        minutes == 0 ? 0 : 1 + log2(Double(minutes) / 15)
    }

    private static func minutes(at position: Double) -> Int {
        position < 0.5 ? 0 : roundedTimedMinutes(15 * exp2(position - 1))
    }

    private static func roundedTimedMinutes(_ value: Double) -> Int {
        min(120, max(15, Int((value / 5).rounded()) * 5))
    }

    private static func sliderMinutes(_ minutes: Int) -> Int {
        minutes == 0 ? 0 : roundedTimedMinutes(Double(minutes))
    }

    private static func durationLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "Off" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) hr" }
        if minutes < 60 { return "\(minutes) min" }
        return "1 hr \(minutes - 60) min"
    }
}

@MainActor
private final class DurationSliderCell: NSSliderCell {
    var onTrackingEnd: ((Bool) -> Void)?
    private(set) var isTrackingPointer = false

    override func trackMouse(with event: NSEvent, in cellFrame: NSRect, of controlView: NSView, untilMouseUp flag: Bool) -> Bool {
        isTrackingPointer = true
        let released = super.trackMouse(with: event, in: cellFrame, of: controlView, untilMouseUp: flag)
        isTrackingPointer = false
        onTrackingEnd?(released)
        return released
    }
}
