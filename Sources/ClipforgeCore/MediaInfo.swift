import Foundation

public enum StreamKind: String, Sendable {
    case video, audio, subtitle, attachment, data, unknown
}

public struct MediaStream: Identifiable, Hashable, Sendable {
    /// Absolute stream index in the input file (what `-map 0:N` refers to).
    public let index: Int
    public let kind: StreamKind
    public let codec: String
    public let language: String?
    public let title: String?
    public let channels: Int?
    public let width: Int?
    public let height: Int?
    /// Bits per second, if ffprobe or the MKV `BPS` tag reports it.
    public let bitRate: Int?
    public let colorTransfer: String?
    public let isDefault: Bool
    public let isForced: Bool
    /// Cover art stored as a video stream. Never offered as a real video track.
    public let isAttachedPicture: Bool

    public var id: Int { index }

    public init(index: Int, kind: StreamKind, codec: String, language: String? = nil, title: String? = nil,
                channels: Int? = nil, width: Int? = nil, height: Int? = nil, bitRate: Int? = nil,
                colorTransfer: String? = nil, isDefault: Bool = false, isForced: Bool = false,
                isAttachedPicture: Bool = false) {
        self.index = index
        self.kind = kind
        self.codec = codec
        self.language = language
        self.title = title
        self.channels = channels
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.colorTransfer = colorTransfer
        self.isDefault = isDefault
        self.isForced = isForced
        self.isAttachedPicture = isAttachedPicture
    }

    /// Bitmap subtitles (Blu-ray PGS, DVD VobSub). MP4/MOV cannot store these.
    public static let imageSubtitleCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]

    public var isImageSubtitle: Bool { kind == .subtitle && Self.imageSubtitleCodecs.contains(codec) }

    public var isHDR: Bool { colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67" }

    public var label: String {
        var parts: [String] = [codec]
        switch kind {
        case .video:
            if let w = width, let h = height { parts.append("\(w)×\(h)") }
            if isHDR { parts.append("HDR") }
        case .audio:
            if let c = channels { parts.append(Self.channelName(c)) }
        default:
            break
        }
        if let rate = bitRate { parts.append("\(rate / 1000) kbps") }
        if let language { parts.append(language) }
        if let title, !title.isEmpty { parts.append("“\(title)”") }
        if isDefault { parts.append("default") }
        if isForced { parts.append("forced") }
        return parts.joined(separator: " · ")
    }

    public static func channelName(_ count: Int) -> String {
        switch count {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count)ch"
        }
    }
}

public struct MediaInfo: Sendable {
    public let duration: Double
    public let fileSize: Int64
    public let bitRate: Int?
    public let formatName: String
    public let streams: [MediaStream]

    public init(duration: Double, fileSize: Int64, bitRate: Int?, formatName: String, streams: [MediaStream]) {
        self.duration = duration
        self.fileSize = fileSize
        self.bitRate = bitRate
        self.formatName = formatName
        self.streams = streams
    }

    public var videoStreams: [MediaStream] { streams.filter { $0.kind == .video && !$0.isAttachedPicture } }
    public var audioStreams: [MediaStream] { streams.filter { $0.kind == .audio } }
    public var subtitleStreams: [MediaStream] { streams.filter { $0.kind == .subtitle } }
    public var attachmentCount: Int { streams.filter { $0.kind == .attachment }.count }

    /// Everything that can be selected: all video, audio and subtitle tracks.
    public var defaultSelection: Set<Int> {
        Set((videoStreams + audioStreams + subtitleStreams).map(\.index))
    }

    /// Distinct languages of a track kind, in file order. Untagged tracks report "und".
    public func languages(of kind: StreamKind) -> [String] {
        var seen: [String] = []
        for s in streams where s.kind == kind {
            let lang = s.language ?? "und"
            if !seen.contains(lang) { seen.append(lang) }
        }
        return seen
    }

    // MARK: - ffprobe JSON

    private struct ProbeOutput: Decodable {
        struct Stream: Decodable {
            let index: Int
            let codec_type: String?
            let codec_name: String?
            let channels: Int?
            let width: Int?
            let height: Int?
            let bit_rate: String?
            let color_transfer: String?
            let tags: [String: String]?
            let disposition: [String: Int]?
        }
        struct Format: Decodable {
            let duration: String?
            let size: String?
            let bit_rate: String?
            let format_name: String?
        }
        let streams: [Stream]?
        let format: Format?
    }

    /// Parses `ffprobe -print_format json -show_format -show_streams` output.
    public static func parse(ffprobeJSON data: Data) throws -> MediaInfo {
        let probe = try JSONDecoder().decode(ProbeOutput.self, from: data)
        let streams: [MediaStream] = (probe.streams ?? []).map { s in
            // Tag keys vary in case between containers (language / LANGUAGE).
            var tags: [String: String] = [:]
            for (k, v) in s.tags ?? [:] { tags[k.lowercased()] = v }
            let bitRate = s.bit_rate.flatMap { Int($0) }
                ?? tags["bps"].flatMap { Int($0) }
                ?? tags["bps-eng"].flatMap { Int($0) }
            let kind = StreamKind(rawValue: s.codec_type ?? "") ?? .unknown
            return MediaStream(
                index: s.index,
                kind: kind,
                codec: s.codec_name ?? "unknown",
                language: tags["language"],
                title: tags["title"],
                channels: s.channels,
                width: s.width,
                height: s.height,
                bitRate: kind == .subtitle ? nil : bitRate,
                colorTransfer: s.color_transfer,
                isDefault: (s.disposition?["default"] ?? 0) == 1,
                isForced: (s.disposition?["forced"] ?? 0) == 1,
                isAttachedPicture: (s.disposition?["attached_pic"] ?? 0) == 1
            )
        }
        return MediaInfo(
            duration: probe.format?.duration.flatMap { Double($0) } ?? 0,
            fileSize: probe.format?.size.flatMap { Int64($0) } ?? 0,
            bitRate: probe.format?.bit_rate.flatMap { Int($0) },
            formatName: probe.format?.format_name ?? "",
            streams: streams
        )
    }
}

public enum Probe {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func run(ffprobe: URL, file: URL) async throws -> MediaInfo {
        let result = try await RunningProcess.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.path,
        ])
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "ffprobe could not read this file" : message)
        }
        return try MediaInfo.parse(ffprobeJSON: result.stdout)
    }
}
