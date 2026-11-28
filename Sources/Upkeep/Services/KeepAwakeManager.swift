import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation

public enum KeepAwakeMode: String, CaseIterable, Sendable {
    case displayAndSystem = "Display + System"
    case systemOnly = "System Only"

    var assertionType: CFString {
        switch self {
        case .displayAndSystem:
            return kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        case .systemOnly:
            return kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        }
    }

    var activityOptions: ProcessInfo.ActivityOptions {
        switch self {
        case .displayAndSystem:
            return [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated]
        case .systemOnly:
            return [.idleSystemSleepDisabled, .userInitiated]
        }
    }
}

@MainActor
@Observable
public final class KeepAwakeManager {
    public static let shared = KeepAwakeManager()

    public private(set) var isActive: Bool = false
    public private(set) var mode: KeepAwakeMode = .displayAndSystem
    public private(set) var expiresAt: Date?
    public private(set) var usingIOKitAssertion: Bool = false
    private static let closedLidPreferenceKey = "caffeinateWithLidClosed"
    private(set) var keepsAwakeWithLidClosed = UserDefaults.standard.bool(forKey: closedLidPreferenceKey)
    let closedLid = ClosedLidSession()

    /// Computed on demand so views observing `expiresAt` don't suffer 1 Hz `@Observable` invalidation storms.
    /// Live window countdowns should bind directly to `expiresAt` via `Text(expiresAt, style: .timer)`.
    public var remainingSeconds: Int? {
        guard isActive, let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSinceNow.rounded(.up)))
    }

    private var assertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var activityToken: NSObjectProtocol?
    private var expirationTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let expiry = self.expiresAt else { return }
                if expiry <= Date() {
                    self.stop()
                } else {
                    self.scheduleExpiration(at: expiry)
                }
            }
        }
    }

    public func start(durationMinutes: Int?, mode: KeepAwakeMode = .displayAndSystem) {
        clearIdleSleepSession()

        let reason = "Upkeep Caffeinated Mac"
        var newID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            mode.assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )

        if status == kIOReturnSuccess {
            self.assertionID = newID
            self.usingIOKitAssertion = true

            // For displayAndSystem, also guarantee system idle sleep is prevented
            if mode == .displayAndSystem {
                var sysID: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason as CFString,
                    &sysID
                ) == kIOReturnSuccess {
                    self.systemAssertionID = sysID
                }
            }
        } else {
            // Resilient macOS Foundation fallback when IOKit powerd Mach port is restricted
            self.activityToken = ProcessInfo.processInfo.beginActivity(
                options: mode.activityOptions,
                reason: reason
            )
            self.usingIOKitAssertion = false
        }

        self.mode = mode
        self.isActive = true
        setExpiration(durationMinutes.flatMap { $0 > 0 ? Date().addingTimeInterval(TimeInterval($0) * 60) : nil })
        applyClosedLidPreference()
    }

    func applyDuration(minutes: Int?, mode: KeepAwakeMode) {
        guard isActive else {
            start(durationMinutes: minutes, mode: mode)
            return
        }
        setExpiration(minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) })
    }

    private func setExpiration(_ date: Date?) {
        expiresAt = date
        if let date {
            scheduleExpiration(at: date)
        } else {
            expirationTask?.cancel()
            expirationTask = nil
        }
    }

    func restoreSession(isActive: Bool, mode: KeepAwakeMode, expiresAt: Date?) {
        self.mode = mode
        guard isActive else { return }
        if let expiresAt, expiresAt <= Date() { return }
        start(durationMinutes: nil, mode: mode)
        if let expiresAt {
            setExpiration(expiresAt)
        }
    }

    public func extend(byMinutes minutes: Int) {
        guard isActive else {
            start(durationMinutes: minutes, mode: mode)
            return
        }
        let base = expiresAt ?? Date()
        setExpiration(base.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    public func stop() {
        closedLid.stop()
        clearIdleSleepSession()
    }

    func enableKeepsAwakeWithLidClosed() async {
        if await closedLid.prepare() { setKeepsAwakeWithLidClosed(true) }
    }

    func setKeepsAwakeWithLidClosed(_ enabled: Bool) {
        guard keepsAwakeWithLidClosed != enabled else { return }
        keepsAwakeWithLidClosed = enabled
        UserDefaults.standard.set(enabled, forKey: Self.closedLidPreferenceKey)
        if enabled { applyClosedLidPreference() } else { closedLid.stop() }
    }

    private func applyClosedLidPreference() {
        guard isActive, keepsAwakeWithLidClosed else { return }
        closedLid.start(onRestored: { [weak self] in
            self?.applyClosedLidPreference()
        })
    }

    private func clearIdleSleepSession() {
        expirationTask?.cancel()
        expirationTask = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        usingIOKitAssertion = false
        isActive = false
        expiresAt = nil
    }

    public var formattedRemaining: String {
        guard isActive else { return "Off" }
        guard let seconds = remainingSeconds else { return "Indefinite" }
        let hrs = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        if hrs > 0 {
            return String(format: "%dh %02dm", hrs, mins)
        }
        return String(format: "%02dm %02ds", mins, secs)
    }

    private func scheduleExpiration(at target: Date) {
        expirationTask?.cancel()
        let delay = max(0, target.timeIntervalSinceNow)
        expirationTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.stop()
        }
    }
}
