import Darwin
import Foundation
import Observation
import notify

@MainActor
@Observable
final class ClosedLidSession {
    enum State: Equatable {
        case off, authorizing, active, stopping
        case failed(String)
    }

    private(set) var state = State.off
    @ObservationIgnored private var lease: FileHandle?

    var isEngaged: Bool {
        state == .authorizing || state == .active || state == .stopping
    }

    func start(onActivation: @escaping @MainActor () -> Void) {
        guard !isEngaged else { return }
        let token = UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Upkeep-\(token).lock")
        let fd = open(file.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            state = .failed("Upkeep couldn’t prepare closed-lid mode.")
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let notification = "com.local.Upkeep.closed-lid.\(token)"
        var observer: Int32 = 0
        guard flock(fd, LOCK_EX | LOCK_NB) == 0,
              notify_register_dispatch(notification, &observer, .main, { [weak self] _ in
                  MainActor.assumeIsolated {
                      guard let self, self.state == .authorizing else { return }
                      self.state = .active
                      onActivation()
                  }
              }) == NOTIFY_STATUS_OK else {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            state = .failed("Upkeep couldn’t prepare closed-lid mode.")
            return
        }

        lease = handle
        state = .authorizing
        let command = [
            "/usr/bin/lockf", "-k", "-t", "5", "/var/run/com.local.Upkeep.closed-lid.lock",
            "/bin/sh", "-c", Self.watchdog, "upkeep-closed-lid", file.path, notification
        ].map(Self.shellQuote).joined(separator: " ")
        let script = """
        try
            do shell script \(Self.appleScriptString(command)) with administrator privileges with prompt "Upkeep needs your approval to keep this Mac awake with the lid closed."
        on error messageText number errorNumber
            if errorNumber is -128 then return "cancelled"
            error messageText number errorNumber
        end try
        """

        Task {
            let result = try? await CLIExecutor.run(binary: "/usr/bin/osascript", arguments: ["-e", script])
            notify_cancel(observer)
            try? handle.close()
            lease = nil
            try? FileManager.default.removeItem(at: file)
            guard result?.succeeded == true else {
                let diagnostic = result?.stderr ?? ""
                if diagnostic.contains("could not restore") {
                    state = .failed("Upkeep couldn’t restore system sleep. Restart your Mac to retry.")
                } else if state == .stopping {
                    state = .off
                } else {
                    state = .failed("Upkeep couldn’t enable closed-lid mode.")
                }
                return
            }
            state = .off
        }
    }

    func stop() {
        guard state == .authorizing || state == .active else { return }
        state = .stopping
        try? lease?.close()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // lockf waits for Upkeep to close its lease, including when the process crashes.
    // The boot job covers a power loss before the watchdog can restore sleep.
    private static let watchdog = #"""
    set -eu
    lease=$1
    notification=$2
    recovery=/Library/LaunchDaemons/com.local.Upkeep.restore-sleep.plist

    held=0
    /usr/bin/lockf -s -n -k -t 0 "$lease" /usr/bin/true || held=$?
    case "$held" in
        75) ;;
        0|69) exit 0 ;;
        *) exit 1 ;;
    esac

    sleep_setting() {
        settings=$(/usr/bin/pmset -g) || return 1
        printf '%s\n' "$settings" | /usr/bin/awk '$1 == "SleepDisabled" {print $2}'
    }
    disabled=$(sleep_setting)
    case "$disabled" in
        1)
            # A setting Upkeep already owns is identified by its recovery job.
            if [ -f "$recovery" ]; then
                /usr/bin/pmset -a disablesleep 0
                disabled=0
            fi
            ;;
        0|"") disabled=0 ;;
        *) exit 1 ;;
    esac

    if [ "$disabled" = 0 ]; then
        restore() {
            if /usr/bin/pmset -a disablesleep 0 && [ "$(sleep_setting)" = 0 ]; then
                /bin/rm -f "$recovery"
            else
                printf '%s\n' 'Upkeep could not restore system sleep' >&2
                exit 1
            fi
        }
        trap restore EXIT
        trap 'exit 1' HUP INT TERM
        umask 022
        temp=$(/usr/bin/mktemp /Library/LaunchDaemons/.upkeep-restore-sleep.XXXXXX)
        /bin/cat > "$temp" <<'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.local.Upkeep.restore-sleep</string>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
            <key>SuccessfulExit</key>
            <false/>
        </dict>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/bin/lockf</string>
            <string>-k</string>
            <string>/var/run/com.local.Upkeep.closed-lid.lock</string>
            <string>/bin/sh</string>
            <string>-c</string>
            <string>[ ! -f /Library/LaunchDaemons/com.local.Upkeep.restore-sleep.plist ] || { /usr/bin/pmset -a disablesleep 0 &amp;&amp; /bin/rm -f /Library/LaunchDaemons/com.local.Upkeep.restore-sleep.plist; }</string>
        </array>
    </dict>
    </plist>
    PLIST
        /bin/chmod 644 "$temp"
        /bin/mv -f "$temp" "$recovery"
        /usr/bin/pmset -a disablesleep 1
        [ "$(sleep_setting)" = 1 ]
    fi

    /usr/bin/notifyutil -p "$notification"
    /usr/bin/lockf -n -k "$lease" /usr/bin/true
    """#
}
