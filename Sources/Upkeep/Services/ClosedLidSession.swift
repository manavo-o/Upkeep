import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class ClosedLidSession {
    enum State: Equatable {
        case off, authorizing, starting, active, stopping
        case failed(String)
    }

    private(set) var state = State.off
    @ObservationIgnored private var connection: Int32 = -1
    @ObservationIgnored private var reader: DispatchSourceRead?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var restorationFailed = false

    private static let service = "com.local.Upkeep.closed-lid-\(getuid())"
    private static let socketPath = "/var/run/\(service).sock"

    var isEngaged: Bool {
        state == .authorizing || state == .starting || state == .active || state == .stopping
    }

    private var hasHelper: Bool {
        var info = stat()
        return lstat(Self.socketPath, &info) == 0
            && info.st_mode & S_IFMT == S_IFSOCK
            && info.st_uid == getuid()
            && info.st_mode & 0o777 == 0o600
    }

    func prepare() async -> Bool {
        if hasHelper { return true }
        guard !isEngaged else { return false }
        state = .authorizing

        let definition: [String: Any] = [
            "Label": Self.service,
            "ProgramArguments": [
                "/usr/bin/lockf", "-k", "-t", "5", "/var/run/com.local.Upkeep.closed-lid.lock",
                "/bin/sh", "-c", Self.watchdog
            ],
            "inetdCompatibility": ["Wait": false],
            "Sockets": ["Session": [
                "SockPathName": Self.socketPath,
                "SockPathOwner": getuid(),
                "SockPathMode": 0o600
            ]],
            "ThrottleInterval": 1
        ]
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0) else {
            state = .failed("Upkeep couldn’t prepare closed-lid setup.")
            return false
        }

        let destination = Self.shellQuote("/Library/LaunchDaemons/\(Self.service).plist")
        let command = """
        set -eu
        temp=$(/usr/bin/mktemp /Library/LaunchDaemons/.upkeep-closed-lid.XXXXXX)
        trap '/bin/rm -f "$temp"' EXIT
        /usr/bin/printf '%s' \(Self.shellQuote(plist.base64EncodedString())) | /usr/bin/base64 -D > "$temp"
        /usr/sbin/chown root:wheel "$temp"
        /bin/chmod 644 "$temp"
        /bin/mv -f "$temp" \(destination)
        /bin/launchctl bootstrap system \(destination)
        """
        let script = """
        try
            do shell script \(Self.appleScriptString(command)) with administrator privileges with prompt "Allow Upkeep to manage system sleep during future Caffeinate sessions with the lid closed."
        on error messageText number errorNumber
            if errorNumber is -128 then return "cancelled"
            error messageText number errorNumber
        end try
        """
        let result = try? await CLIExecutor.run(binary: "/usr/bin/osascript", arguments: ["-e", script])
        if hasHelper {
            state = .off
            return true
        }
        let declined = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "cancelled"
        state = declined ? .off : .failed("Upkeep couldn’t finish the one-time closed-lid setup.")
        return false
    }

    func start(onRestored: @escaping @MainActor () -> Void) {
        guard !isEngaged else { return }
        guard hasHelper, let fd = connectToHelper() else {
            state = .failed("The closed-lid helper is unavailable. Turn the setting off and on to set it up again.")
            return
        }

        connection = fd
        restorationFailed = false
        state = .starting
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.readStatus(from: fd, onRestored: onRestored)
            }
        }
        reader = source
        source.resume()

        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.connection == fd else { return }
            self.closeConnection()
            self.state = .failed("The closed-lid helper didn’t respond.")
        }
    }

    func stop() {
        guard state == .starting || state == .active else { return }
        state = .stopping
        shutdown(connection, SHUT_WR)
    }

    private func readStatus(from fd: Int32, onRestored: () -> Void) {
        guard connection == fd else { return }
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = read(fd, &bytes, bytes.count)
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        if count > 0 {
            if bytes.prefix(count).contains(65), state == .starting { // A: active
                timeout?.cancel()
                state = .active
            }
            if bytes.prefix(count).contains(70) { restorationFailed = true } // F: restore failed
            return
        }
        closeConnection()
        if restorationFailed {
            state = .failed("Upkeep couldn’t restore system sleep. Restart your Mac to retry.")
        } else if state == .stopping {
            state = .off
            onRestored()
        } else {
            state = .failed("Upkeep couldn’t enable closed-lid mode.")
        }
    }

    private func closeConnection() {
        timeout?.cancel()
        timeout = nil
        shutdown(connection, SHUT_RDWR)
        connection = -1
        reader?.cancel()
        reader = nil
    }

    private func connectToHelper() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath.utf8CString
        let size = MemoryLayout<sockaddr_un>.size
        address.sun_len = UInt8(size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.map { UInt8(bitPattern: $0) })
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(size))
            }
        }
        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard connected == 0, getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // EOF releases the session when Upkeep stops or exits.
    // The boot job covers a power loss before the watchdog can restore sleep.
    private static let watchdog = #"""
    set -eu
    exec 2>/dev/null
    trap '' PIPE
    recovery=/Library/LaunchDaemons/com.local.Upkeep.restore-sleep.plist

    sleep_setting() {
        settings=$(/usr/bin/pmset -g) || return 1
        printf '%s\n' "$settings" | /usr/bin/awk '$1 == "SleepDisabled" {print $2}'
    }
    disabled=$(sleep_setting)
    case "$disabled" in
        1)
            # A setting Upkeep already owns is identified by its recovery job.
            if [ -f "$recovery" ]; then
                /usr/bin/pmset -a disablesleep 0 >/dev/null
                disabled=0
            fi
            ;;
        0|"") disabled=0 ;;
        *) exit 1 ;;
    esac

    if [ "$disabled" = 0 ]; then
        restore() {
            if /usr/bin/pmset -a disablesleep 0 >/dev/null && [ "$(sleep_setting)" = 0 ]; then
                /bin/rm -f "$recovery"
            else
                printf F || :
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
        /usr/bin/pmset -a disablesleep 1 >/dev/null
        [ "$(sleep_setting)" = 1 ]
    fi

    printf A
    /bin/dd bs=1 count=1 > /dev/null
    """#
}
