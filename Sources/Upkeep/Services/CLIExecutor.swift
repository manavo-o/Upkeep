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
    public enum OutputCapture: Sendable {
        case full
        case tail(maxBytes: Int)
    }

    static let truncationMarker = "… (earlier output truncated)\n"

    static func boundedTail(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let marker = truncationMarker.utf8.count <= maxBytes ? truncationMarker : ""
        let tail = text.utf8.suffix(max(0, maxBytes - marker.utf8.count))
        return marker + String(decoding: tail.drop(while: isUTF8Continuation), as: UTF8.self)
    }

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }

    private final class CommandActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func begin() { lock.withLock { count += 1 } }
        func end() {
            let becameIdle = lock.withLock {
                count -= 1
                return count == 0
            }
            if becameIdle {
                NotificationCenter.default.post(name: IdleMemoryRecovery.workDidBecomeIdle, object: nil)
            }
        }
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
        private let limit: Int?
        private var data = Data()
        private var wasTruncated = false

        init(capture: OutputCapture) {
            if case .tail(let maxBytes) = capture {
                limit = min(max(0, maxBytes), Int.max / 2)
            } else {
                limit = nil
            }
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.withLock {
                guard let limit else {
                    data.append(chunk)
                    return
                }
                if chunk.count >= limit {
                    wasTruncated = wasTruncated || !data.isEmpty || chunk.count > limit
                    data = chunk.subdata(in: (chunk.endIndex - limit)..<chunk.endIndex)
                } else {
                    data.append(chunk)
                    // Compact in batches so high-volume output doesn't copy the tail for each small read.
                    if data.count > limit * 2 {
                        wasTruncated = true
                        data = data.subdata(in: (data.endIndex - limit)..<data.endIndex)
                    }
                }
            }
        }

        func output() -> String {
            lock.withLock {
                guard let limit else { return String(data: data, encoding: .utf8) ?? "" }
                guard wasTruncated || data.count > limit else { return String(decoding: data, as: UTF8.self) }
                let marker = truncationMarker.utf8.count <= limit ? truncationMarker : ""
                let tail = data.suffix(limit - marker.utf8.count).drop(while: isUTF8Continuation)
                return boundedTail(marker + String(decoding: tail, as: UTF8.self), maxBytes: limit)
            }
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
        capture: OutputCapture = .full,
        onLine: (@Sendable (String) -> Void)?
    ) async throws -> CLIResult {
        let onLines: (@Sendable ([String]) -> Void)?
        if let onLine {
            onLines = { lines in lines.forEach(onLine) }
        } else {
            onLines = nil
        }
        let liveLineLimit: Int?
        if case .tail(let maxBytes) = capture {
            liveLineLimit = max(0, maxBytes)
        } else {
            liveLineLimit = nil
        }
        return try await runStreamingBatches(
            binary: binary, arguments: arguments, environment: environment,
            capture: capture, liveLineLimit: liveLineLimit, onLines: onLines
        )
    }

    static func runStreamingBatches(
        binary: String,
        arguments: [String],
        environment: [String: String],
        capture: OutputCapture,
        liveLineLimit: Int? = nil,
        onLines: (@Sendable ([String]) -> Void)?
    ) async throws -> CLIResult {
        try Task.checkCancellation()
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

        let outAcc = PipeAccumulator(capture: capture)
        let errAcc = PipeAccumulator(capture: capture)

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
            private var pending = Data()
            private let onLines: (@Sendable ([String]) -> Void)?
            private let limit: Int?

            init(onLines: (@Sendable ([String]) -> Void)?, limit: Int?) {
                self.onLines = onLines
                self.limit = limit
            }

            func feed(_ chunk: Data) {
                guard let onLines, !chunk.isEmpty else { return }
                var emitted: [String] = []
                let newBytesStart = pending.endIndex
                pending.append(chunk)
                var cursor = pending.startIndex
                var searchStart = newBytesStart
                while let nl = pending[searchStart...].firstIndex(of: 0x0A) {
                    if let line = cleaned(pending[cursor..<nl]) { emitted.append(line) }
                    cursor = pending.index(after: nl)
                    searchStart = cursor
                }
                if let limit, pending.endIndex - cursor > limit {
                    pending = Data(pending.suffix(limit).drop(while: CLIExecutor.isUTF8Continuation))
                } else if cursor > pending.startIndex {
                    pending = Data(pending[cursor...])
                }
                if !emitted.isEmpty { onLines(emitted) }
            }

            private func cleaned(_ bytes: Data) -> String? {
                let raw: String?
                if let limit {
                    let tail = bytes.suffix(limit).drop(while: CLIExecutor.isUTF8Continuation)
                    raw = String(decoding: tail, as: UTF8.self)
                } else {
                    raw = String(data: bytes, encoding: .utf8)
                }
                guard let raw else { return nil }
                let line = UpkeepEngine.stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                return line.isEmpty ? nil : line
            }

            func flush() {
                if !pending.isEmpty, let line = cleaned(pending) { onLines?([line]) }
                pending.removeAll()
            }
        }

        let outStream = LineStreamBuffer(onLines: onLines, limit: liveLineLimit)
        let errStream = LineStreamBuffer(onLines: onLines, limit: liveLineLimit)
        let readers = DispatchGroup()

        // Each FileHandle serializes its reads. Finish the command only after both streams reach EOF.
        func drain(_ pipe: Pipe, into accumulator: PipeAccumulator, stream: LineStreamBuffer) {
            readers.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    stream.flush()
                    readers.leave()
                } else {
                    accumulator.append(chunk)
                    stream.feed(chunk)
                }
            }
        }
        drain(stdoutPipe, into: outAcc, stream: outStream)
        drain(stderrPipe, into: errAcc, stream: errStream)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = ContinuationBox(continuation)

                process.terminationHandler = { proc in
                    let exitCode = proc.terminationStatus
                    proc.terminationHandler = nil
                    readers.notify(queue: .global(qos: .utility)) {
                        box.resumeOnce(.success(CLIResult(
                            exitCode: exitCode, stdout: outAcc.output(), stderr: errAcc.output()
                        )))
                    }
                }

                do {
                    try Task.checkCancellation()
                    try process.run()
                    // Close the parent write ends so that the only open write handles are in the child process.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
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
