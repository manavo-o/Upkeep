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
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name):
            return "Could not find '\(name)' in Homebrew (/opt/homebrew/bin), Cargo (~/.cargo/bin), or system PATH."
        case .executionFailed(let command, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "'\(command)' exited with status \(code)\(detail.isEmpty ? "" : ": \(detail)")"
        case .cancelled:
            return "Command was cancelled."
        }
    }
}

public enum CLIExecutor {
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
        binaryCache.resolve(name)
    }

    public static func invalidateBinaryCache() {
        binaryCache.invalidate()
    }

    public static func stripANSI(_ input: String) -> String {
        SpotlightEngine.stripANSI(input)
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

        // Drain stdout & stderr continuously while the process runs to prevent 64KB pipe buffer deadlocks.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outAcc.append(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errAcc.append(chunk)
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

    /// Runs an interactive CLI inside a POSIX pseudo-terminal (PTY) so tools that require a TTY
    /// (such as `mo uninstall`) execute with full fidelity. When `autoConfirmTrigger` appears in
    /// the PTY stream, writes `autoConfirmInput` after a short delay to clear input draining.
    public static func runInPTY(
        binary: String,
        arguments: [String],
        environment: [String: String] = [:],
        autoConfirmTrigger: String? = nil,
        autoConfirmInput: String = "y\n",
        confirmDelayMs: UInt64 = 180
    ) async throws -> CLIResult {
        guard let executablePath = resolveBinary(binary) else {
            throw CLIError.binaryNotFound(binary)
        }

        var rawMasterFD: Int32 = -1
        var rawSlaveFD: Int32 = -1
        guard openpty(&rawMasterFD, &rawSlaveFD, nil, nil, nil) == 0 else {
            throw CLIError.executionFailed(command: binary, exitCode: -1, stderr: "Failed to allocate pseudo-terminal (openpty).")
        }
        let masterFD = rawMasterFD
        let slaveFD = rawSlaveFD

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let joinedPaths = searchPaths.joined(separator: ":")
        env["PATH"] = joinedPaths + ":" + (env["PATH"] ?? "")
        env["TERM"] = "xterm-256color"
        env["NO_COLOR"] = "1"
        for (k, v) in environment {
            env[k] = v
        }
        process.environment = env

        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        final class PTYState: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            private var confirmed = false
            private var continuation: CheckedContinuation<CLIResult, Error>?

            init(_ continuation: CheckedContinuation<CLIResult, Error>) {
                self.continuation = continuation
            }

            func appendAndCheckTrigger(_ bytes: [UInt8], count: Int, trigger: String?) -> Bool {
                lock.lock()
                data.append(bytes, count: count)
                var shouldConfirm = false
                if !confirmed, let trigger, !trigger.isEmpty {
                    let tailSlice = data.suffix(2048)
                    if let text = String(data: tailSlice, encoding: .utf8),
                       text.contains(trigger) {
                        confirmed = true
                        shouldConfirm = true
                    }
                }
                lock.unlock()
                return shouldConfirm
            }

            func takeString() -> String {
                lock.lock()
                let copy = data
                lock.unlock()
                return String(data: copy, encoding: .utf8) ?? ""
            }

            func resumeOnce(_ result: Result<CLIResult, Error>) {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(with: result)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state = PTYState(continuation)
                let readDone = DispatchGroup()
                readDone.enter()

                do {
                    try process.run()
                    // Close slave fd in parent so EOF/EIO arrives on master when child exits
                    Darwin.close(slaveFD)
                } catch {
                    Darwin.close(slaveFD)
                    Darwin.close(masterFD)
                    readDone.leave()
                    state.resumeOnce(.failure(error))
                    return
                }

                // Read PTY master using raw POSIX read() so EIO on slave close exits cleanly
                DispatchQueue.global(qos: .userInitiated).async {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = Darwin.read(masterFD, &buffer, buffer.count)
                        if n > 0 {
                            if state.appendAndCheckTrigger(buffer, count: n, trigger: autoConfirmTrigger) {
                                let payload = Array(autoConfirmInput.utf8)
                                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                                    deadline: .now() + .milliseconds(Int(confirmDelayMs))
                                ) {
                                    _ = payload.withUnsafeBytes { ptr in
                                        Darwin.write(masterFD, ptr.baseAddress, ptr.count)
                                    }
                                }
                            }
                        } else if n < 0 && errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    readDone.leave()
                }

                process.terminationHandler = { proc in
                    proc.terminationHandler = nil
                    readDone.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                        Darwin.close(masterFD)
                        let cleanOutput = SpotlightEngine.stripANSI(state.takeString())
                        state.resumeOnce(.success(CLIResult(
                            exitCode: proc.terminationStatus,
                            stdout: cleanOutput,
                            stderr: proc.terminationStatus == 0 ? "" : cleanOutput
                        )))
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
