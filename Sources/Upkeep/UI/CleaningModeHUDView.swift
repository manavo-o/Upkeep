import SwiftUI

public struct CleaningModeHUDView: View {
    @Bindable var manager: CleaningModeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(manager: CleaningModeManager) {
        self.manager = manager
    }

    private var activeProgress: Double {
        manager.isHoldingToUnlock ? manager.holdUnlockProgress : manager.remainingFraction
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Top Liquid Glass status pill with continuous circular countdown & hold-to-unlock ring
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(.primary.opacity(0.15), lineWidth: 3)

                    Circle()
                        .trim(from: 0, to: activeProgress)
                        .stroke(
                            manager.isHoldingToUnlock ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(Color.blue.gradient),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion || manager.isHoldingToUnlock ? nil : UpkeepMotion.paneEntrance, value: manager.remainingFraction)
                        .animation(nil, value: manager.isHoldingToUnlock)

                    Image(systemName: manager.isHoldingToUnlock ? "lock.open.fill" : "keyboard.badge.ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(manager.isHoldingToUnlock ? .green : .primary)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.isHoldingToUnlock ? "Hold to Unlock…" : "Cleaning Mode")
                        .font(.system(size: 16, weight: .semibold))
                    Text(manager.lockPointer ? "Keyboard & Pointer Locked" : "Keyboard Locked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(manager.remainingSeconds)s")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .foregroundStyle(.secondary)

                if !manager.lockPointer {
                    Button("Unlock") {
                        manager.stop()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 22)
            .frame(width: 460, height: 64)
            .upkeepGlass(in: Capsule())

            // Detached unlock hint tray (20pt Golden Gate radius)
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                Text("Hold ⌘ + Esc (1s) or tap ⌘ six times to unlock")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                if manager.commandTapCount > 0 {
                    Text("\(manager.commandTapCount)/6")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 20)
            .frame(width: 460, height: 44)
            .upkeepGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(24)
    }
}
