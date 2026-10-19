import Foundation

public struct EncodeCommand: Sendable {
    /// Arguments after `ffmpeg`.
    public var arguments: [String]
    public var warnings: [String]
    /// Video bitrate in kbps when it is fixed (bitrate / target-size modes).
    public var videoKbps: Int?
    /// Sum of all output audio tracks in kbps (copied tracks use the source rate when known).
    public var audioKbps: Int

    public var shellString: String {
        (["ffmpeg"] + arguments).map(ShellQuote.quote).joined(separator: " ")
    }
}

/// A slice of the input, used for sample encodes.
public struct Segment: Sendable {
    public var start: Double
    public var duration: Double
    public init(start: Double, duration: Double) {
        self.start = start
        self.duration = duration
    }
}

public enum CommandBuilder {
    static let mp4CopyableAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "opus", "flac"]
    static let mp4TextSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]
    /// Bitrate assumed for copied audio whose rate ffprobe can't see (typical for DTS/TrueHD in MKV).
    static let unknownAudioKbps = 640

    public static func build(info: MediaInfo, selection: Set<Int>, settings: EncodeSettings,
                             input: URL, output: URL, segment: Segment? = nil,
                             overwrite: Bool = false) -> EncodeCommand {
        var warnings: [String] = []
        let container = settings.container
        let isMKV = container == .mkv

        let video = info.videoStreams.filter { selection.contains($0.index) }
        let audio = info.audioStreams.filter { selection.contains($0.index) }
        // Sample encodes skip subtitles: they don't affect size and can stall after a seek.
        var subs = segment == nil ? info.subtitleStreams.filter { selection.contains($0.index) } : []

        if !isMKV {
            let dropped = subs.filter { !mp4TextSubtitles.contains($0.codec) }
            if !dropped.isEmpty {
                warnings.append("\(dropped.count) picture-based subtitle track(s) (PGS/VobSub) can't go into \(container.displayName) and will be left out. Choose MKV to keep them.")
                subs.removeAll { !mp4TextSubtitles.contains($0.codec) }
            }
        }
        if video.isEmpty {
            warnings.append("No video track selected: the output will contain no picture.")
        }

        var args = ["-hide_banner", "-nostdin", overwrite ? "-y" : "-n"]
        if let segment { args += ["-ss", format(segment.start)] }
        args += ["-i", input.path]
        if let segment { args += ["-t", format(segment.duration)] }

        for stream in video + audio + subs {
            args += ["-map", "0:\(stream.index)"]
        }
        // Fonts embedded in MKV are needed to render styled (ASS) subtitles.
        let keepAttachments = isMKV && !subs.isEmpty && info.attachmentCount > 0
        if keepAttachments { args += ["-map", "0:t?"] }
        args += ["-map_metadata", "0", "-map_chapters", "0"]

        // Audio is planned first because target-size mode needs its total bitrate.
        var audioArgs: [String] = []
        var audioKbps = 0
        var raisedSurround = false
        for (i, stream) in audio.enumerated() {
            var copy = settings.audioMode == .copy
            if copy && !isMKV && !mp4CopyableAudio.contains(stream.codec) {
                copy = false
                warnings.append("Audio track \(i + 1) is \(stream.codec), which \(container.displayName) can't hold. It will be converted to AAC.")
            }
            if copy {
                audioArgs += ["-c:a:\(i)", "copy"]
                audioKbps += stream.bitRate.map { $0 / 1000 } ?? unknownAudioKbps
                continue
            }
            let sourceChannels = stream.channels ?? 2
            let downmix = settings.downmixToStereo && sourceChannels > 2
            var kbps = settings.audioBitrateKbps
            if !downmix && sourceChannels > 2 && kbps < 384 {
                kbps = 384
                raisedSurround = true
            }
            audioArgs += ["-c:a:\(i)", "aac", "-b:a:\(i)", "\(kbps)k"]
            if downmix { audioArgs += ["-ac:a:\(i)", "2"] }
            audioKbps += kbps
        }
        if raisedSurround {
            warnings.append("Surround (5.1/7.1) tracks use 384 kbps: \(settings.audioBitrateKbps) kbps spread over 6+ channels sounds poor. Turn on “Downmix to stereo” to keep \(settings.audioBitrateKbps) kbps.")
        }

        var videoKbps: Int?
        let encoder = settings.videoEncoder
        if !video.isEmpty {
            if encoder == .copy {
                args += ["-c:v", "copy"]
                if !isMKV && video.contains(where: { $0.codec == "hevc" }) {
                    args += ["-tag:v", "hvc1"]
                }
                if settings.maxHeight > 0 {
                    warnings.append("Resizing needs re-encoding, so Max resolution has no effect with Copy video.")
                }
            } else {
                args += ["-c:v", encoder.ffmpegName]
                switch settings.rateMode {
                case .quality:
                    args += encoder.usesCRF ? ["-crf", "\(settings.quality)"] : ["-q:v", "\(settings.quality)"]
                case .bitrate:
                    videoKbps = settings.videoBitrateKbps
                case .targetSize:
                    let kbps = SizeEstimator.videoKbps(forTargetMB: settings.targetSizeMB,
                                                       duration: info.duration, audioKbps: audioKbps)
                    if kbps < 300 {
                        warnings.append("\(settings.targetSizeMB) MB is too small for this video: the picture would get \(max(kbps, 0)) kbps and look very blocky.")
                    }
                    videoKbps = max(kbps, 100)
                }
                if let kbps = videoKbps {
                    args += ["-b:v", "\(kbps)k"]
                    if encoder.usesCRF {
                        args += ["-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k"]
                    }
                }
                if encoder.usesCRF { args += ["-preset", settings.speed.rawValue] }
                if encoder == .x265 { args += ["-x265-params", "log-level=error"] }
                // 8-bit 4:2:0 is the only H.264 flavour that all players handle.
                if !encoder.producesHEVC { args += ["-pix_fmt", "yuv420p"] }
                // Without the hvc1 tag, QuickTime and iOS refuse to play HEVC in MP4/MOV.
                if encoder.producesHEVC && !isMKV { args += ["-tag:v", "hvc1"] }
                if settings.maxHeight > 0, let height = video.compactMap(\.height).max(), height > settings.maxHeight {
                    args += ["-vf", "scale=-2:\(settings.maxHeight)"]
                }
                if !encoder.producesHEVC && video.contains(where: \.isHDR) {
                    warnings.append("The source is HDR. H.264 output is SDR, so colours will look washed out. Use an HEVC encoder for HDR sources.")
                }
            }
        }

        args += audioArgs

        for (i, stream) in subs.enumerated() {
            let codec: String
            if isMKV {
                codec = stream.codec == "mov_text" ? "srt" : "copy"
            } else {
                codec = stream.codec == "mov_text" ? "copy" : "mov_text"
            }
            args += ["-c:s:\(i)", codec]
        }
        if keepAttachments { args += ["-c:t", "copy"] }
        if !isMKV { args += ["-movflags", "+faststart"] }
        args.append(output.path)

        return EncodeCommand(arguments: args, warnings: warnings, videoKbps: videoKbps, audioKbps: audioKbps)
    }

    static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}

public enum ShellQuote {
    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=+,%@")

    public static func quote(_ s: String) -> String {
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
