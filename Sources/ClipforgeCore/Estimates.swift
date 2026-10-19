import Foundation

public enum SizeEstimator {
    /// Container overhead (MP4/MKV headers, indexes) as a fraction of the payload.
    static let overhead = 0.01

    /// Video bitrate that makes the whole file land on `targetMB`.
    public static func videoKbps(forTargetMB targetMB: Int, duration: Double, audioKbps: Int) -> Int {
        guard duration > 0 else { return 0 }
        let totalKbits = Double(targetMB) * 1_048_576 * 8 / 1000 / (1 + overhead)
        return Int(totalKbits / duration) - audioKbps
    }

    public static func bytes(videoKbps: Int, audioKbps: Int, duration: Double) -> Int64 {
        Int64(Double(videoKbps + audioKbps) * 1000 / 8 * duration * (1 + overhead))
    }

    public static func extrapolate(sampleBytes: Int64, sampleSeconds: Double, totalSeconds: Double) -> Int64 {
        guard sampleSeconds > 0 else { return 0 }
        return Int64(Double(sampleBytes) * totalSeconds / sampleSeconds)
    }

    /// Size estimate that needs no encoding. Nil for constant-quality modes,
    /// where only a sample encode can tell.
    public static func quickEstimate(info: MediaInfo, selection: Set<Int>, settings: EncodeSettings,
                                     command: EncodeCommand) -> Int64? {
        guard info.duration > 0 else { return nil }
        let videoSelected = info.videoStreams.contains { selection.contains($0.index) }
        if !videoSelected {
            return bytes(videoKbps: 0, audioKbps: command.audioKbps, duration: info.duration)
        }
        if settings.videoEncoder == .copy {
            return bytes(videoKbps: sourceVideoKbps(info: info, selection: selection),
                         audioKbps: command.audioKbps, duration: info.duration)
        }
        if let kbps = command.videoKbps {
            return bytes(videoKbps: kbps, audioKbps: command.audioKbps, duration: info.duration)
        }
        return nil
    }

    /// Bitrate of the selected source video. MKV often hides per-stream rates,
    /// so fall back to "whole file minus the audio we know about".
    static func sourceVideoKbps(info: MediaInfo, selection: Set<Int>) -> Int {
        let selected = info.videoStreams.filter { selection.contains($0.index) }
        let known = selected.compactMap(\.bitRate)
        if known.count == selected.count {
            return known.reduce(0, +) / 1000
        }
        let totalBps = info.bitRate ?? Int(Double(info.fileSize) * 8 / info.duration)
        let audioBps = info.audioStreams.map { $0.bitRate ?? CommandBuilder.unknownAudioKbps * 1000 }.reduce(0, +)
        return max(totalBps - audioBps, 0) / 1000
    }
}

public enum OutputNamer {
    /// Output lives next to the input with the same base name.
    /// `movie.mkv` → MP4 gives `movie.mp4`; → MKV gives `movie_new.mkv`.
    /// If that is taken (on disk or by another queued job), `_new`, `_new2`, `_new3`… are tried.
    public static func outputURL(for input: URL, container: Container, reserved: Set<String> = [],
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let directory = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let ext = container.fileExtension
        func isTaken(_ url: URL) -> Bool { exists(url) || reserved.contains(url.path.lowercased()) }

        if input.pathExtension.lowercased() != ext {
            let plain = directory.appendingPathComponent("\(base).\(ext)")
            if !isTaken(plain) { return plain }
        }
        var n = 1
        while true {
            let suffix = n == 1 ? "_new" : "_new\(n)"
            let candidate = directory.appendingPathComponent("\(base)\(suffix).\(ext)")
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }
}

public struct ProgressUpdate: Equatable, Sendable {
    /// Seconds of output written so far.
    public var outTime: Double?
    /// Encoding speed relative to real time (2.0 = twice as fast as playback).
    public var speed: Double?
    public var finished: Bool
}

/// Parses the key=value blocks written by `ffmpeg -progress pipe:1`.
public struct ProgressParser {
    private var pending = ""
    private var current = ProgressUpdate(outTime: nil, speed: nil, finished: false)

    public init() {}

    public mutating func feed(_ text: String) -> [ProgressUpdate] {
        pending += text
        var updates: [ProgressUpdate] = []
        while let newline = pending.firstIndex(of: "\n") {
            let line = pending[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            switch key {
            // out_time_ms is microseconds too (a long-standing ffmpeg misnomer).
            case "out_time_us", "out_time_ms":
                if let v = Double(value), v >= 0 { current.outTime = v / 1_000_000 }
            case "speed":
                current.speed = Double(value.replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces))
            case "progress":
                current.finished = value == "end"
                updates.append(current)
            default:
                break
            }
        }
        return updates
    }
}

public enum FFmpegCapabilities {
    /// Encoder names from `ffmpeg -encoders`.
    public static func parseEncoders(_ output: String) -> Set<String> {
        var names = Set<String>()
        var inList = false
        for line in output.split(separator: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("------") {
                inList = true
                continue
            }
            guard inList else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 { names.insert(String(parts[1])) }
        }
        return names
    }
}
