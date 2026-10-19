import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClipforgeCore

enum JobStatus: Equatable {
    case probing
    case unreadable(String)
    case ready
    case running(fraction: Double, speed: Double?)
    case done(URL, Int64)
    case failed(String)
    case cancelled

    /// Running or finished jobs keep their output name and settings.
    var isLocked: Bool {
        switch self {
        case .running, .done: return true
        default: return false
        }
    }
}

enum SizeEstimate: Equatable {
    case none
    case computing
    case value(Int64, sampled: Bool)
    case failed(String)
}

struct Job: Identifiable {
    let id = UUID()
    let input: URL
    var settings: EncodeSettings
    var info: MediaInfo?
    var selection: Set<Int> = []
    var status: JobStatus = .probing
    var plannedOutput: URL?
    var command: EncodeCommand?
    var estimate: SizeEstimate = .none
    /// What a sampled estimate was computed for, so it survives unrelated refreshes.
    var estimateKey: EstimateKey?
    /// Where the output goes. nil = next to the original.
    var outputFolder: URL?
}

struct EstimateKey: Equatable {
    let settings: EncodeSettings
    let selection: Set<Int>
}

/// Progress parser state shared with ffmpeg's stdout reader thread.
private final class ParserBox: @unchecked Sendable {
    var parser = ProgressParser()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var selection: Set<Job.ID> = []
    @Published private(set) var isRunning = false
    @Published private(set) var availableEncoders: Set<String> = []
    @Published var defaultSettings = Preset.builtIn[0].settings
    @Published private(set) var thumbnails: [Job.ID: NSImage] = [:]

    let ffmpegURL = FFmpegLocator.find("ffmpeg")
    let ffprobeURL = FFmpegLocator.find("ffprobe")

    private var current: (job: Job.ID, process: RunningProcess)?
    private var stopRequested = false
    private var sleepActivity: NSObjectProtocol?
    private var selectionAnchor: Job.ID?

    /// Folder for newly added videos, remembered between launches. nil = next to the original.
    @Published private(set) var defaultOutputFolder: URL?
    private static let outputFolderKey = "outputFolder"

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.outputFolderKey) {
            defaultOutputFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        Task { await loadEncoders() }
    }

    private func loadEncoders() async {
        guard let ffmpeg = ffmpegURL,
              let result = try? await RunningProcess.run(ffmpeg, ["-hide_banner", "-encoders"]) else { return }
        availableEncoders = FFmpegCapabilities.parseEncoders(String(decoding: result.stdout, as: UTF8.self))
    }

    func isAvailable(_ encoder: VideoEncoder) -> Bool {
        encoder == .copy || availableEncoders.isEmpty || availableEncoders.contains(encoder.ffmpegName)
    }

    // MARK: - Lookup

    func job(_ id: Job.ID) -> Job? { jobs.first { $0.id == id } }

    private func update(_ id: Job.ID, _ change: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
    }

    var selectedJobs: [Job] { jobs.filter { selection.contains($0.id) } }

    // MARK: - Adding and removing

    static let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        + ["mkv", "webm", "m4v", "avi", "ts", "mts", "m2ts", "wmv", "flv", "3gp", "mpg", "mpeg", "vob"]
            .compactMap { UTType(filenameExtension: $0) }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.videoTypes
        panel.message = "Choose one or more videos"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        let existing = Set(jobs.map { $0.input.standardizedFileURL })
        var added: [Job.ID] = []
        for url in urls where !existing.contains(url.standardizedFileURL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            var job = Job(input: url, settings: defaultSettings)
            job.outputFolder = defaultOutputFolder
            jobs.append(job)
            added.append(job.id)
            Task { await probe(job.id) }
        }
        if let first = added.first, selection.isEmpty { selection = [first] }
    }

    func remove(_ ids: Set<Job.ID>) {
        let removable = ids.filter { !isActive($0) }
        jobs.removeAll { removable.contains($0.id) }
        for id in removable { thumbnails[id] = nil }
        selection.subtract(removable)
        refreshAll()
    }

    // MARK: - Selection (Finder-style: click, ⌘-click, ⇧-click)

    func click(_ id: Job.ID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else if modifiers.contains(.shift),
                  let anchor = selectionAnchor,
                  let from = jobs.firstIndex(where: { $0.id == anchor }),
                  let to = jobs.firstIndex(where: { $0.id == id }) {
            selection = Set(jobs[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    func selectAll() {
        selection = Set(jobs.map(\.id))
    }

    func removeFinished() {
        remove(Set(jobs.filter { if case .done = $0.status { return true } else { return false } }.map(\.id)))
    }

    func requeue(_ ids: Set<Job.ID>) {
        for id in ids where !isActive(id) {
            update(id) { if $0.info != nil { $0.status = .ready } }
        }
        refreshAll()
    }

    private func isActive(_ id: Job.ID) -> Bool { current?.job == id }

    private func probe(_ id: Job.ID) async {
        guard let job = job(id) else { return }
        guard let ffprobe = ffprobeURL else {
            update(id) { $0.status = .unreadable("ffprobe not found") }
            return
        }
        do {
            let info = try await Probe.run(ffprobe: ffprobe, file: job.input)
            update(id) {
                $0.info = info
                $0.selection = info.defaultSelection
                $0.status = .ready
            }
        } catch {
            update(id) { $0.status = .unreadable(error.localizedDescription) }
        }
        refreshAll()
        await makeThumbnail(id)
    }

    /// Grabs one frame at 10% of the running time.
    private func makeThumbnail(_ id: Job.ID) async {
        guard let ffmpeg = ffmpegURL, let job = job(id), let info = job.info, !info.videoStreams.isEmpty else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clipforge-thumb-\(id.uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let seconds = String(format: "%.2f", info.duration * 0.1)
        let arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", seconds, "-i", job.input.path,
                         "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=480:-2", "-q:v", "4", file.path]
        guard let result = try? await RunningProcess.run(ffmpeg, arguments), result.status == 0,
              let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return }
        thumbnails[id] = image
    }

    // MARK: - Settings

    /// The settings panel shows the first selected job and writes to all selected ones.
    var selectionSettings: EncodeSettings {
        selectedJobs.first(where: { !$0.status.isLocked })?.settings ?? defaultSettings
    }

    func setSettings(_ new: EncodeSettings) {
        var settings = new
        let old = selectionSettings
        if settings.videoEncoder != old.videoEncoder {
            settings.quality = settings.videoEncoder.defaultQuality
        }
        defaultSettings = settings
        for i in jobs.indices where selection.contains(jobs[i].id) && !jobs[i].status.isLocked {
            jobs[i].settings = settings
        }
        refreshAll()
    }

    func apply(_ preset: Preset) {
        var settings = preset.settings
        if !isAvailable(settings.videoEncoder) { settings.videoEncoder = .x264 }
        defaultSettings = settings
        for i in jobs.indices where selection.contains(jobs[i].id) && !jobs[i].status.isLocked {
            jobs[i].settings = settings
        }
        refreshAll()
    }

    // MARK: - Destination

    /// nil when the selected videos go to different places.
    var selectionOutputFolder: URL?? {
        let folders = selectedJobs.filter { !$0.status.isLocked }.map(\.outputFolder)
        guard let first = folders.first else { return .some(defaultOutputFolder) }
        return folders.allSatisfy { $0 == first } ? .some(first) : nil
    }

    /// Sets the destination for the selected videos and for videos added later.
    func setOutputFolder(_ folder: URL?) {
        defaultOutputFolder = folder
        if let folder {
            UserDefaults.standard.set(folder.path, forKey: Self.outputFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.outputFolderKey)
        }
        for i in jobs.indices where selection.contains(jobs[i].id) && !jobs[i].status.isLocked {
            jobs[i].outputFolder = folder
        }
        refreshAll()
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = "Choose where converted videos are saved"
        if let current = defaultOutputFolder { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url { setOutputFolder(url) }
    }

    // MARK: - Tracks

    func setStream(_ index: Int, on: Bool, in id: Job.ID) {
        update(id) { if on { $0.selection.insert(index) } else { $0.selection.remove(index) } }
        refreshAll()
    }

    func setStreams(_ indices: [Int], on: Bool, in id: Job.ID) {
        update(id) {
            if on { $0.selection.formUnion(indices) } else { $0.selection.subtract(indices) }
        }
        refreshAll()
    }

    /// Across all selected files: keep only tracks of `kind` in `language`.
    /// nil keeps none; "*" keeps all. Files without that language are left alone.
    func keepOnly(_ kind: StreamKind, language: String?) {
        for i in jobs.indices where selection.contains(jobs[i].id) && !jobs[i].status.isLocked {
            guard let info = jobs[i].info else { continue }
            let ofKind = info.streams.filter { $0.kind == kind }
            let keep: [MediaStream]
            switch language {
            case nil: keep = []
            case "*"?: keep = ofKind
            case let lang?: keep = ofKind.filter { ($0.language ?? "und") == lang }
            }
            if language != nil && language != "*" && keep.isEmpty { continue }
            jobs[i].selection.subtract(ofKind.map(\.index))
            jobs[i].selection.formUnion(keep.map(\.index))
        }
        refreshAll()
    }

    func languages(of kind: StreamKind) -> [String] {
        var all: [String] = []
        for job in selectedJobs {
            for lang in job.info?.languages(of: kind) ?? [] where !all.contains(lang) { all.append(lang) }
        }
        return all
    }

    // MARK: - Planning

    /// Recomputes output names, commands and quick estimates. Names are assigned in list
    /// order so two queued jobs never get the same output file.
    func refreshAll() {
        var reserved = Set(jobs.filter(\.status.isLocked).compactMap { $0.plannedOutput?.path.lowercased() })
        for i in jobs.indices where !jobs[i].status.isLocked {
            guard let info = jobs[i].info else { continue }
            let job = jobs[i]
            let output = OutputNamer.outputURL(for: job.input, container: job.settings.container,
                                               directory: job.outputFolder, reserved: reserved)
            reserved.insert(output.path.lowercased())
            let command = CommandBuilder.build(info: info, selection: job.selection, settings: job.settings,
                                               input: job.input, output: output)
            jobs[i].plannedOutput = output
            jobs[i].command = command

            let key = EstimateKey(settings: job.settings, selection: job.selection)
            if job.estimateKey == key, job.estimate != .none { continue }
            jobs[i].estimateKey = nil
            if let bytes = SizeEstimator.quickEstimate(info: info, selection: job.selection,
                                                       settings: job.settings, command: command) {
                jobs[i].estimate = .value(bytes, sampled: false)
            } else {
                jobs[i].estimate = .none
            }
        }
    }

    /// Encodes ~20 s from the middle of each selected file and scales the size up.
    func estimateSelected() {
        let ids = jobs.filter { selection.contains($0.id) && !$0.status.isLocked && $0.info != nil }.map(\.id)
        Task {
            for id in ids { await sampleEstimate(id) }
        }
    }

    private func sampleEstimate(_ id: Job.ID) async {
        guard let ffmpeg = ffmpegURL, let job = job(id), let info = job.info, info.duration > 0 else { return }
        let length = min(20, info.duration)
        let start = info.duration > 60 ? info.duration * 0.4 : 0
        let sample = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipforge-sample-\(UUID().uuidString).\(job.settings.container.fileExtension)")
        defer { try? FileManager.default.removeItem(at: sample) }

        let key = EstimateKey(settings: job.settings, selection: job.selection)
        update(id) { $0.estimate = .computing; $0.estimateKey = key }
        let command = CommandBuilder.build(info: info, selection: job.selection, settings: job.settings,
                                           input: job.input, output: sample,
                                           segment: Segment(start: start, duration: length), overwrite: true)
        let estimate: SizeEstimate
        do {
            let result = try await RunningProcess.run(ffmpeg, ["-loglevel", "error"] + command.arguments)
            let bytes = Self.fileSize(sample)
            if result.status == 0 && bytes > 0 {
                estimate = .value(SizeEstimator.extrapolate(sampleBytes: bytes, sampleSeconds: length,
                                                            totalSeconds: info.duration), sampled: true)
            } else {
                estimate = .failed(Self.lastLines(result.stderr))
            }
        } catch {
            estimate = .failed(error.localizedDescription)
        }
        // Drop the result if settings changed while sampling.
        update(id) { if $0.estimateKey == key { $0.estimate = estimate } }
    }

    // MARK: - Encoding

    var readyCount: Int { jobs.filter { $0.status == .ready }.count }

    func start() {
        guard !isRunning, let ffmpeg = ffmpegURL else { return }
        isRunning = true
        stopRequested = false
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Encoding video")
        Task {
            while !stopRequested, let next = jobs.first(where: { $0.status == .ready }) {
                await encode(next.id, ffmpeg: ffmpeg)
            }
            if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity) }
            sleepActivity = nil
            isRunning = false
            if !stopRequested { NSSound(named: "Glass")?.play() }
        }
    }

    func stop() {
        stopRequested = true
        current?.process.cancel()
    }

    /// Called on quit: ffmpeg would otherwise keep running after the app is gone.
    func terminateNow() {
        guard let current else { return }
        current.process.cancel()
        current.process.waitUntilExit()
        if let output = job(current.job)?.plannedOutput { try? FileManager.default.removeItem(at: output) }
    }

    private func encode(_ id: Job.ID, ffmpeg: URL) async {
        refreshAll()
        guard let job = job(id), let info = job.info, let output = job.plannedOutput else { return }
        // External drives get unplugged; say so instead of letting ffmpeg fail obscurely.
        if let folder = job.outputFolder {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue, FileManager.default.isWritableFile(atPath: folder.path) else {
                update(id) {
                    $0.status = .failed("Can't save to “\(folder.lastPathComponent)”: the folder is missing or read-only. Is the drive connected?")
                }
                return
            }
        }
        // The name was free a moment ago; never touch a file we didn't create.
        if FileManager.default.fileExists(atPath: output.path) {
            update(id) { $0.status = .failed("\(output.lastPathComponent) already exists") }
            return
        }
        let command = CommandBuilder.build(info: info, selection: job.selection, settings: job.settings,
                                           input: job.input, output: output)
        let process = RunningProcess(executable: ffmpeg,
                                     arguments: ["-progress", "pipe:1", "-nostats", "-loglevel", "error"] + command.arguments)
        current = (id, process)
        update(id) {
            $0.command = command
            $0.status = .running(fraction: 0, speed: nil)
        }

        let box = ParserBox()
        let duration = info.duration
        do {
            let result = try await process.run(onStdout: { data in
                guard let last = box.parser.feed(String(decoding: data, as: UTF8.self)).last else { return }
                let fraction = duration > 0 ? min(1, (last.outTime ?? 0) / duration) : 0
                Task { @MainActor in
                    self.update(id) {
                        if case .running = $0.status { $0.status = .running(fraction: fraction, speed: last.speed) }
                    }
                }
            })
            // ffmpeg can exit 0 without writing anything (e.g. -n refusing to overwrite).
            let size = Self.fileSize(output)
            if result.status == 0 && size > 0 {
                update(id) { $0.status = .done(output, size) }
            } else {
                try? FileManager.default.removeItem(at: output)
                update(id) { $0.status = .failed(Self.lastLines(result.stderr)) }
            }
        } catch ProcessError.cancelled {
            try? FileManager.default.removeItem(at: output)
            update(id) { $0.status = .cancelled }
        } catch {
            try? FileManager.default.removeItem(at: output)
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
        current = nil
        refreshAll()
    }

    // MARK: - Helpers

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func lastLines(_ data: Data, count: Int = 4) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").suffix(count).joined(separator: "\n")
        return text.isEmpty ? "ffmpeg failed without a message" : text
    }
}
