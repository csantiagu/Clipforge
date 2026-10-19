import XCTest
@testable import ClipforgeCore

/// Behaviour that is easy to break and doesn't need ffmpeg to check.
final class EdgeCaseTests: XCTestCase {
    let input = URL(fileURLWithPath: "/m/in.mkv")
    let mp4 = URL(fileURLWithPath: "/m/out.mp4")

    private func movie(_ streams: [MediaStream], duration: Double = 600) -> MediaInfo {
        MediaInfo(duration: duration, fileSize: 1_000_000_000, bitRate: 8_000_000, formatName: "matroska", streams: streams)
    }

    private let h264 = MediaStream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080)
    private let stereo = MediaStream(index: 1, kind: .audio, codec: "aac", language: "eng", channels: 2)

    // MARK: Command building

    func testStereoSourceIsNeverDownmixed() {
        var s = EncodeSettings()
        s.downmixToStereo = true
        let cmd = CommandBuilder.build(info: movie([h264, stereo]), selection: [0, 1], settings: s, input: input, output: mp4)
        XCTAssertFalse(cmd.arguments.contains("-ac:a:0"))
    }

    func testNoUpscaling() {
        var s = EncodeSettings()
        s.maxHeight = 2160
        let cmd = CommandBuilder.build(info: movie([h264]), selection: [0], settings: s, input: input, output: mp4)
        XCTAssertFalse(cmd.arguments.contains("-vf"))
    }

    func testResizeWithCopyWarns() {
        var s = EncodeSettings()
        s.videoEncoder = .copy
        s.maxHeight = 720
        let cmd = CommandBuilder.build(info: movie([h264]), selection: [0], settings: s, input: input, output: mp4)
        XCTAssertFalse(cmd.arguments.contains("-vf"))
        XCTAssertTrue(cmd.warnings.contains { $0.contains("Max resolution") })
    }

    func testHDRToH264Warns() {
        let hdr = MediaStream(index: 0, kind: .video, codec: "hevc", height: 2160, colorTransfer: "smpte2084")
        let x264 = CommandBuilder.build(info: movie([hdr]), selection: [0], settings: EncodeSettings(), input: input, output: mp4)
        XCTAssertTrue(x264.warnings.contains { $0.contains("HDR") })

        var s = EncodeSettings()
        s.videoEncoder = .x265
        let x265 = CommandBuilder.build(info: movie([hdr]), selection: [0], settings: s, input: input, output: mp4)
        XCTAssertFalse(x265.warnings.contains { $0.contains("HDR") })
    }

    func testTinyTargetSizeWarnsAndKeepsAFloor() {
        var s = EncodeSettings()
        s.rateMode = .targetSize
        s.targetSizeMB = 10   // 10 MB for a 10-minute film
        let cmd = CommandBuilder.build(info: movie([h264, stereo]), selection: [0, 1], settings: s, input: input, output: mp4)
        XCTAssertTrue(cmd.warnings.contains { $0.contains("too small") })
        XCTAssertEqual(cmd.videoKbps, 100)
    }

    func testMaxrateOnlyForSoftwareEncoders() {
        var s = EncodeSettings()
        s.rateMode = .bitrate
        s.videoBitrateKbps = 3000
        let software = CommandBuilder.build(info: movie([h264]), selection: [0], settings: s, input: input, output: mp4)
        XCTAssertTrue(software.arguments.contains("-maxrate"))

        s.videoEncoder = .h264VideoToolbox
        let hardware = CommandBuilder.build(info: movie([h264]), selection: [0], settings: s, input: input, output: mp4)
        XCTAssertFalse(hardware.arguments.contains("-maxrate"))
        XCTAssertTrue(hardware.arguments.contains("3000k"))
    }

    func testMovTextBecomesSRTInMKV() {
        let movText = MediaStream(index: 1, kind: .subtitle, codec: "mov_text")
        var s = EncodeSettings()
        s.container = .mkv
        let cmd = CommandBuilder.build(info: movie([h264, movText]), selection: [0, 1], settings: s, input: input,
                                       output: URL(fileURLWithPath: "/m/out.mkv"))
        XCTAssertTrue(cmd.shellString.contains("-c:s:0 srt"))
        XCTAssertFalse(cmd.arguments.contains("-movflags"))
    }

    func testAudioOnlySelectionWarns() {
        let cmd = CommandBuilder.build(info: movie([h264, stereo]), selection: [1], settings: EncodeSettings(),
                                       input: input, output: mp4)
        XCTAssertFalse(cmd.arguments.contains("-c:v"))
        XCTAssertTrue(cmd.warnings.contains { $0.contains("No video") })
    }

    func testCoverArtIsNeverATrack() {
        let cover = MediaStream(index: 2, kind: .video, codec: "mjpeg", isAttachedPicture: true)
        let info = movie([h264, stereo, cover])
        XCTAssertEqual(info.videoStreams.map(\.index), [0])
        XCTAssertFalse(info.defaultSelection.contains(2))
    }

    func testPathsWithQuotesSurviveShellQuoting() {
        let odd = URL(fileURLWithPath: "/m/Don't Look Up (2021).mkv")
        let cmd = CommandBuilder.build(info: movie([h264]), selection: [0], settings: EncodeSettings(), input: odd, output: mp4)
        XCTAssertTrue(cmd.shellString.contains("'/m/Don'\\''t Look Up (2021).mkv'"))
        XCTAssertTrue(cmd.arguments.contains(odd.path), "arguments are passed unquoted, straight to ffmpeg")
    }

    // MARK: Presets

    func testPresetsAreSane() {
        XCTAssertEqual(Set(Preset.builtIn.map(\.name)).count, Preset.builtIn.count, "names are unique")
        for preset in Preset.builtIn where preset.settings.videoEncoder != .copy {
            XCTAssertTrue(preset.settings.videoEncoder.qualityRange.contains(preset.settings.quality),
                          "\(preset.name) quality is in range")
        }
    }

    // MARK: Estimates

    func testQualityModeHasNoQuickEstimate() {
        let info = movie([h264, stereo])
        let cmd = CommandBuilder.build(info: info, selection: [0, 1], settings: EncodeSettings(), input: input, output: mp4)
        XCTAssertNil(SizeEstimator.quickEstimate(info: info, selection: [0, 1], settings: EncodeSettings(), command: cmd))
    }

    func testCopyEstimateFallsBackToFileBitrate() {
        // 8 Mbps file, audio rate unknown → assumed 640 kbps → video ≈ 7,360 kbps.
        XCTAssertEqual(SizeEstimator.sourceVideoKbps(info: movie([h264, stereo]), selection: [0]), 7360)
    }

    func testEstimateMathEdges() {
        XCTAssertEqual(SizeEstimator.videoKbps(forTargetMB: 100, duration: 0, audioKbps: 128), 0)
        XCTAssertEqual(SizeEstimator.extrapolate(sampleBytes: 1_000, sampleSeconds: 20, totalSeconds: 600), 30_000)
        XCTAssertEqual(SizeEstimator.extrapolate(sampleBytes: 1_000, sampleSeconds: 0, totalSeconds: 600), 0)
    }

    // MARK: Output names

    func testManyExistingNames() {
        let taken: Set<String> = ["/m/x.mp4", "/m/x_new.mp4", "/m/x_new2.mp4", "/m/x_new3.mp4"]
        let url = OutputNamer.outputURL(for: URL(fileURLWithPath: "/m/x.mp4"), container: .mp4,
                                        exists: { taken.contains($0.path) })
        XCTAssertEqual(url.lastPathComponent, "x_new4.mp4")
    }

    func testReservedNamesAreCaseInsensitive() {
        let url = OutputNamer.outputURL(for: URL(fileURLWithPath: "/m/Clip.MKV"), container: .mp4,
                                        reserved: ["/m/clip.mp4"], exists: { _ in false })
        XCTAssertEqual(url.lastPathComponent, "Clip_new.mp4")
    }

    func testOtherFolderKeepsPlainName() {
        let out = URL(fileURLWithPath: "/Volumes/Backup/Converted")
        func name(_ path: String, _ c: Container, taken: Set<String> = [], reserved: Set<String> = []) -> String {
            OutputNamer.outputURL(for: URL(fileURLWithPath: path), container: c, directory: out,
                                  reserved: reserved, exists: { taken.contains($0.path) }).path
        }
        // Same format, other folder: no clash with the original, so no _new.
        XCTAssertEqual(name("/m/movie.mkv", .mkv), "/Volumes/Backup/Converted/movie.mkv")
        XCTAssertEqual(name("/m/movie.mkv", .mp4), "/Volumes/Backup/Converted/movie.mp4")
        // Taken there already → _new.
        XCTAssertEqual(name("/m/movie.mkv", .mkv, taken: ["/Volumes/Backup/Converted/movie.mkv"]),
                       "/Volumes/Backup/Converted/movie_new.mkv")
        // Two queued videos with the same name from different folders.
        XCTAssertEqual(name("/b/movie.mkv", .mp4, reserved: ["/volumes/backup/converted/movie.mp4"]),
                       "/Volumes/Backup/Converted/movie_new.mp4")
    }

    func testChoosingTheSourceFolderBehavesLikeNextToOriginal() {
        let url = OutputNamer.outputURL(for: URL(fileURLWithPath: "/m/movie.mkv"), container: .mkv,
                                        directory: URL(fileURLWithPath: "/m/"), exists: { _ in false })
        XCTAssertEqual(url.path, "/m/movie_new.mkv")
    }

    // MARK: Progress

    func testProgressSplitAcrossChunks() {
        var parser = ProgressParser()
        XCTAssertTrue(parser.feed("out_time_us=1500").isEmpty)
        XCTAssertTrue(parser.feed("000\nspeed=2.5x\nprog").isEmpty)
        let updates = parser.feed("ress=continue\n")
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].outTime!, 1.5, accuracy: 0.0001)
        XCTAssertEqual(updates[0].speed!, 2.5, accuracy: 0.0001)
        XCTAssertFalse(updates[0].finished)
    }

    // MARK: Labels

    func testTrackLabel() {
        let surround = MediaStream(index: 3, kind: .audio, codec: "eac3", language: "eng", title: "Atmos",
                                   channels: 8, bitRate: 768_000, isDefault: true)
        XCTAssertEqual(surround.label, "eac3 · 7.1 · 768 kbps · eng · “Atmos” · default")
        XCTAssertEqual(movie([stereo, MediaStream(index: 2, kind: .audio, codec: "aac")]).languages(of: .audio),
                       ["eng", "und"])
    }
}
