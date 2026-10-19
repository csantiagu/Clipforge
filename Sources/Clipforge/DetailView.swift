import AppKit
import SwiftUI
import ClipforgeCore

/// The glass inspector on the right.
struct DetailPanel: View {
    var body: some View {
        DetailView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // A ScrollView at the top of the window may draw under the title bar; keep it inside the panel.
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassSurface(cornerRadius: 24)
    }
}

struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let jobs = model.selectedJobs
        if jobs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Select a video to tune it")
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                Text("⌘-click or ⇧-click to change several at once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if jobs.allSatisfy(\.status.isLocked) {
            VStack(alignment: .leading, spacing: 14) {
                PanelTitle(jobs: jobs)
                Text("Encoding or finished. Right-click the video and choose Encode Again to change its settings.")
                    .foregroundStyle(.secondary)
                if jobs.count == 1, let command = jobs[0].command { CommandBox(command: command) }
                Spacer()
            }
            .padding(18)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PanelTitle(jobs: jobs)
                    EstimateHero(jobs: jobs)
                    PresetTiles()
                    SettingsForm(settings: Binding(get: { model.selectionSettings },
                                                   set: { model.setSettings($0) }))
                    TrackFilters()
                    if jobs.count == 1, let info = jobs[0].info {
                        TrackList(job: jobs[0], info: info)
                    }
                    if jobs.count == 1, let command = jobs[0].command {
                        ForEach(command.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        CommandBox(command: command)
                    }
                }
                .padding(18)
            }
            .scrollEdgeFade()
        }
    }
}

struct PanelTitle: View {
    let jobs: [Job]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(jobs.count == 1 ? jobs[0].input.deletingPathExtension().lastPathComponent : "\(jobs.count) videos")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(jobs.count == 1 ? jobs[0].input.pathExtension.uppercased() + " source" : "Changes apply to all of them")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Grouped block inside the glass panel. Plain fill, because glass on glass turns to mud.
struct PanelSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .fontDesign(.rounded)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PresetTiles: View {
    @EnvironmentObject private var model: AppModel

    private static let icons: [String: String] = [
        "Compatible": "play.tv",
        "Small · fast": "bolt.fill",
        "Small · best": "sparkles",
        "Fix audio only": "speaker.wave.2.fill",
        "Remux": "shippingbox.fill",
    ]

    var body: some View {
        let active = Preset.builtIn.first { $0.settings == model.selectionSettings }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Preset.builtIn) { preset in
                    tile(preset, isActive: preset.id == active?.id)
                }
            }
            Text(active?.summary ?? "Custom settings. Pick a preset to start over.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tile(_ preset: Preset, isActive: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button { model.apply(preset) } label: {
            VStack(spacing: 6) {
                Image(systemName: Self.icons[preset.name] ?? "wand.and.stars")
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

struct SettingsForm: View {
    @EnvironmentObject private var model: AppModel
    @Binding var settings: EncodeSettings

    private static let heights = [0, 2160, 1440, 1080, 720, 480]
    private static let audioRates = [96, 128, 160, 192, 256, 320]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelSection(title: "Output", systemImage: "doc.badge.gearshape") {
                VStack(alignment: .leading, spacing: 8) {
                    row("Format") {
                        Picker("Format", selection: $settings.container) {
                            ForEach(Container.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                    hint(containerHint)
                    row("Save to") { DestinationMenu() }
                    hint("Next to the original, same format, adds _new to the name. In another folder the name stays the same. Nothing is ever overwritten.")
                }
            }

            PanelSection(title: "Video", systemImage: "film") {
                VStack(alignment: .leading, spacing: 8) {
                    row("Encoder") {
                        Picker("Encoder", selection: $settings.videoEncoder) {
                            ForEach(VideoEncoder.allCases.filter { model.isAvailable($0) || $0 == settings.videoEncoder }) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    if settings.videoEncoder == .copy {
                        hint("The picture is copied bit-for-bit: no quality loss, fast, and the video size doesn't change.")
                    } else {
                        row("Size control") {
                            Picker("Size control", selection: $settings.rateMode) {
                                ForEach(RateMode.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        rateControls
                        if settings.videoEncoder.usesCRF {
                            row("Speed") {
                                Picker("Speed", selection: $settings.speed) {
                                    ForEach(SpeedPreset.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 160)
                            }
                            hint("Slower presets give a smaller file at the same quality. Each step slower takes roughly 1.5–2× the time for 3–8% less size.")
                        }
                        row("Max resolution") {
                            Picker("Max resolution", selection: $settings.maxHeight) {
                                ForEach(Self.heights, id: \.self) { h in
                                    Text(h == 0 ? "Keep original" : "\(h)p").tag(h)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 160)
                        }
                        hint("Going from 2160p to 1080p cuts size by roughly 60–75%. Smaller videos are never upscaled.")
                    }
                }
            }

            PanelSection(title: "Audio", systemImage: "waveform") {
                VStack(alignment: .leading, spacing: 8) {
                    row("Audio") {
                        Picker("Audio", selection: $settings.audioMode) {
                            ForEach(AudioMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                    if settings.audioMode == .aac {
                        row("Bitrate") {
                            Picker("Bitrate", selection: $settings.audioBitrateKbps) {
                                ForEach(Self.audioRates, id: \.self) { Text("\($0) kbps").tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 160)
                        }
                        row("") { Toggle("Downmix to stereo", isOn: $settings.downmixToStereo) }
                        hint("\(settings.audioBitrateKbps) kbps ≈ \(Format.perHour(kbps: settings.audioBitrateKbps)) per hour per audio track. 128 is fine for speech, 192 for music and stereo films. Surround tracks get at least 384 unless downmixed.")
                    } else {
                        hint("Keeps the original audio. DTS/TrueHD can't go into MP4/MOV and will still be converted to AAC.")
                    }
                }
            }
        }
    }

    @ViewBuilder private var rateControls: some View {
        switch settings.rateMode {
        case .quality:
            row(settings.videoEncoder.usesCRF ? "CRF" : "Quality") {
                Slider(value: Binding(get: { Double(settings.quality) },
                                      set: { settings.quality = Int($0.rounded()) }),
                       in: Double(settings.videoEncoder.qualityRange.lowerBound)...Double(settings.videoEncoder.qualityRange.upperBound),
                       step: 1)
                Text("\(settings.quality)").monospacedDigit().frame(width: 28, alignment: .trailing)
            }
            hint("\(settings.videoEncoder.qualityHint) Quality mode has no fixed size: use “Estimate size” below.")
        case .bitrate:
            row("Video bitrate") {
                TextField("kbps", value: $settings.videoBitrateKbps, format: .number)
                    .labelsHidden()
                    .frame(width: 80)
                Text("kbps")
            }
            hint("≈ \(Format.perHour(kbps: settings.videoBitrateKbps)) per hour of video. Typical: 720p 2,500 · 1080p 5,000 (H.264) or 3,000 (HEVC) · 4K 15,000–25,000.")
        case .targetSize:
            row("Target size") {
                TextField("MB", value: $settings.targetSizeMB, format: .number)
                    .labelsHidden()
                    .frame(width: 80)
                Text("MB per file")
            }
            hint("The video bitrate is worked out from the length and the audio. Expect results within about ±5%.")
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

    private var containerHint: String {
        switch settings.container {
        case .mp4: return "MP4 plays everywhere. It can't hold picture subtitles (PGS) or DTS/TrueHD audio."
        case .mkv: return "MKV keeps every kind of track and subtitle. Apple devices (QuickTime, iPhone, Apple TV app) don't play it natively."
        case .mov: return "MOV is Apple's format: the same limits as MP4, and it opens nicely in Final Cut and iMovie."
        }
    }
}

/// Where converted files go. Not part of presets, and remembered between launches.
struct DestinationMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let current = model.selectionOutputFolder
        Menu {
            Button {
                model.setOutputFolder(nil)
            } label: {
                Label("Next to Original", systemImage: "arrow.turn.down.right")
            }
            if let remembered = model.defaultOutputFolder, current != .some(remembered) {
                Button {
                    model.setOutputFolder(remembered)
                } label: {
                    Label(remembered.lastPathComponent, systemImage: "folder")
                }
            }
            Divider()
            Button("Choose Folder…") { model.chooseOutputFolder() }
        } label: {
            Label(title(for: current), systemImage: icon(for: current))
        }
        .fixedSize()
        .help(helpText(for: current))
    }

    private func title(for folder: URL??) -> String {
        switch folder {
        case .none: return "Mixed"
        case .some(.none): return "Next to Original"
        case .some(.some(let url)): return url.lastPathComponent
        }
    }

    private func icon(for folder: URL??) -> String {
        if case .some(.some) = folder { return "folder" }
        return "arrow.turn.down.right"
    }

    private func helpText(for folder: URL??) -> String {
        switch folder {
        case .none: return "The selected videos are saved to different places."
        case .some(.none): return "Saved in the same folder as each original video."
        case .some(.some(let url)): return url.path
        }
    }
}

/// Language filters that work across every selected file.
struct TrackFilters: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let audio = model.languages(of: .audio)
        let subs = model.languages(of: .subtitle)
        if audio.count > 1 || !subs.isEmpty {
            HStack {
                if audio.count > 1 {
                    Menu("Audio language") {
                        Button("Keep all") { model.keepOnly(.audio, language: "*") }
                        Divider()
                        ForEach(audio, id: \.self) { lang in
                            Button("Only \(lang)") { model.keepOnly(.audio, language: lang) }
                        }
                    }
                }
                if !subs.isEmpty {
                    Menu("Subtitles") {
                        Button("Keep all") { model.keepOnly(.subtitle, language: "*") }
                        Button("Remove all") { model.keepOnly(.subtitle, language: nil) }
                        Divider()
                        ForEach(subs, id: \.self) { lang in
                            Button("Only \(lang)") { model.keepOnly(.subtitle, language: lang) }
                        }
                    }
                }
                Spacer()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TrackList: View {
    @EnvironmentObject private var model: AppModel
    let job: Job
    let info: MediaInfo

    var body: some View {
        PanelSection(title: "Tracks to keep", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                group("Video", info.videoStreams)
                group("Audio", info.audioStreams)
                group("Subtitles", info.subtitleStreams)
                if info.attachmentCount > 0 {
                    Text("\(info.attachmentCount) attachment(s) (fonts): kept automatically in MKV when subtitles are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func group(_ title: String, _ streams: [MediaStream]) -> some View {
        if !streams.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("All") { model.setStreams(streams.map(\.index), on: true, in: job.id) }
                    Button("None") { model.setStreams(streams.map(\.index), on: false, in: job.id) }
                }
                .buttonStyle(.link)
                ForEach(streams) { stream in
                    Toggle(isOn: Binding(get: { job.selection.contains(stream.index) },
                                         set: { model.setStream(stream.index, on: $0, in: job.id) })) {
                        HStack(spacing: 6) {
                            Text("#\(stream.index)").monospacedDigit().foregroundStyle(.secondary)
                            Text(stream.label).lineLimit(1).truncationMode(.tail)
                            if stream.isImageSubtitle && job.settings.container != .mkv {
                                Text("not possible in \(job.settings.container.displayName)")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}

/// The headline number: what these settings do to the file size.
struct EstimateHero: View {
    @EnvironmentObject private var model: AppModel
    let jobs: [Job]

    var body: some View {
        let source = jobs.compactMap { $0.info?.fileSize }.reduce(0, +)
        let outputs = jobs.compactMap(\.expectedOutputBytes)
        let known = outputs.count == jobs.count
        let total = outputs.reduce(0, +)
        let grew = total > source
        let computing = jobs.contains { $0.estimate == .computing }
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
                    Text(known ? "≈ \(Format.bytes(total))" : "?")
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
            SizeMeter(source: source, output: known ? total : nil, approximate: true, computing: computing)
            HStack(alignment: .top) {
                Text(known ? "Bitrate and size modes are calculated. Quality mode is extrapolated from a 20-second sample (about ±15%)."
                           : "Quality mode has no fixed size. Estimate encodes a short sample to find out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { model.estimateSelected() } label: {
                    Label("Estimate", systemImage: "gauge.with.dots.needle.33percent")
                }
                .disabled(computing || model.ffmpegURL == nil)
                .help("Encodes 20 seconds from the middle of each video with these settings and scales the size up.")
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CommandBox: View {
    let command: EncodeCommand

    var body: some View {
        DisclosureGroup("ffmpeg command") {
            VStack(alignment: .trailing, spacing: 6) {
                Text(command.shellString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command.shellString, forType: .string)
                }
            }
        }
    }
}
