import Darwin
import Foundation

public struct CLIResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { exitCode == 0 }
}

public enum CLIError: LocalizedError, Sendable {
    case binaryNotFound(String)
    case executionFailed(command: String, exitCode: Int32, stderr: String)
    case invalidOutput(command: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "Could not find '\(name)' in Homebrew (/opt/homebrew/bin), Cargo (~/.cargo/bin), or system PATH."
        case .executionFailed(let command, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "'\(command)' exited with status \(code)\(detail.isEmpty ? "" : ": \(detail)")"
        case .invalidOutput(let command):
            return "'\(command)' returned unreadable package information."
        case .cancelled:
            return "Command was cancelled."
        }
    }
}

public enum CLIExecutor {
    private final class CommandActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func begin() { lock.withLock { count += 1 } }
        func end() { lock.withLock { count -= 1 } }
        var isRunning: Bool { lock.withLock { count > 0 } }
    }

    private static let activity = CommandActivity()
    static var hasRunningCommands: Bool { activity.isRunning }

    public static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        (NSHomeDirectory() as NSString).appendingPathComponent(".cargo/bin"),
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    private final class BinaryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: String?] = [:]

        func resolve(_ name: String) -> String? {
            lock.lock()
            if let cached = cache[name] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let fm = FileManager.default
            var found: String? = nil
            for dir in CLIExecutor.searchPaths {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate) {
                    found = candidate
                    break
                }
            }

            lock.lock()
            cache[name] = found
            lock.unlock()
            return found
        }

        func invalidate() {
            lock.lock()
            cache.removeAll()
            lock.unlock()
        }
    }

    private static let binaryCache = BinaryCache()

    public static func resolveBinary(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        return binaryCache.resolve(name)
    }

    public static func invalidateBinaryCache() {
        binaryCache.invalidate()
    }

    public static func stripANSI(_ input: String) -> String {
        UpkeepEngine.stripANSI(input)
    }

    private final class PipeAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func takeData() -> Data {
            lock.lock()
            let copy = data
            lock.unlock()
            return copy
        }
    }

    public static func run(
        binary: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> CLIResult {
        try await runStreaming(
            binary: binary,
            arguments: arguments,
            environment: environment,
            onLine: nil
        )
    }

    /// Executes a CLI process while streaming ANSI-stripped stdout/stderr lines live as they arrive.
    public static func runStreaming(
        binary: String,
        arguments: [String],
        environment: [String: String] = [:],
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> CLIResult {
        activity.begin()
        defer { activity.end() }

        guard let executablePath = resolveBinary(binary) else {
            throw CLIError.binaryNotFound(binary)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let joinedPaths = searchPaths.joined(separator: ":")
        env["PATH"] = joinedPaths + ":" + (env["PATH"] ?? "")
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        for (k, v) in environment {
            env[k] = v
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outAcc = PipeAccumulator()
        let errAcc = PipeAccumulator()

        final class ContinuationBox: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<CLIResult, Error>?

            init(_ continuation: CheckedContinuation<CLIResult, Error>) {
                self.continuation = continuation
            }

            func resumeOnce(_ result: Result<CLIResult, Error>) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(with: result)
            }
        }

        final class LineStreamBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var pending = Data()
            private let onLine: (@Sendable (String) -> Void)?

            init(onLine: (@Sendable (String) -> Void)?) {
                self.onLine = onLine
            }

            func feed(_ chunk: Data) {
                guard let onLine, !chunk.isEmpty else { return }
                var emitted: [String] = []
                lock.lock()
                pending.append(chunk)
                var cursor = pending.startIndex
                while let nl = pending[cursor...].firstIndex(of: 0x0A) {
                    let lineData = pending[cursor..<nl]
                    cursor = pending.index(after: nl)
                    if let raw = String(data: lineData, encoding: .utf8) {
                        let clean = UpkeepEngine.stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty {
                            emitted.append(clean)
                        }
                    }
                }
                if cursor == pending.endIndex {
                    pending.removeAll(keepingCapacity: true)
                } else if cursor > pending.startIndex {
                    pending = Data(pending[cursor...])
                }
                lock.unlock()
                for line in emitted {
                    onLine(line)
                }
            }

            func flush() {
                guard let onLine else { return }
                lock.lock()
                let rem = pending
                pending.removeAll()
                lock.unlock()
                if !rem.isEmpty, let raw = String(data: rem, encoding: .utf8) {
                    let clean = UpkeepEngine.stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        onLine(clean)
                    }
                }
            }
        }

        let outStream = LineStreamBuffer(onLine: onLine)
        let errStream = LineStreamBuffer(onLine: onLine)

        // Drain stdout & stderr continuously while the process runs to prevent 64KB pipe buffer deadlocks.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outAcc.append(chunk)
                outStream.feed(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errAcc.append(chunk)
                errStream.feed(chunk)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = ContinuationBox(continuation)

                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remainingOut = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let remainingErr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    outAcc.append(remainingOut)
                    errAcc.append(remainingErr)
                    outStream.feed(remainingOut)
                    errStream.feed(remainingErr)
                    outStream.flush()
                    errStream.flush()

                    let outStr = String(data: outAcc.takeData(), encoding: .utf8) ?? ""
                    let errStr = String(data: errAcc.takeData(), encoding: .utf8) ?? ""
                    proc.terminationHandler = nil
                    box.resumeOnce(.success(CLIResult(
                        exitCode: proc.terminationStatus,
                        stdout: outStr,
                        stderr: errStr
                    )))
                }

                do {
                    try process.run()
                    // Close the parent write ends so that the only open write handles are in the child process.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    box.resumeOnce(.failure(error))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
