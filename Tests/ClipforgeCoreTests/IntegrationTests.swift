import XCTest
@testable import ClipforgeCore

/// Encodes real clips with ffmpeg, so these prove that ffmpeg accepts the commands we build.
/// Skipped when ffmpeg isn't installed (`brew install ffmpeg`).
///
/// The source clip is made on the fly: 4 s of 320×240 HEVC, a 5.1 AC3 track (eng),
/// a stereo AAC track (jpn) and an SRT subtitle (eng), with spaces and brackets in the name.
final class IntegrationTests: XCTestCase {
    private var ffmpeg: URL!
    private var ffprobe: URL!
    private var directory: URL!
    private var source: URL!
    private var encoders: Set<String> = []

    struct FFmpegFailure: Error, CustomStringConvertible {
        let description: String
    }

    override func setUp() async throws {
        guard let ffmpeg = FFmpegLocator.find("ffmpeg"), let ffprobe = FFmpegLocator.find("ffprobe") else {
            throw XCTSkip("ffmpeg/ffprobe not installed")
        }
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipforge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let list = try await RunningProcess.run(ffmpeg, ["-hide_banner", "-encoders"])
        encoders = FFmpegCapabilities.parseEncoders(String(decoding: list.stdout, as: UTF8.self))
        source = try await makeSource()
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Probe

    func testProbeReadsTracks() async throws {
        let info = try await Probe.run(ffprobe: ffprobe, file: source)
        XCTAssertEqual(info.duration, 4, accuracy: 0.2)
        XCTAssertEqual(info.videoStreams.map(\.codec), ["hevc"])
        XCTAssertEqual(info.videoStreams.first?.height, 240)
        XCTAssertEqual(info.audioStreams.map(\.channels), [6, 2])
        XCTAssertEqual(info.languages(of: .audio), ["eng", "jpn"])
        XCTAssertEqual(info.subtitleStreams.map(\.codec), ["subrip"])
    }

    func testProbeRejectsNonVideo() async throws {
        let text = directory.appendingPathComponent("notes.mkv")
        try "not a video".write(to: text, atomically: true, encoding: .utf8)
        do {
            _ = try await Probe.run(ffprobe: ffprobe, file: text)
            XCTFail("expected ffprobe to fail")
        } catch is Probe.Failure {
            // expected
        }
    }

    // MARK: - Presets

    func testCompatiblePreset() async throws {
        let (output, info) = try await encode(preset: "Compatible")
        XCTAssertEqual(output.lastPathComponent, "My Clip (2026).mp4")
        XCTAssertEqual(info.videoStreams.map(\.codec), ["h264"])
        XCTAssertEqual(info.audioStreams.map(\.codec), ["aac", "aac"])
        XCTAssertEqual(info.audioStreams.map(\.channels), [2, 2], "5.1 is downmixed to stereo")
        XCTAssertEqual(info.subtitleStreams.map(\.codec), ["mov_text"])
        XCTAssertEqual(info.languages(of: .audio), ["eng", "jpn"], "language tags survive")
    }

    func testSmallBestPreset() async throws {
        try requireEncoder("libx265")
        let (_, info) = try await encode(preset: "Small · best")
        XCTAssertEqual(info.videoStreams.map(\.codec), ["hevc"])
        XCTAssertEqual(info.audioStreams.map(\.channels), [6, 2], "surround is kept")
    }

    func testSmallFastPresetOnHardware() async throws {
        try requireEncoder("hevc_videotoolbox")
        do {
            let (_, info) = try await encode(preset: "Small · fast")
            XCTAssertEqual(info.videoStreams.map(\.codec), ["hevc"])
        } catch let failure as FFmpegFailure {
            // Virtual Macs (CI) often have no hardware encoder even though ffmpeg lists it.
            throw XCTSkip("VideoToolbox not usable here: \(failure)")
        }
    }

    func testFixAudioPresetKeepsVideoAndSubs() async throws {
        let (output, info) = try await encode(preset: "Fix audio only")
        XCTAssertEqual(output.lastPathComponent, "My Clip (2026)_new.mkv", "same format gets _new")
        XCTAssertEqual(info.videoStreams.map(\.codec), ["hevc"], "video is copied")
        XCTAssertEqual(info.audioStreams.map(\.codec), ["aac", "aac"])
        XCTAssertEqual(info.subtitleStreams.map(\.codec), ["subrip"])
    }

    func testRemuxPreset() async throws {
        let (_, info) = try await encode(preset: "Remux")
        XCTAssertEqual(info.videoStreams.map(\.codec), ["hevc"])
        XCTAssertEqual(info.audioStreams.map(\.codec), ["ac3", "aac"], "audio is copied")
    }

    func testTrackSelectionAndScaling() async throws {
        var settings = EncodeSettings()
        settings.maxHeight = 120
        let (_, info) = try await encode(settings: settings, selection: [0, 2])
        XCTAssertEqual(info.audioStreams.count, 1)
        XCTAssertEqual(info.languages(of: .audio), ["jpn"])
        XCTAssertTrue(info.subtitleStreams.isEmpty)
        XCTAssertEqual(info.videoStreams.first?.height, 120)
        XCTAssertEqual(info.videoStreams.first?.width, 160)
    }

    func testEncodeIntoAnotherFolder() async throws {
        let folder = directory.appendingPathComponent("Out Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preset = try XCTUnwrap(Preset.builtIn.first { $0.name == "Remux" })
        let (output, info) = try await encode(settings: preset.settings, directory: folder)
        XCTAssertEqual(output.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(output.lastPathComponent, "My Clip (2026).mp4")
        XCTAssertEqual(info.videoStreams.count, 1)
    }

    func testTargetSizeLandsNearTarget() async throws {
        var settings = EncodeSettings()
        settings.rateMode = .targetSize
        settings.targetSizeMB = 1
        let (output, _) = try await encode(settings: settings)
        let size = Double(fileSize(output))
        // Measured with ffmpeg 6.1: 952,774 bytes for a 1,048,576 byte target (−9%).
        // Very short clips undershoot, so allow ±20%.
        XCTAssertEqual(size, 1_048_576, accuracy: 1_048_576 * 0.2)
    }

    // MARK: - Process handling

    func testProgressReportsCompletion() async throws {
        let info = try await Probe.run(ffprobe: ffprobe, file: source)
        let output = directory.appendingPathComponent("progress.mp4")
        let command = CommandBuilder.build(info: info, selection: info.defaultSelection, settings: EncodeSettings(),
                                           input: source, output: output)
        final class Collector: @unchecked Sendable {
            var parser = ProgressParser()
            var updates: [ProgressUpdate] = []
            let lock = NSLock()
        }
        let collector = Collector()
        let process = RunningProcess(executable: ffmpeg,
                                     arguments: ["-progress", "pipe:1", "-nostats", "-loglevel", "error"] + command.arguments)
        let result = try await process.run(onStdout: { data in
            collector.lock.lock()
            collector.updates += collector.parser.feed(String(decoding: data, as: UTF8.self))
            collector.lock.unlock()
        })
        XCTAssertEqual(result.status, 0)
        let last = try XCTUnwrap(collector.updates.last)
        XCTAssertTrue(last.finished)
        XCTAssertEqual(last.outTime ?? 0, 4, accuracy: 0.3)
    }

    func testCancelStopsFFmpegQuickly() async throws {
        let process = RunningProcess(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=600",
            "-c:v", "libx264", "-f", "null", "-",
        ])
        let task = Task { try await process.run() }
        try await Task.sleep(nanoseconds: 500_000_000)
        let start = Date()
        process.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch ProcessError.cancelled {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        }
    }

    /// ffmpeg exits 0 when -n refuses to overwrite, so the app must never rely on the exit code alone.
    func testNoOverwriteLeavesExistingFileAlone() async throws {
        let existing = directory.appendingPathComponent("keep.mp4")
        try "precious".write(to: existing, atomically: true, encoding: .utf8)
        _ = try await RunningProcess.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                                                  "-i", source.path, "-map", "0:0", "-c", "copy", existing.path])
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "precious")
    }

    func testOutputNamerOnRealFolder() throws {
        let mkv = directory.appendingPathComponent("a.mkv")
        try Data().write(to: mkv)
        try Data().write(to: directory.appendingPathComponent("a.mp4"))
        XCTAssertEqual(OutputNamer.outputURL(for: mkv, container: .mp4).lastPathComponent, "a_new.mp4")
        XCTAssertEqual(OutputNamer.outputURL(for: mkv, container: .mov).lastPathComponent, "a.mov")
        XCTAssertEqual(OutputNamer.outputURL(for: mkv, container: .mkv).lastPathComponent, "a_new.mkv")

        let other = directory.appendingPathComponent("Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(OutputNamer.outputURL(for: mkv, container: .mkv, directory: other).path,
                       other.appendingPathComponent("a.mkv").path)
    }

    // MARK: - Helpers

    private func requireEncoder(_ name: String) throws {
        if !encoders.contains(name) { throw XCTSkip("\(name) is not in this ffmpeg build") }
    }

    private func encode(preset name: String) async throws -> (URL, MediaInfo) {
        let preset = try XCTUnwrap(Preset.builtIn.first { $0.name == name })
        return try await encode(settings: preset.settings)
    }

    /// Runs the exact command the app would run, then probes the result.
    private func encode(settings: EncodeSettings, selection: Set<Int>? = nil,
                        directory: URL? = nil) async throws -> (URL, MediaInfo) {
        let info = try await Probe.run(ffprobe: ffprobe, file: source)
        let output = OutputNamer.outputURL(for: source, container: settings.container, directory: directory)
        let command = CommandBuilder.build(info: info, selection: selection ?? info.defaultSelection,
                                           settings: settings, input: source, output: output)
        let result = try await RunningProcess.run(ffmpeg, ["-loglevel", "error"] + command.arguments)
        guard result.status == 0, fileSize(output) > 0 else {
            throw FFmpegFailure(description: "\(command.shellString)\n\(String(decoding: result.stderr, as: UTF8.self))")
        }
        return (output, try await Probe.run(ffprobe: ffprobe, file: output))
    }

    private func makeSource() async throws -> URL {
        let srt = directory.appendingPathComponent("en.srt")
        try "1\n00:00:00,500 --> 00:00:02,000\nHello\n\n".write(to: srt, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("My Clip (2026).mkv")
        let video = encoders.contains("libx265")
            ? ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error"]
            : ["-c:v", "libx264", "-preset", "ultrafast"]
        let result = try await RunningProcess.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4:sample_rate=48000",
            "-i", srt.path,
            "-filter_complex", "[1]asplit=2[st][m];[m]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[s51]",
            "-map", "0:v", "-map", "[s51]", "-map", "[st]", "-map", "2:s",
        ] + video + [
            "-c:a:0", "ac3", "-c:a:1", "aac", "-ac:a:1", "2", "-c:s", "srt",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=jpn",
            "-metadata:s:s:0", "language=eng",
            output.path,
        ])
        guard result.status == 0 else {
            throw FFmpegFailure(description: String(decoding: result.stderr, as: UTF8.self))
        }
        return output
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
