import SwiftUI

struct CaffeinateSettingsPane: View {
    @Bindable var vm: TrayViewModel
    @Bindable var keepAwake: KeepAwakeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tint = TraySection.controls.accentColor

    var body: some View {
        UpkeepSettingsFormView {
            sessionStatus
                .upkeepSearchTarget("power.keepAwake")
        } content: {
            UpkeepSettingsSection("Session Options") {
                Picker(selection: awakeMode) {
                    Text("Mac & Display").tag(KeepAwakeMode.displayAndSystem)
                    Text("Mac Only").tag(KeepAwakeMode.systemOnly)
                } label: {
                    UpkeepSettingLabel("Keep Awake", subtitle: "Choose whether the display can sleep during a session.")
                }
                .pickerStyle(.segmented)
                .tint(UpkeepSettingsPalette.accent)
                .upkeepSearchTarget("power.assertionMode")

                Toggle(isOn: Binding(
                    get: { keepAwake.keepsAwakeWithLidClosed },
                    set: { enabled in
                        if enabled {
                            Task { await keepAwake.enableKeepsAwakeWithLidClosed() }
                        } else {
                            keepAwake.setKeepsAwakeWithLidClosed(false)
                        }
                    }
                )) {
                    UpkeepSettingLabel("Keep Awake With Lid Closed", subtitle: closedLidSubtitle)
                }
                .tint(UpkeepSettingsPalette.accent)
                .disabled(keepAwake.closedLid.state == .authorizing)
                .accessibilityLabel("Keep Awake With Lid Closed")
                .accessibilityHint(closedLidSubtitle)
                .upkeepSearchTarget("power.closedLid")

                HStack {
                    Text("Session Duration")
                    Spacer()
                    HStack(spacing: 10) {
                        CaffeinateDurationSlider(minutes: sliderMinutes) { minutes in
                            updateSession {
                                if minutes == 0 {
                                    keepAwake.stop()
                                } else {
                                    keepAwake.applyDuration(minutes: minutes, mode: vm.selectedAwakeMode)
                                }
                            }
                        }
                        .frame(width: 248, height: 61)

                        Button("Until Stopped") {
                            updateSession { keepAwake.applyDuration(minutes: nil, mode: vm.selectedAwakeMode) }
                        }
                        .buttonStyle(.upkeepSecondary)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(keepAwake.isActive && keepAwake.expiresAt == nil)
                    }
                }
                .upkeepSearchTarget("power.quickDuration")
            }
        }
    }

    private var sliderMinutes: Int {
        guard keepAwake.isActive else { return 0 }
        return keepAwake.remainingSeconds.map { max(15, ($0 + 59) / 60) } ?? -1
    }

    private var closedLidSubtitle: String {
        switch keepAwake.closedLid.state {
        case .off:
            keepAwake.keepsAwakeWithLidClosed
                ? "Applies automatically to future Caffeinate sessions."
                : "One-time administrator approval lets future sessions stay awake with the lid closed."
        case .authorizing: "Waiting for one-time administrator approval…"
        case .starting: "Enabling closed-lid mode…"
        case .active: "This Mac stays awake with the lid closed until the session ends."
        case .stopping: "Restoring the previous sleep setting…"
        case .failed(let message): message
        }
    }

    private var sessionStatus: some View {
        UpkeepSettingsFeature(
            title: keepAwake.isActive ? "Caffeinate is on" : "Caffeinate is off",
            tint: tint
        ) {
            UpkeepSettingsIcon(systemName: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", color: tint, size: 44)
        } detail: {
            if keepAwake.isActive {
                VStack(alignment: .leading, spacing: 2) {
                    Text(keepAwake.mode == .displayAndSystem ? "Mac & Display" : "Mac Only")
                    if let expiresAt = keepAwake.expiresAt {
                        Text("\(Text(expiresAt, style: .timer)) remaining")
                            .monospacedDigit()
                    } else {
                        Text("Until stopped")
                    }
                }
            } else {
                Text("Start a session to prevent idle sleep.")
            }
        } actions: {
            HStack(spacing: 8) {
                if keepAwake.isActive {
                    Button(keepAwake.expiresAt == nil ? "Set 30 min" : "Add 30 min") { keepAwake.extend(byMinutes: 30) }
                        .buttonStyle(.upkeepSecondary)
                    Button("Stop Session") { updateSession { keepAwake.stop() } }
                        .buttonStyle(.upkeepSecondary)
                } else {
                    Button("Start for 1 Hour") { start(minutes: 60) }
                        .buttonStyle(.upkeepPrimary)
                        .tint(UpkeepSettingsPalette.accent)
                }
            }
        }
    }

    private var awakeMode: Binding<KeepAwakeMode> {
        Binding(
            get: { vm.selectedAwakeMode },
            set: { mode in
                vm.selectedAwakeMode = mode
                if keepAwake.isActive {
                    keepAwake.restoreSession(isActive: true, mode: mode, expiresAt: keepAwake.expiresAt)
                }
            }
        )
    }

    private func start(minutes: Int?) {
        updateSession { keepAwake.start(durationMinutes: minutes, mode: vm.selectedAwakeMode) }
    }

    private func updateSession(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.2), action)
    }
}

struct CleanKeysSettingsPane: View {
    @Bindable var vm: TrayViewModel
    @Bindable var cleaning: CleaningModeManager

    private let tint = TraySection.cleanKeys.accentColor

    private var canLock: Bool { cleaning.hasAccessibility && !cleaning.permissionDenied }

    var body: some View {
        UpkeepSettingsFormView {
            lockStatus
                .upkeepSearchTarget("power.cleanKeys")
        } content: {
            UpkeepSettingsSection("When Locked") {
                HStack(spacing: 8) {
                    Picker(selection: $vm.cleaningDuration) {
                        Text("30 sec").tag(30)
                        Text("1 min").tag(60)
                        Text("2 min").tag(120)
                    } label: {
                        UpkeepSettingLabel("Lock Duration")
                    }
                    .pickerStyle(.segmented)
                    .tint(UpkeepSettingsPalette.accent)
                    UpkeepResetButton(isModified: vm.cleaningDuration != 60) {
                        vm.cleaningDuration = 60
                    }
                }
                .upkeepSearchTarget("power.lockDuration")

                Toggle(isOn: $vm.cleaningDimScreen) {
                    UpkeepSettingLabel("Dim Screen", subtitle: "Make dust and smudges easier to see on connected displays.")
                }
                .tint(UpkeepSettingsPalette.accent)
                .accessibilityLabel("Dim Screen")
                .upkeepSearchTarget("power.dimScreen")

                Toggle(isOn: $vm.cleaningLockPointer) {
                    UpkeepSettingLabel("Lock Pointer & Trackpad", subtitle: "Ignore mouse clicks and trackpad taps while cleaning.")
                }
                .tint(UpkeepSettingsPalette.accent)
                .accessibilityLabel("Lock Pointer & Trackpad")
                .upkeepSearchTarget("power.lockPointer")
            }

            UpkeepSettingsSection("Unlock Early") {
                UpkeepSettingsShortcut(title: "Hold for 1 second", keys: ["⌘", "Esc"])
                    .upkeepSearchTarget("power.unlock")
                UpkeepSettingsShortcut(title: "Or press six times", keys: ["⌘"])
            }
        }
    }

    private var lockStatus: some View {
        UpkeepSettingsFeature(title: statusTitle, tint: canLock ? tint : .orange) {
            UpkeepSettingsIcon(
                systemName: cleaning.isLocked ? "lock.fill" : "keyboard",
                color: canLock ? tint : .orange,
                size: 44
            )
        } detail: {
            if cleaning.isLocked {
                Text("\(cleaning.remainingSeconds) seconds remaining")
                    .monospacedDigit()
            } else if canLock {
                Text("Lock the keyboard for \(vm.cleaningDuration) seconds.")
            } else {
                Text("Allow Accessibility access to pause keyboard input.")
            }
        } actions: {
            if cleaning.isLocked {
                Button("Unlock Keyboard") { cleaning.stop() }
                    .buttonStyle(.upkeepSecondary)
            } else if canLock {
                Button("Lock Keyboard") {
                    cleaning.start(
                        durationSeconds: vm.cleaningDuration,
                        dimScreen: vm.cleaningDimScreen,
                        lockPointer: vm.cleaningLockPointer
                    )
                }
                .buttonStyle(.upkeepPrimary)
                .tint(UpkeepSettingsPalette.accent)
            } else {
                Button("Grant Accessibility…") { cleaning.openAccessibilitySettings() }
                    .buttonStyle(.upkeepPrimary)
                    .tint(UpkeepSettingsPalette.accent)
            }
        }
    }

    private var statusTitle: String {
        if cleaning.isLocked { return "Keyboard is locked" }
        return canLock ? "Keyboard is unlocked" : "Accessibility access required"
    }
}
