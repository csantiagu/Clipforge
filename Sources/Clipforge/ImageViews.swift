import AppKit
import SwiftUI
import ClipforgeCore
import UniformTypeIdentifiers

// MARK: - Queue

struct ImageQueueColumn: View {
    @EnvironmentObject private var model: ImageModel
    @Binding var tab: AppTab
    let onDrop: ([URL]) -> Void
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QueueHeader(tab: $tab, totals: model.jobs.isEmpty ? nil : totals)
            if model.jobs.isEmpty {
                DropHero(targeted: dropTargeted, systemImage: "photo.stack", title: "Drop images here",
                         subtitle: "HEIC, JPEG, PNG, TIFF, WebP, RAW: anything macOS can open",
                         buttonTitle: "Choose Images…") { model.showOpenPanel() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.jobs) { job in
                            ImageCard(job: job, isSelected: model.selection.contains(job.id),
                                      thumbnail: model.thumbnails[job.id])
                                .onTapGesture { model.click(job.id, modifiers: NSEvent.modifierFlags) }
                                .contextMenu { menu(for: job) }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 84)   // room for the dock
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if !model.jobs.isEmpty { ImageDock() }
        }
        .overlay {
            if dropTargeted && !model.jobs.isEmpty { DropOutline() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var totals: String {
        let count = model.jobs.count
        let source = model.jobs.compactMap { $0.info?.fileSize }.reduce(0, +)
        var text = "\(count) image\(count == 1 ? "" : "s") · \(Format.bytes(source))"
        let outputs = model.jobs.compactMap(\.expectedOutputBytes)
        if outputs.count == count, source > 0 {
            text += "  →  \(Format.bytes(outputs.reduce(0, +)))"
        }
        return text
    }

    @ViewBuilder private func menu(for job: ImageJob) -> some View {
        let ids = model.selection.contains(job.id) ? model.selection : [job.id]
        if case .done(let url, _) = job.status {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Button("Convert Again") { model.requeue(ids) }
        Divider()
        Button("Remove") { model.remove(ids) }
    }
}

struct ImageCard: View {
    let job: ImageJob
    let isSelected: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            preview
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.input.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    ImageStatusPill(status: job.status)
                }
                if let info = job.info { chips(info) }
                detail
            }
        }
        .padding(12)
        .glassSurface(cornerRadius: 20, tint: isSelected ? Color.accentColor.opacity(0.45) : nil, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private var preview: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.12)
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
            }
            if case .done = job.status {
                Color.black.opacity(0.35)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            }
        }
        .frame(width: 96, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func chips(_ info: ImageInfo) -> some View {
        HStack(spacing: 5) {
            Chip(text: info.formatName)
            Chip(text: "\(info.displayWidth)×\(info.displayHeight)")
            if info.hasLocation {
                Chip(text: "Location", systemImage: "location.fill", color: .orange)
            }
            let others = info.metadata.filter { $0.label != "Location" }.count
            if others > 0 {
                Chip(text: "\(others) metadata", systemImage: "info.circle")
            }
            if info.frameCount > 1 {
                Chip(text: "\(info.frameCount) frames", systemImage: "square.stack")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.status {
        case .reading:
            Text("Reading image…").font(.caption).foregroundStyle(.secondary)
        case .unreadable(let message), .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(message)
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Saving…")
            }
            .font(.caption)
            outputLine
        case .done(let url, let bytes):
            SizeMeter(source: job.info?.fileSize ?? 0, output: bytes, approximate: false)
            HStack {
                outputLine
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .ready:
            SizeMeter(source: job.info?.fileSize ?? 0, output: job.expectedOutputBytes,
                      approximate: false, computing: job.isMeasuring)
            outputLine
        }
    }

    @ViewBuilder private var outputLine: some View {
        if let output = job.plannedOutput {
            Label(job.outputFolder.map { "\($0.lastPathComponent) / \(output.lastPathComponent)" } ?? output.lastPathComponent,
                  systemImage: job.outputFolder == nil ? "arrow.turn.down.right" : "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(output.path)
        }
    }
}

struct ImageStatusPill: View {
    let status: ImageJobStatus

    var body: some View {
        let style = Self.style(status)
        Text(style.text)
            .font(.caption.weight(.semibold))
            .fontDesign(.rounded)
            .foregroundStyle(style.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.16), in: Capsule())
    }

    static func style(_ status: ImageJobStatus) -> (text: String, color: Color) {
        switch status {
        case .reading: return ("Reading", Color.secondary)
        case .unreadable: return ("Can't read", .red)
        case .ready: return ("Ready", .blue)
        case .saving: return ("Saving", .green)
        case .done: return ("Done", .green)
        case .failed: return ("Failed", .red)
        }
    }
}

struct ImageDock: View {
    @EnvironmentObject private var model: ImageModel

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 4) {
                Button { model.showOpenPanel() } label: { Label("Add", systemImage: "plus") }
                Button { model.remove(model.selection) } label: { Label("Remove", systemImage: "trash") }
                    .disabled(model.selection.isEmpty)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Remove selected (⌘⌫)")
                if model.jobs.contains(where: { if case .done = $0.status { return true } else { return false } }) {
                    Button { model.removeFinished() } label: { Label("Clear Done", systemImage: "checkmark.circle") }
                }
                Divider().frame(height: 22).padding(.horizontal, 6)
                Button { model.start() } label: {
                    Label(model.readyCount > 0 ? "Save \(model.readyCount)" : "Save", systemImage: "square.and.arrow.down.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.readyCount == 0 || model.isRunning)
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .controlSize(.large)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassSurface(cornerRadius: 26)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Settings panel

struct ImageDetailPanel: View {
    var body: some View {
        ImageDetailView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassSurface(cornerRadius: 24)
    }
}

struct ImageDetailView: View {
    @EnvironmentObject private var model: ImageModel

    var body: some View {
        let jobs = model.selectedJobs
        if jobs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Select an image to tune it")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                Text("⌘-click or ⇧-click to change several at once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if jobs.allSatisfy(\.status.isLocked) {
            VStack(alignment: .leading, spacing: 14) {
                title(jobs)
                Text("Saved. Right-click the image and choose Convert Again to change its settings.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(18)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    title(jobs)
                    ImageSizeHero(jobs: jobs)
                    ImagePresetTiles()
                    ImageSettingsForm(settings: Binding(get: { model.selectionSettings },
                                                        set: { model.setSettings($0) }))
                    if jobs.count == 1, let info = jobs[0].info {
                        MetadataList(info: info, mode: jobs[0].settings.metadata)
                    }
                    ForEach(warnings(jobs), id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(18)
            }
            .scrollEdgeFade()
        }
    }

    private func title(_ jobs: [ImageJob]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(jobs.count == 1 ? jobs[0].input.deletingPathExtension().lastPathComponent : "\(jobs.count) images")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(jobs.count == 1 ? (jobs[0].info?.formatName ?? "Image") + " source" : "Changes apply to all of them")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func warnings(_ jobs: [ImageJob]) -> [String] {
        let settings = model.selectionSettings
        let infos = jobs.compactMap(\.info)
        var result: [String] = []
        if infos.contains(where: { $0.frameCount > 1 }) {
            result.append("Animated or multi-image files keep only their first frame.")
        }
        if settings.format == .jpeg, infos.contains(where: \.hasAlpha) {
            result.append("JPEG has no transparency: transparent areas become white. Use PNG or HEIC to keep them.")
        }
        if settings.format == .heic {
            result.append("HEIC opens on Apple devices and current Windows and Android, but some older apps and websites can't read it.")
        }
        return result
    }
}

/// Exact before/after size: images are converted in memory, so this isn't an estimate.
struct ImageSizeHero: View {
    let jobs: [ImageJob]

    var body: some View {
        let source = jobs.compactMap { $0.info?.fileSize }.reduce(0, +)
        let outputs = jobs.compactMap(\.expectedOutputBytes)
        let known = outputs.count == jobs.count
        let total = outputs.reduce(0, +)
        let grew = total > source
        let lossless = jobs.allSatisfy(\.willBeLossless)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Now").font(.caption).foregroundStyle(.secondary)
                    Text(Format.bytes(source))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("After").font(.caption).foregroundStyle(.secondary)
                    Text(known ? Format.bytes(total) : "…")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
                Spacer()
                if known && source > 0 {
                    Text(Format.change(from: source, to: total).trimmingCharacters(in: CharacterSet(charactersIn: " ()")))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(grew ? Color.orange : Color.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background((grew ? Color.orange : Color.green).opacity(0.15), in: Capsule())
                }
            }
            .monospacedDigit()
            SizeMeter(source: source, output: known ? total : nil, approximate: false, computing: !known)
            if lossless {
                Label("No re-compression: the picture is copied untouched and only the metadata changes.",
                      systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Exact size: each image is converted in memory with these settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ImagePresetTiles: View {
    @EnvironmentObject private var model: ImageModel

    var body: some View {
        let active = ImagePreset.builtIn.first { $0.settings == model.selectionSettings }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(ImagePreset.builtIn) { preset in
                    tile(preset, isActive: preset.id == active?.id)
                }
            }
            Text(active?.summary ?? "Custom settings. Pick a preset to start over.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tile(_ preset: ImagePreset, isActive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { model.apply(preset) } label: {
            VStack(spacing: 6) {
                Image(systemName: preset.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(height: 22)
                Text(preset.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background {
                if isActive {
                    shape.fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                                              startPoint: .top, endPoint: .bottom))
                } else {
                    shape.fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(preset.summary)
        .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

struct ImageSettingsForm: View {
    @EnvironmentObject private var model: ImageModel
    @Binding var settings: ImageSettings

    private static let sizes = [0, 4096, 3000, 2048, 1600, 1080, 800]

    private var isLossyOutput: Bool {
        switch settings.format {
        case .jpeg, .heic: return true
        case .png, .tiff: return false
        case .original:
            // Depends on each source; JPEG and HEIC sources are lossy.
            return model.selectedJobs.contains { job in
                guard let type = job.info?.type else { return false }
                return type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelSection(title: "Output", systemImage: "doc.badge.gearshape") {
                VStack(alignment: .leading, spacing: 8) {
                    row("Format") {
                        Picker("Format", selection: $settings.format) {
                            ForEach(ImageFormat.allCases.filter { model.writableFormats.contains($0) }) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    hint(formatHint)
                    row("Save to") {
                        DestinationMenu(current: model.selectionOutputFolder, remembered: model.defaultOutputFolder,
                                        setFolder: { model.setOutputFolder($0) }, chooseFolder: { model.chooseOutputFolder() })
                    }
                    hint("Next to the original, same format, adds _new to the name. In another folder the name stays the same. Nothing is ever overwritten.")
                }
            }

            PanelSection(title: "Size", systemImage: "arrow.down.right.and.arrow.up.left") {
                VStack(alignment: .leading, spacing: 8) {
                    row("") { Toggle("Compress", isOn: $settings.compress) }
                    if settings.compress && isLossyOutput {
                        row("Quality") {
                            Slider(value: Binding(get: { Double(settings.quality) },
                                                  set: { settings.quality = Int($0.rounded()) }),
                                   in: 10...100, step: 5)
                            Text("\(settings.quality)").monospacedDigit().frame(width: 28, alignment: .trailing)
                        }
                        hint("80 looks the same as the original to most people at a fraction of the size. Below 50, edges start to smear.")
                    } else if settings.compress {
                        hint("PNG and TIFF are lossless, so quality doesn't apply. Make them smaller with Max size, or convert to JPEG or HEIC.")
                    } else {
                        hint("Keeps the original compression. JPEG, PNG and TIFF are copied untouched when the format and size stay the same.")
                    }
                    row("Max size") {
                        Picker("Max size", selection: $settings.maxDimension) {
                            ForEach(Self.sizes, id: \.self) { size in
                                Text(size == 0 ? "Keep original" : "\(size) px").tag(size)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                    hint("Longest side. A 12-megapixel phone photo is 4032 px; 2048 px is plenty for screens and cuts the file to about a quarter. Images are never enlarged.")
                }
            }

            PanelSection(title: "Metadata", systemImage: "eye.slash") {
                VStack(alignment: .leading, spacing: 8) {
                    row("Remove") {
                        Picker("Metadata", selection: $settings.metadata) {
                            ForEach(MetadataMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    hint(metadataHint)
                }
            }
        }
    }

    private var formatHint: String {
        switch settings.format {
        case .original: return "Keeps each image's own format."
        case .jpeg: return "Opens everywhere. No transparency."
        case .heic: return "About half the size of JPEG at the same quality. Best on Apple devices."
        case .png: return "Lossless, keeps transparency. Large for photos; best for screenshots and graphics."
        case .tiff: return "Lossless, for printing and editing. Very large."
        }
    }

    private var metadataHint: String {
        switch settings.metadata {
        case .removeAll: return "Removes location, camera, dates, owner, serial numbers and captions. The colour profile and rotation are kept, so the picture looks the same."
        case .removeLocation: return "Removes GPS location only. Camera, dates and captions stay."
        case .keepAll: return "Keeps everything, including location. Anyone you send the file to can see where it was taken."
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(width: 92, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 102)
    }
}

/// What's in this file, and what happens to each item with the chosen setting.
struct MetadataList: View {
    let info: ImageInfo
    let mode: MetadataMode

    var body: some View {
        PanelSection(title: "Found in this image", systemImage: "doc.text.magnifyingglass") {
            if info.metadata.isEmpty {
                Text("No personal metadata. Nothing to remove.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(info.metadata, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: removed(item) ? "xmark.circle.fill" : "checkmark.circle")
                                .foregroundStyle(removed(item) ? Color.green : Color.secondary)
                                .help(removed(item) ? "Will be removed" : "Will be kept")
                            Text(item.label)
                                .fontWeight(.medium)
                                .foregroundStyle(item.isSensitive ? Color.orange : Color.primary)
                                .frame(width: 92, alignment: .leading)
                            Text(item.value)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func removed(_ item: MetadataItem) -> Bool {
        switch mode {
        case .removeAll: return true
        case .removeLocation: return item.label == "Location"
        case .keepAll: return false
        }
    }
}
