import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

public enum ProcessError: LocalizedError {
    case launchFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): return "Could not start: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// A child process whose output is read on background threads, so a chatty
/// ffmpeg can never fill a pipe and deadlock.
public final class RunningProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    public init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
    }

    public static func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessResult {
        try await RunningProcess(executable: executable, arguments: arguments).run()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    public func waitUntilExit() {
        if process.isRunning { process.waitUntilExit() }
    }

    /// With `onStdout`, stdout is streamed to it instead of being collected.
    public func run(onStdout: (@Sendable (Data) -> Void)? = nil) async throws -> ProcessResult {
        if isCancelled { throw ProcessError.cancelled }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        final class Buffers: @unchecked Sendable {
            var out = Data()
            var err = Data()
        }
        let buffers = Buffers()

        return try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProcessError.launchFailed(error.localizedDescription))
                return
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = outPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if let onStdout { onStdout(chunk) } else { buffers.out.append(chunk) }
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                buffers.err = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            group.notify(queue: .global()) {
                if self.isCancelled {
                    continuation.resume(throwing: ProcessError.cancelled)
                } else {
                    continuation.resume(returning: ProcessResult(status: self.process.terminationStatus,
                                                                 stdout: buffers.out, stderr: buffers.err))
                }
            }
        }
    }
}

public enum FFmpegLocator {
    /// Looks inside the app bundle first (bundled build), then Homebrew / system paths.
    public static func find(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name) { candidates.append(bundled) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)"))
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent(name))
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
