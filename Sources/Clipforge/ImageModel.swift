import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClipforgeCore

/// Which queue the window shows. Stored so the app reopens on the same tab.
enum AppTab: String {
    case videos, images
}

enum ImageJobStatus: Equatable {
    case reading
    case unreadable(String)
    case ready
    case saving
    case done(URL, Int64)
    case failed(String)

    /// Saving or saved images keep their output name and settings.
    var isLocked: Bool {
        switch self {
        case .saving, .done: return true
        default: return false
        }
    }
}

struct ImageJob: Identifiable {
    let id = UUID()
    let input: URL
    var settings: ImageSettings
    /// nil = next to the original.
    var outputFolder: URL?
    var info: ImageInfo?
    var status: ImageJobStatus = .reading
    var plannedOutput: URL?
    /// Exact size of the converted file, measured by converting in memory.
    var estimate: Int64?
    /// The settings `estimate` was measured with; nil until measured.
    var estimateKey: ImageSettings?
    /// The image data will be copied untouched (only metadata changes).
    var willBeLossless = false

    var isMeasuring: Bool { info != nil && estimateKey != settings }

    /// Final size when saved, otherwise the measured size.
    var expectedOutputBytes: Int64? {
        if case .done(_, let bytes) = status { return bytes }
        return estimateKey == settings ? estimate : nil
    }
}

@MainActor
final class ImageModel: ObservableObject {
    @Published var jobs: [ImageJob] = []
    @Published var selection: Set<ImageJob.ID> = []
    @Published private(set) var isRunning = false
    @Published private(set) var thumbnails: [ImageJob.ID: NSImage] = [:]
    @Published var defaultSettings = ImagePreset.builtIn[0].settings
    /// Folder for newly added images, remembered between launches. nil = next to the original.
    @Published private(set) var defaultOutputFolder: URL?

    let writableFormats = ImageProcessor.writableFormats()

    private var selectionAnchor: ImageJob.ID?
    private var measuring = false
    private static let outputFolderKey = "imageOutputFolder"

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.outputFolderKey) {
            defaultOutputFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    func job(_ id: ImageJob.ID) -> ImageJob? { jobs.first { $0.id == id } }

    private func update(_ id: ImageJob.ID, _ change: (inout ImageJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
    }

    var selectedJobs: [ImageJob] { jobs.filter { selection.contains($0.id) } }
    var readyCount: Int { jobs.filter { $0.status == .ready }.count }

    // MARK: - Adding and removing

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose one or more images"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        let existing = Set(jobs.map { $0.input.standardizedFileURL })
        var added: [ImageJob.ID] = []
        for url in urls where !existing.contains(url.standardizedFileURL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            var job = ImageJob(input: url, settings: defaultSettings)
            job.outputFolder = defaultOutputFolder
            jobs.append(job)
            added.append(job.id)
            Task { await read(job.id) }
        }
        if let first = added.first, selection.isEmpty { selection = [first] }
    }

    func remove(_ ids: Set<ImageJob.ID>) {
        let removable = ids.filter { job($0)?.status != .saving }
        jobs.removeAll { removable.contains($0.id) }
        for id in removable { thumbnails[id] = nil }
        selection.subtract(removable)
        refreshAll()
    }

    func removeFinished() {
        remove(Set(jobs.filter { if case .done = $0.status { return true } else { return false } }.map(\.id)))
    }

    func requeue(_ ids: Set<ImageJob.ID>) {
        for id in ids {
            update(id) { if $0.info != nil && $0.status != .saving { $0.status = .ready } }
        }
        refreshAll()
    }

    private func read(_ id: ImageJob.ID) async {
        guard let url = job(id)?.input else { return }
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ImageInfo, Error> in
            Result { try ImageProcessor.readInfo(url) }
        }.value
        switch outcome {
        case .success(let info):
            update(id) {
                $0.info = info
                $0.status = .ready
            }
        case .failure(let error):
            update(id) { $0.status = .unreadable(error.localizedDescription) }
        }
        refreshAll()
        let thumbnail = await Task.detached(priority: .utility) {
            ImageProcessor.thumbnail(url, maxPixelSize: 320)
        }.value
        if let thumbnail, job(id) != nil {
            thumbnails[id] = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
    }

    // MARK: - Selection (Finder-style: click, ⌘-click, ⇧-click)

    func click(_ id: ImageJob.ID, modifiers: NSEvent.ModifierFlags) {
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

    // MARK: - Settings

    var selectionSettings: ImageSettings {
        selectedJobs.first(where: { !$0.status.isLocked })?.settings ?? defaultSettings
    }

    func setSettings(_ settings: ImageSettings) {
        defaultSettings = settings
        for i in jobs.indices where selection.contains(jobs[i].id) && !jobs[i].status.isLocked {
            jobs[i].settings = settings
        }
        refreshAll()
    }

    func apply(_ preset: ImagePreset) {
        var settings = preset.settings
        if !writableFormats.contains(settings.format) { settings.format = .jpeg }
        setSettings(settings)
    }

    // MARK: - Destination

    /// nil when the selected images go to different places.
    var selectionOutputFolder: URL?? {
        let folders = selectedJobs.filter { !$0.status.isLocked }.map(\.outputFolder)
        guard let first = folders.first else { return .some(defaultOutputFolder) }
        return folders.allSatisfy { $0 == first } ? .some(first) : nil
    }

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
        if let url = FolderPicker.choose(startingAt: defaultOutputFolder, message: "Choose where converted images are saved") {
            setOutputFolder(url)
        }
    }

    // MARK: - Planning

    /// Output names in list order (so two images never get the same name), then measure sizes.
    func refreshAll() {
        var reserved = Set(jobs.filter(\.status.isLocked).compactMap { $0.plannedOutput?.path.lowercased() })
        for i in jobs.indices where !jobs[i].status.isLocked {
            guard let info = jobs[i].info else { continue }
            let ext = ImageProcessor.fileExtension(for: jobs[i].input, info: info, settings: jobs[i].settings)
            let output = OutputNamer.outputURL(for: jobs[i].input, fileExtension: ext,
                                               directory: jobs[i].outputFolder, reserved: reserved)
            reserved.insert(output.path.lowercased())
            jobs[i].plannedOutput = output
            jobs[i].willBeLossless = ImageProcessor.canCopyLosslessly(info, settings: jobs[i].settings)
        }
        measureSizes()
    }

    /// Converts each image in memory, one at a time, to show its exact output size.
    private func measureSizes() {
        guard !measuring else { return }
        measuring = true
        Task {
            while let next = jobs.first(where: { $0.status == .ready && $0.isMeasuring }), let info = next.info {
                let id = next.id, url = next.input, settings = next.settings
                let size = await Task.detached(priority: .utility) { () -> Int64? in
                    (try? ImageProcessor.process(url, info: info, settings: settings)).map { Int64($0.data.count) }
                }.value
                // Settings changed meanwhile: the loop measures again with the new ones.
                update(id) {
                    if $0.settings == settings {
                        $0.estimate = size
                        $0.estimateKey = settings
                    }
                }
            }
            measuring = false
        }
    }

    // MARK: - Saving

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            while let next = jobs.first(where: { $0.status == .ready && $0.info != nil }) {
                await save(next.id)
            }
            isRunning = false
            NSSound(named: "Glass")?.play()
        }
    }

    private func save(_ id: ImageJob.ID) async {
        refreshAll()
        guard let job = job(id), let info = job.info, let output = job.plannedOutput else { return }
        if let folder = job.outputFolder, !FolderPicker.isWritableFolder(folder) {
            update(id) {
                $0.status = .failed("Can't save to “\(folder.lastPathComponent)”: the folder is missing or read-only. Is the drive connected?")
            }
            return
        }
        update(id) { $0.status = .saving }
        let input = job.input, settings = job.settings
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Int64, Error> in
            Result {
                let result = try ImageProcessor.process(input, info: info, settings: settings)
                // Never overwrite: fails if a file with this name appeared meanwhile.
                try result.data.write(to: output, options: .withoutOverwriting)
                return Int64(result.data.count)
            }
        }.value
        switch outcome {
        case .success(let bytes): update(id) { $0.status = .done(output, bytes) }
        case .failure(let error): update(id) { $0.status = .failed(error.localizedDescription) }
        }
        refreshAll()
    }
}

/// Shared by the video and image tabs.
enum FolderPicker {
    @MainActor
    static func choose(startingAt folder: URL?, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = message
        if let folder { panel.directoryURL = folder }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// External drives get unplugged; check before writing instead of failing obscurely.
    static func isWritableFolder(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: folder.path)
    }
}
