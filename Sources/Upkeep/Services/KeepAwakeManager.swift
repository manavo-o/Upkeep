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
    /// Observable formatted countdown string updated only when its text changes, so menu bar items
    /// refresh live while views using `Text(expiresAt, style: .timer)` avoid 1 Hz invalidation.
    public private(set) var formattedRemaining: String = "Off"
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
    private var displayTimer: Timer?

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
                    self.refreshFormattedRemaining()
                    self.startDisplayTimer()
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
        startDisplayTimer()
        refreshFormattedRemaining()
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

    func toggleClosedLid(mode: KeepAwakeMode) {
        if closedLid.isEngaged {
            closedLid.stop()
        } else {
            closedLid.start { [weak self] in
                guard let self, !self.isActive else { return }
                self.start(durationMinutes: 60, mode: mode)
            }
        }
    }

    private func clearIdleSleepSession() {
        expirationTask?.cancel()
        expirationTask = nil
        displayTimer?.invalidate()
        displayTimer = nil
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
        formattedRemaining = "Off"
    }

    private func computeFormattedRemaining() -> String {
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

    private var displayTimerIsMinuteCadence: Bool = false

    private func refreshFormattedRemaining() {
        let next = computeFormattedRemaining()
        if next != formattedRemaining {
            formattedRemaining = next
        }
        // Automatically switch from 60s cadence to 1s cadence when crossing under 1 hour.
        if isActive, let secs = remainingSeconds {
            let wantsMinuteCadence = secs >= 3600
            if displayTimer != nil && wantsMinuteCadence != displayTimerIsMinuteCadence {
                startDisplayTimer()
            }
        }
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        guard isActive, let secs = remainingSeconds else {
            displayTimer = nil
            return
        }
        // Above 1 hour the display format is "%dh %02dm" (changes only once per minute),
        // so wake every 60s instead of 1 Hz (60x fewer idle CPU wakeups).
        let useMinuteCadence = secs >= 3600
        displayTimerIsMinuteCadence = useMinuteCadence
        let interval: TimeInterval = useMinuteCadence ? 60.0 : 1.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFormattedRemaining()
            }
        }
        timer.tolerance = useMinuteCadence ? 2.0 : 0.25
        // The open status menu has a dedicated timer that only redraws its countdown field.
        RunLoop.main.add(timer, forMode: .default)
        displayTimer = timer
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
