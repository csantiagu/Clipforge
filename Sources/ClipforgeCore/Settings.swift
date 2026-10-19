import Foundation

public enum Container: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case mp4, mkv, mov

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
}

public enum VideoEncoder: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case hevcVideoToolbox = "hevc_videotoolbox"
    case h264VideoToolbox = "h264_videotoolbox"
    case x265 = "libx265"
    case x264 = "libx264"
    case copy = "copy"

    public var id: String { rawValue }
    public var ffmpegName: String { rawValue }

    public var displayName: String {
        switch self {
        case .hevcVideoToolbox: return "HEVC (H.265) · Apple hardware · fast"
        case .h264VideoToolbox: return "H.264 · Apple hardware · fast"
        case .x265: return "HEVC (H.265) · x265 · smallest, slow"
        case .x264: return "H.264 · x264 · plays everywhere"
        case .copy: return "Copy video (no re-encode)"
        }
    }

    public var producesHEVC: Bool { self == .x265 || self == .hevcVideoToolbox }
    public var isHardware: Bool { self == .hevcVideoToolbox || self == .h264VideoToolbox }
    /// Software encoders use CRF (lower = better); VideoToolbox uses -q:v (higher = better).
    public var usesCRF: Bool { self == .x264 || self == .x265 }

    public var qualityRange: ClosedRange<Int> {
        switch self {
        case .x264: return 14...32
        case .x265: return 16...34
        case .hevcVideoToolbox, .h264VideoToolbox: return 20...90
        case .copy: return 0...0
        }
    }

    public var defaultQuality: Int {
        switch self {
        case .x264: return 20
        case .x265: return 24
        case .hevcVideoToolbox: return 55
        case .h264VideoToolbox: return 65
        case .copy: return 0
        }
    }

    public var qualityHint: String {
        if usesCRF {
            let crf = self == .x264 ? "18 ≈ visually lossless · 20 high · 23 default · 28 small" : "20 high · 24 good · 28 default · 32 small"
            return "CRF: lower number = better quality and bigger file. \(crf). x265 at a given CRF is roughly 40% smaller than x264."
        }
        return "Higher number = better quality and bigger file. 50–65 is a good range. Constant quality needs an Apple Silicon Mac; on Intel use Average bitrate."
    }
}

public enum RateMode: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case quality, bitrate, targetSize

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .quality: return "Quality"
        case .bitrate: return "Bitrate"
        case .targetSize: return "Target size"
        }
    }
}

public enum SpeedPreset: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow
    public var id: String { rawValue }
}

public enum AudioMode: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case aac, copy
    public var id: String { rawValue }
    public var displayName: String { self == .aac ? "AAC" : "Copy original" }
}

public struct EncodeSettings: Equatable, Hashable, Codable, Sendable {
    public var container: Container = .mp4
    public var videoEncoder: VideoEncoder = .x264
    public var rateMode: RateMode = .quality
    /// CRF for x264/x265, -q:v for VideoToolbox.
    public var quality: Int = 20
    public var videoBitrateKbps: Int = 4000
    public var targetSizeMB: Int = 1000
    public var speed: SpeedPreset = .medium
    /// 0 keeps the source resolution.
    public var maxHeight: Int = 0
    public var audioMode: AudioMode = .aac
    public var audioBitrateKbps: Int = 192
    public var downmixToStereo: Bool = false

    public init() {}
}

public struct Preset: Identifiable, Sendable {
    public let name: String
    public let summary: String
    public let settings: EncodeSettings
    public var id: String { name }

    public static let builtIn: [Preset] = {
        var compatible = EncodeSettings()
        compatible.downmixToStereo = true

        var smallHW = EncodeSettings()
        smallHW.videoEncoder = .hevcVideoToolbox
        smallHW.quality = VideoEncoder.hevcVideoToolbox.defaultQuality
        smallHW.audioBitrateKbps = 160

        var smallSW = EncodeSettings()
        smallSW.videoEncoder = .x265
        smallSW.quality = VideoEncoder.x265.defaultQuality
        smallSW.audioBitrateKbps = 160

        var fixAudio = EncodeSettings()
        fixAudio.container = .mkv
        fixAudio.videoEncoder = .copy

        var remux = EncodeSettings()
        remux.videoEncoder = .copy
        remux.audioMode = .copy

        return [
            Preset(name: "Compatible", summary: "H.264 + stereo AAC in MP4. Plays on phones, TVs, browsers, WhatsApp. Can be bigger than an HEVC source.", settings: compatible),
            Preset(name: "Small · fast", summary: "HEVC on Apple's hardware encoder. Minutes instead of hours. A little larger than x265 at the same quality.", settings: smallHW),
            Preset(name: "Small · best", summary: "HEVC with x265. Best size for the quality, but slow (often slower than real time for 4K).", settings: smallSW),
            Preset(name: "Fix audio only", summary: "Keeps the video untouched and converts audio (DTS/TrueHD) to AAC. Fast, no quality loss to the picture.", settings: fixAudio),
            Preset(name: "Remux", summary: "Changes the container only. Seconds, no quality loss, size barely changes.", settings: remux),
        ]
    }()
}
