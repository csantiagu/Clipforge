import XCTest
@testable import ClipforgeCore

/// Real `ffprobe -show_format -show_streams` output (trimmed to the fields we read) for a 30 s MKV:
/// 0 HEVC 1080p · 1,2,3 mono AC3 (eng, jpn, fre) · 4 SRT eng · 5 ASS fre · 6 AC3 5.1 eng · 7 font attachment.
let fixtureJSON = #"""
{
 "streams": [
  {
   "index": 0,
   "codec_name": "hevc",
   "codec_type": "video",
   "width": 1920,
   "height": 1080,
   "disposition": {
    "default": 0,
    "forced": 0,
    "attached_pic": 0
   },
   "tags": {}
  },
  {
   "index": 1,
   "codec_name": "ac3",
   "codec_type": "audio",
   "channels": 1,
   "bit_rate": "96000",
   "disposition": {
    "default": 1,
    "forced": 0,
    "attached_pic": 0
   },
   "tags": {
    "language": "eng"
   }
  },
  {
   "index": 2,
   "codec_name": "ac3",
   "codec_type": "audio",
   "channels": 1,
   "bit_rate": "96000",
   "disposition": {
    "default": 0,
    "forced": 0,
    "attached_pic": 0
   },
   "tags": {
    "language": "jpn"
   }
  },
  {
   "index": 3,
   "codec_name": "ac3",
   "codec_type": "audio",
   "channels": 1,
   "bit_rate": "96000",
   "disposition": {
    "default": 0,
    "forced": 0,
    "attached_pic": 0
   },
   "tags": {
    "language": "fre"
   }
  },
  {
   "index": 4,
   "codec_name": "subrip",
   "codec_type": "subtitle",
   "disposition": {
    "default": 1,
    "forced": 0,
    "attached_pic": 0
   },
   "tags": {
    "language": "eng"
   }
  },
  {
   "index": 5,
   "codec_name": "ass",
   "codec_type": "subtitle",
   "disposition": {
    "default": 0,
    "forced": 0,
    "attached_pic": 0
   },
   "tags": {
    "language": "fre"
   }
  },
  {
   "index": 6,
   "codec_name": "ac3",
   "codec_type": "audio",
   "channels": 6,
   "bit_rate": "448000",
   "disposition": {
    "default": 0,
    "forced": 0,
    "attached_pic": 0
   },
   "tags": {
    "language": "eng",
    "title": "Surround"
   }
  },
  {
   "index": 7,
   "codec_name": "ttf",
   "codec_type": "attachment",
   "disposition": {
    "default": 0,
    "forced": 0,
    "attached_pic": 0
   },
   "tags": {
    "filename": "InterDisplay-MediumItalic.otf",
    "mimetype": "application/x-truetype-font"
   }
  }
 ],
 "format": {
  "duration": "30.000000",
  "size": "15537356",
  "bit_rate": "4143294",
  "format_name": "matroska,webm"
 }
}
"""#

final class ClipforgeCoreTests: XCTestCase {
    let input = URL(fileURLWithPath: "/movies/Test Movie (2026).mkv")
    var info: MediaInfo!

    override func setUpWithError() throws {
        info = try MediaInfo.parse(ffprobeJSON: Data(fixtureJSON.utf8))
    }

    // MARK: Probe parsing

    func testParsesStreams() {
        XCTAssertEqual(info.duration, 30, accuracy: 0.01)
        XCTAssertEqual(info.fileSize, 15_537_356)
        XCTAssertEqual(info.videoStreams.map(\.index), [0])
        XCTAssertEqual(info.audioStreams.map(\.index), [1, 2, 3, 6])
        XCTAssertEqual(info.subtitleStreams.map(\.codec), ["subrip", "ass"])
        XCTAssertEqual(info.attachmentCount, 1)
        XCTAssertEqual(info.audioStreams.last?.channels, 6)
        XCTAssertEqual(info.audioStreams.last?.title, "Surround")
        XCTAssertEqual(info.languages(of: .audio), ["eng", "jpn", "fre"])
        XCTAssertEqual(info.defaultSelection, [0, 1, 2, 3, 4, 5, 6])
    }

    func testMKVBpsTagIsUsedAsBitrate() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"audio","codec_name":"dts","tags":{"BPS-eng":"1509000"}}],"format":{"duration":"10"}}"#
        let parsed = try MediaInfo.parse(ffprobeJSON: Data(json.utf8))
        XCTAssertEqual(parsed.streams[0].bitRate, 1_509_000)
    }

    // MARK: Commands (each expected list was run through ffmpeg 6.1 successfully)

    func testCompatiblePresetToMP4() {
        let out = URL(fileURLWithPath: "/movies/Test Movie (2026).mp4")
        let cmd = CommandBuilder.build(info: info, selection: info.defaultSelection,
                                       settings: Preset.builtIn[0].settings, input: input, output: out)
        XCTAssertEqual(cmd.arguments, [
            "-hide_banner", "-nostdin", "-n", "-i", input.path,
            "-map", "0:0", "-map", "0:1", "-map", "0:2", "-map", "0:3", "-map", "0:6", "-map", "0:4", "-map", "0:5",
            "-map_metadata", "0", "-map_chapters", "0",
            "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p",
            "-c:a:0", "aac", "-b:a:0", "192k", "-c:a:1", "aac", "-b:a:1", "192k",
            "-c:a:2", "aac", "-b:a:2", "192k", "-c:a:3", "aac", "-b:a:3", "192k", "-ac:a:3", "2",
            "-c:s:0", "mov_text", "-c:s:1", "mov_text",
            "-movflags", "+faststart", out.path,
        ])
        XCTAssertTrue(cmd.warnings.isEmpty, "\(cmd.warnings)")
    }

    func testX265ScaledWithSurroundBump() {
        var s = Preset.builtIn[2].settings
        s.maxHeight = 720
        let out = URL(fileURLWithPath: "/movies/Test Movie (2026).mp4")
        let cmd = CommandBuilder.build(info: info, selection: [0, 6, 4], settings: s, input: input, output: out)
        XCTAssertEqual(cmd.arguments, [
            "-hide_banner", "-nostdin", "-n", "-i", input.path,
            "-map", "0:0", "-map", "0:6", "-map", "0:4", "-map_metadata", "0", "-map_chapters", "0",
            "-c:v", "libx265", "-crf", "24", "-preset", "medium", "-x265-params", "log-level=error",
            "-tag:v", "hvc1", "-vf", "scale=-2:720",
            "-c:a:0", "aac", "-b:a:0", "384k", "-c:s:0", "mov_text",
            "-movflags", "+faststart", out.path,
        ])
        XCTAssertEqual(cmd.warnings.count, 1)
    }

    func testFixAudioKeepsSubsAndFontsInMKV() {
        let out = URL(fileURLWithPath: "/movies/Test Movie (2026)_new.mkv")
        let cmd = CommandBuilder.build(info: info, selection: info.defaultSelection,
                                       settings: Preset.builtIn[3].settings, input: input, output: out)
        XCTAssertEqual(cmd.arguments, [
            "-hide_banner", "-nostdin", "-n", "-i", input.path,
            "-map", "0:0", "-map", "0:1", "-map", "0:2", "-map", "0:3", "-map", "0:6", "-map", "0:4", "-map", "0:5",
            "-map", "0:t?", "-map_metadata", "0", "-map_chapters", "0",
            "-c:v", "copy",
            "-c:a:0", "aac", "-b:a:0", "192k", "-c:a:1", "aac", "-b:a:1", "192k",
            "-c:a:2", "aac", "-b:a:2", "192k", "-c:a:3", "aac", "-b:a:3", "384k",
            "-c:s:0", "copy", "-c:s:1", "copy", "-c:t", "copy", out.path,
        ])
    }

    func testTargetSize() {
        var s = EncodeSettings()
        s.rateMode = .targetSize
        s.targetSizeMB = 5
        let out = URL(fileURLWithPath: "/movies/x.mp4")
        let cmd = CommandBuilder.build(info: info, selection: [0, 1], settings: s, input: input, output: out)
        XCTAssertEqual(cmd.videoKbps, 1192)
        XCTAssertTrue(cmd.arguments.contains("1192k"))
        XCTAssertTrue(cmd.arguments.contains("1788k"))
        // ffmpeg produced 4,979,267 bytes for a 5,242,880 byte target.
        let estimate = SizeEstimator.quickEstimate(info: info, selection: [0, 1], settings: s, command: cmd)!
        XCTAssertEqual(Double(estimate), 5_242_880, accuracy: 5_242_880 * 0.03)
    }

    func testRemuxHEVCGetsHvc1Tag() {
        let out = URL(fileURLWithPath: "/movies/x.mp4")
        let cmd = CommandBuilder.build(info: info, selection: [0, 1, 6, 4, 5],
                                       settings: Preset.builtIn[4].settings, input: input, output: out)
        XCTAssertEqual(Array(cmd.arguments[cmd.arguments.firstIndex(of: "-c:v")!...]), [
            "-c:v", "copy", "-tag:v", "hvc1", "-c:a:0", "copy", "-c:a:1", "copy",
            "-c:s:0", "mov_text", "-c:s:1", "mov_text", "-movflags", "+faststart", out.path,
        ])
    }

    func testPictureSubtitlesDroppedForMP4ButKeptForMKV() {
        let pgs = MediaInfo(duration: 60, fileSize: 1, bitRate: nil, formatName: "matroska", streams: [
            MediaStream(index: 0, kind: .video, codec: "h264", height: 1080),
            MediaStream(index: 1, kind: .subtitle, codec: "hdmv_pgs_subtitle"),
            MediaStream(index: 2, kind: .subtitle, codec: "subrip"),
        ])
        var s = EncodeSettings()
        let mp4 = CommandBuilder.build(info: pgs, selection: [0, 1, 2], settings: s, input: input,
                                       output: URL(fileURLWithPath: "/o.mp4"))
        XCTAssertFalse(mp4.arguments.contains("0:1"))
        XCTAssertTrue(mp4.arguments.contains("0:2"))
        XCTAssertEqual(mp4.warnings.count, 1)

        s.container = .mkv
        let mkv = CommandBuilder.build(info: pgs, selection: [0, 1, 2], settings: s, input: input,
                                       output: URL(fileURLWithPath: "/o.mkv"))
        XCTAssertTrue(mkv.arguments.contains("0:1"))
        XCTAssertTrue(mkv.warnings.isEmpty)
    }

    func testDTSCopyIntoMP4FallsBackToAAC() {
        let dts = MediaInfo(duration: 60, fileSize: 1, bitRate: nil, formatName: "matroska", streams: [
            MediaStream(index: 0, kind: .audio, codec: "dts", channels: 6),
        ])
        var s = EncodeSettings()
        s.audioMode = .copy
        let cmd = CommandBuilder.build(info: dts, selection: [0], settings: s, input: input,
                                       output: URL(fileURLWithPath: "/o.mp4"))
        XCTAssertTrue(cmd.arguments.contains("aac"))
        XCTAssertFalse(cmd.arguments.contains("copy"))
    }

    func testSampleSegment() {
        let cmd = CommandBuilder.build(info: info, selection: info.defaultSelection, settings: EncodeSettings(),
                                       input: input, output: URL(fileURLWithPath: "/tmp/s.mp4"),
                                       segment: Segment(start: 12, duration: 20), overwrite: true)
        XCTAssertEqual(Array(cmd.arguments.prefix(9)),
                       ["-hide_banner", "-nostdin", "-y", "-ss", "12.000", "-i", input.path, "-t", "20.000"])
        XCTAssertFalse(cmd.arguments.contains("-c:s:0"), "samples skip subtitles")
    }

    func testVideoToolboxUsesQv() {
        var s = EncodeSettings()
        s.videoEncoder = .hevcVideoToolbox
        s.quality = 55
        let cmd = CommandBuilder.build(info: info, selection: [0], settings: s, input: input,
                                       output: URL(fileURLWithPath: "/o.mov"))
        XCTAssertTrue(cmd.shellString.contains("-c:v hevc_videotoolbox -q:v 55 -tag:v hvc1"), cmd.shellString)
        XCTAssertFalse(cmd.arguments.contains("-preset"))
    }

    // MARK: Output names

    func testOutputNames() {
        let files: Set<String> = ["/v/a.mkv", "/v/a_new.mkv", "/v/b.mp4"]
        let exists: (URL) -> Bool = { files.contains($0.path) }
        func name(_ path: String, _ c: Container, reserved: Set<String> = []) -> String {
            OutputNamer.outputURL(for: URL(fileURLWithPath: path), container: c, reserved: reserved, exists: exists).lastPathComponent
        }
        XCTAssertEqual(name("/v/a.mkv", .mp4), "a.mp4")            // different type: same name
        XCTAssertEqual(name("/v/a.mkv", .mkv), "a_new2.mkv")       // same type, a_new taken
        XCTAssertEqual(name("/v/b.mp4", .mp4), "b_new.mp4")        // same type
        XCTAssertEqual(name("/v/B.MP4", .mp4), "B_new.mp4")        // extension case ignored
        XCTAssertEqual(name("/v/b.mkv", .mp4), "b_new.mp4")        // b.mp4 already exists
        XCTAssertEqual(name("/v/c.avi", .mp4, reserved: ["/v/c.mp4"]), "c_new.mp4") // another job has it
    }

    // MARK: Progress

    func testProgressParser() {
        var parser = ProgressParser()
        XCTAssertTrue(parser.feed("frame=1\nout_time_us=N/A\nspeed=N/A\nprogress=continue\nframe=").count == 1)
        let updates = parser.feed("720\nout_time_us=30000363\nout_time_ms=30000363\nspeed= 1.4x\nprogress=end\n")
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].outTime!, 30.000363, accuracy: 0.0001)
        XCTAssertEqual(updates[0].speed!, 1.4, accuracy: 0.001)
        XCTAssertTrue(updates[0].finished)
    }

    func testEncoderListParsing() {
        let output = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264 / AVC
         V....D hevc_videotoolbox    VideoToolbox H.265 Encoder
         A....D aac                  AAC (Advanced Audio Coding)
        """
        XCTAssertEqual(FFmpegCapabilities.parseEncoders(output), ["libx264", "hevc_videotoolbox", "aac"])
    }

    func testShellQuote() {
        XCTAssertEqual(ShellQuote.quote("-c:v"), "-c:v")
        XCTAssertEqual(ShellQuote.quote("/m/Test Movie (2026).mkv"), "'/m/Test Movie (2026).mkv'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
    }
}
