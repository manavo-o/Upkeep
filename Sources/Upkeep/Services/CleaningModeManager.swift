import AppKit
import ApplicationServices
import Foundation
import Observation
import Synchronization

@MainActor
@Observable
public final class CleaningModeManager {
    public static let shared = CleaningModeManager()

    public private(set) var isLocked: Bool = false
    public private(set) var dimScreen: Bool = true
    public private(set) var lockPointer: Bool = false
    public private(set) var totalDurationSeconds: Int = 60
    public private(set) var remainingSeconds: Int = 60
    public private(set) var commandTapCount: Int = 0
    public private(set) var holdUnlockProgress: Double = 0.0
    public private(set) var permissionDenied: Bool = false
    public private(set) var hasAccessibility: Bool = false

    public var remainingFraction: Double {
        guard totalDurationSeconds > 0 else { return 0 }
        return max(0, min(1, Double(remainingSeconds) / Double(totalDurationSeconds)))
    }

    private nonisolated static let ownsPointerLock = Atomic<Bool>(false)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var countdownTask: Task<Void, Never>?
    private var holdUnlockTask: Task<Void, Never>?
    private var holdStartDate: Date?
    private var lastCommandTapTime: Date = .distantPast
    private(set) var hasPromptedThisSession: Bool = false
    private var onStateChange: (@MainActor (Bool) -> Void)?

    private init() {
        hasAccessibility = Self.hasAccessibilityPermission(prompt: false)

        // Observe macOS system-wide accessibility setting changes
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionStatus()
            }
        }

        // Clean up input lock and restore cursor association if application terminates
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }

        // Initialize the atomic before installing signal handlers.
        Self.ownsPointerLock.store(false, ordering: .relaxed)
        // A cancelled replacement must leave another process's pointer lock alone.
        signal(SIGINT) { _ in
            CleaningModeManager.releasePointerIfOwned()
            Foundation.exit(0)
        }
        signal(SIGTERM) { _ in
            CleaningModeManager.releasePointerIfOwned()
            Foundation.exit(0)
        }
    }

    public nonisolated static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        if prompt {
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let options = [key: kCFBooleanTrue] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        if AXIsProcessTrusted() {
            return true
        }

        // Direct session tap probe: accurately tests actual input interception permissions
        // even if AXIsProcessTrusted has a stale process-internal cache
        let probe = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
            callback: { _, _, ev, _ in Unmanaged.passUnretained(ev) },
            userInfo: nil
        )
        if let probe {
            CFMachPortInvalidate(probe)
            return true
        }
        return false
    }

    private var lastPermissionProbeAt: Date = .distantPast

    public func refreshPermissionStatus() {
        if AXIsProcessTrusted() {
            hasAccessibility = true
            permissionDenied = false
            return
        }
        // Avoid spawning a throwaway CGEvent Mach port on MainActor on every window focus
        let now = Date()
        guard now.timeIntervalSince(lastPermissionProbeAt) > 2.0 else { return }
        lastPermissionProbeAt = now
        Task.detached(priority: .utility) {
            let trusted = Self.hasAccessibilityPermission(prompt: false)
            await MainActor.run {
                self.hasAccessibility = trusted
                if trusted {
                    self.permissionDenied = false
                }
            }
        }
    }

    func restorePromptState(prompted: Bool, denied: Bool) {
        hasPromptedThisSession = prompted
        permissionDenied = denied && !hasAccessibility
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func setStateHandler(_ handler: @escaping @MainActor (Bool) -> Void) {
        self.onStateChange = handler
    }

    public func start(durationSeconds: Int = 60, dimScreen: Bool = true, lockPointer: Bool = false) {
        guard !isLocked else { return }

        let shouldPrompt = !hasPromptedThisSession
        hasPromptedThisSession = true
        let trusted = Self.hasAccessibilityPermission(prompt: shouldPrompt)
        hasAccessibility = trusted

        guard trusted else {
            permissionDenied = true
            return
        }
        permissionDenied = false

        var eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << 14) // NX_SYSDEFINED media keys

        if lockPointer {
            eventMask |= (1 << CGEventType.leftMouseDown.rawValue) |
                         (1 << CGEventType.rightMouseDown.rawValue) |
                         (1 << CGEventType.mouseMoved.rawValue) |
                         (1 << CGEventType.leftMouseDragged.rawValue) |
                         (1 << CGEventType.rightMouseDragged.rawValue) |
                         (1 << CGEventType.otherMouseDragged.rawValue) |
                         (1 << CGEventType.scrollWheel.rawValue)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<CleaningModeManager>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    DispatchQueue.main.async {
                        if let existingTap = manager.eventTap {
                            CGEvent.tapEnable(tap: existingTap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                if type.rawValue == 14 {
                    return nil
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

                if type == .flagsChanged || (keyCode == 53 && flags.contains(.maskCommand)) || type == .keyUp {
                    DispatchQueue.main.async {
                        manager.handleInterceptedEvent(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
                    }
                }

                // Swallow targeted input while locked
                return nil
            },
            userInfo: userInfo
        ) else {
            permissionDenied = true
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if lockPointer {
            Self.ownsPointerLock.store(true, ordering: .relaxed)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        }

        let clampedDuration = max(10, durationSeconds)
        self.eventTap = tap
        self.runLoopSource = source
        self.dimScreen = dimScreen
        self.lockPointer = lockPointer
        self.totalDurationSeconds = clampedDuration
        self.remainingSeconds = clampedDuration
        self.commandTapCount = 0
        self.holdUnlockProgress = 0
        self.isLocked = true
        self.onStateChange?(true)

        startCountdown()
    }

    public func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        cancelHoldUnlock()
        Self.releasePointerIfOwned()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        commandTapCount = 0
        holdUnlockProgress = 0
        if isLocked {
            isLocked = false
            onStateChange?(false)
        }
    }

    private nonisolated static func releasePointerIfOwned() {
        guard ownsPointerLock.load(ordering: .relaxed) else { return }
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        ownsPointerLock.store(false, ordering: .relaxed)
    }

    private func handleInterceptedEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) {
        let isCmdEsc = (keyCode == 53) && flags.contains(.maskCommand) // 53 = kVK_Escape

        // Failsafe unlock 1: 1.0s Hold ⌘ + Esc
        if type == .keyDown && isCmdEsc && !isRepeat && holdUnlockTask == nil {
            holdStartDate = Date()
            holdUnlockTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let start = self.holdStartDate else { break }
                    let elapsed = Date().timeIntervalSince(start)
                    self.holdUnlockProgress = min(1.0, elapsed / 1.0)
                    if elapsed >= 1.0 {
                        self.stop()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        } else if (type == .keyUp && keyCode == 53) || (type == .flagsChanged && !flags.contains(.maskCommand)) {
            cancelHoldUnlock()
        }

        // Failsafe unlock 2: Tap ⌘ six times rapidly
        if type == .flagsChanged && flags.contains(.maskCommand) {
            registerCommandTap()
        }
    }

    private func cancelHoldUnlock() {
        holdUnlockTask?.cancel()
        holdUnlockTask = nil
        holdStartDate = nil
        holdUnlockProgress = 0
    }

    private func registerCommandTap() {
        let now = Date()
        if now.timeIntervalSince(lastCommandTapTime) > 1.5 {
            commandTapCount = 1
        } else {
            commandTapCount += 1
        }
        lastCommandTapTime = now
        if commandTapCount >= 6 {
            stop()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                self.remainingSeconds -= 1
                if self.remainingSeconds <= 0 {
                    self.stop()
                    break
                }
            }
        }
    }
}
