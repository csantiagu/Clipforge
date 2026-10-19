import AppKit
import SwiftUI
import ClipforgeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AuroraBackground(energized: model.isRunning)
            HStack(alignment: .top, spacing: 16) {
                QueueColumn()
                    .frame(minWidth: 440, maxWidth: .infinity)
                if !model.jobs.isEmpty {
                    DetailPanel()
                        .frame(width: 440)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.jobs.isEmpty)
        .overlay(alignment: .top) {
            if model.ffmpegURL == nil || model.ffprobeURL == nil {
                Label("ffmpeg/ffprobe not found. Build the app with ./build.sh (it bundles ffmpeg), or run `brew install ffmpeg`.",
                      systemImage: "exclamationmark.triangle.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(cornerRadius: 14, tint: .red)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Queue

struct QueueColumn: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            QueueHeader()
            if model.jobs.isEmpty {
                DropHero(targeted: dropTargeted)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.jobs) { job in
                            JobCard(job: job,
                                    isSelected: model.selection.contains(job.id),
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
            if !model.jobs.isEmpty { Dock() }
        }
        .overlay {
            if dropTargeted && !model.jobs.isEmpty {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private func menu(for job: Job) -> some View {
        let ids = model.selection.contains(job.id) ? model.selection : [job.id]
        if case .done(let url, _) = job.status {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Button("Encode Again") { model.requeue(ids) }
        Divider()
        Button("Remove") { model.remove(ids) }
    }
}

struct QueueHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center) {
            Text("Clipforge")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            Spacer()
            if !model.jobs.isEmpty {
                Text(totals)
                    .font(.callout.weight(.medium))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassSurface(cornerRadius: 14)
            }
        }
        .padding(.horizontal, 4)
    }

    private var totals: String {
        let count = model.jobs.count
        let source = model.jobs.compactMap { $0.info?.fileSize }.reduce(0, +)
        var text = "\(count) video\(count == 1 ? "" : "s") · \(Format.bytes(source))"
        let outputs = model.jobs.compactMap(\.expectedOutputBytes)
        if outputs.count == count, source > 0 {
            text += "  →  ≈ \(Format.bytes(outputs.reduce(0, +)))"
        }
        return text
    }
}

struct DropHero: View {
    @EnvironmentObject private var model: AppModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 20) {
            Color.clear
                .frame(width: 168, height: 168)
                .glassSurface(cornerRadius: 84, tint: targeted ? Color.white.opacity(0.3) : nil)
                .overlay {
                    Image(systemName: targeted ? "arrow.down.circle" : "film.stack")
                        .font(.system(size: 60, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .scaleEffect(targeted ? 1.08 : 1)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: targeted)
            VStack(spacing: 6) {
                Text(targeted ? "Let go to add" : "Drop videos here")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("MKV, MP4, MOV, AVI, phone videos, anything ffmpeg reads")
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            Button { model.showOpenPanel() } label: {
                Label("Choose Videos…", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .glassButton(prominent: true)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card

struct JobCard: View {
    let job: Job
    let isSelected: Bool
    let thumbnail: NSImage?

    private var progress: Double? {
        if case .running(let fraction, _) = job.status { return fraction }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Thumbnail(image: thumbnail, duration: job.info?.duration, status: job.status)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.input.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    StatusPill(status: job.status)
                }
                if let info = job.info { ChipRow(info: info) }
                detail
            }
        }
        .padding(12)
        .background {
            // Progress fills the card from the left while encoding.
            GeometryReader { geo in
                Rectangle()
                    .fill(LinearGradient(colors: [Color.green.opacity(0.10), Color.green.opacity(0.28)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * (progress ?? 0))
                    .animation(.linear(duration: 0.6), value: progress)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .glassSurface(cornerRadius: 20, tint: isSelected ? Color.accentColor.opacity(0.45) : nil, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder private var detail: some View {
        switch job.status {
        case .probing:
            Text("Reading file…").font(.caption).foregroundStyle(.secondary)
        case .unreadable(let message), .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(message)
        case .running(let fraction, let speed):
            Text(Format.progress(fraction: fraction, speed: speed, duration: job.info?.duration ?? 0))
                .font(.caption.weight(.medium))
                .fontDesign(.rounded)
                .monospacedDigit()
            outputLine
        case .done(let url, let bytes):
            SizeMeter(source: job.info?.fileSize ?? 0, output: bytes, approximate: false)
            HStack {
                outputLine
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .ready, .cancelled:
            SizeMeter(source: job.info?.fileSize ?? 0, output: job.expectedOutputBytes,
                      approximate: true, computing: job.estimate == .computing)
            outputLine
        }
    }

    /// Where the output goes. The folder is shown whenever it isn't next to the original.
    @ViewBuilder private var outputLine: some View {
        if let output = job.plannedOutput {
            if let folder = job.outputFolder {
                Label("\(folder.lastPathComponent) / \(output.lastPathComponent)", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(output.path)
            } else {
                Label(output.lastPathComponent, systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(output.path)
            }
        }
    }
}

struct Thumbnail: View {
    let image: NSImage?
    let duration: Double?
    let status: JobStatus

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "film")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
            }
            if case .done = status {
                Color.black.opacity(0.35)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let duration, duration > 0 {
                Text(Format.duration(duration))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(5)
            }
        }
    }
}

struct ChipRow: View {
    let info: MediaInfo

    var body: some View {
        HStack(spacing: 5) {
            if let video = info.videoStreams.first {
                Chip(text: video.codec.uppercased())
                if let height = video.height { Chip(text: Self.resolutionName(height)) }
                if video.isHDR { Chip(text: "HDR", color: .orange) }
            }
            if !info.audioStreams.isEmpty {
                Chip(text: "\(info.audioStreams.count) audio", systemImage: "speaker.wave.2")
            }
            if !info.subtitleStreams.isEmpty {
                Chip(text: "\(info.subtitleStreams.count) subs", systemImage: "captions.bubble")
            }
        }
    }

    static func resolutionName(_ height: Int) -> String {
        switch height {
        case 2000...: return "4K"
        case 1300..<2000: return "1440p"
        case 1000..<1300: return "1080p"
        case 650..<1000: return "720p"
        default: return "\(height)p"
        }
    }
}

struct Chip: View {
    let text: String
    var systemImage: String?
    var color: Color = .primary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct StatusPill: View {
    let status: JobStatus

    var body: some View {
        let style = Self.style(status)
        Text(style.text)
            .font(.caption.weight(.semibold))
            .fontDesign(.rounded)
            .monospacedDigit()
            .foregroundStyle(style.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(style.color.opacity(0.16), in: Capsule())
    }

    static func style(_ status: JobStatus) -> (text: String, color: Color) {
        switch status {
        case .probing: return ("Reading", Color.secondary)
        case .unreadable: return ("Can't read", .red)
        case .ready: return ("Ready", .blue)
        case .running(let fraction, _): return ("\(Int(fraction * 100))%", .green)
        case .done: return ("Done", .green)
        case .failed: return ("Failed", .red)
        case .cancelled: return ("Stopped", .orange)
        }
    }
}

/// Source size against output size, so the effect of the settings is visible at a glance.
struct SizeMeter: View {
    let source: Int64
    let output: Int64?
    var approximate = true
    var computing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    if let ratio {
                        Capsule()
                            .fill(LinearGradient(colors: grew ? [.orange, .red] : [.teal, .green],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geo.size.width * min(ratio, 1)))
                    }
                }
            }
            .frame(height: 6)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: ratio)
            HStack(spacing: 5) {
                Text(Format.bytes(source)).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                if let output {
                    Text("\(approximate ? "≈ " : "")\(Format.bytes(output))").fontWeight(.semibold)
                    Text(Format.change(from: source, to: output).trimmingCharacters(in: .whitespaces))
                        .fontWeight(.semibold)
                        .foregroundStyle(grew ? Color.orange : Color.green)
                } else if computing {
                    ProgressView().controlSize(.mini)
                    Text("estimating").foregroundStyle(.secondary)
                } else {
                    Text("size depends on the video · Estimate").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fontDesign(.rounded)
            .monospacedDigit()
        }
    }

    private var ratio: Double? {
        guard let output, source > 0 else { return nil }
        return Double(output) / Double(source)
    }

    private var grew: Bool { (ratio ?? 0) > 1 }
}

// MARK: - Dock

struct Dock: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 4) {
                Button { model.showOpenPanel() } label: { Label("Add", systemImage: "plus") }
                    .help("Add videos (⌘O)")
                Button { model.remove(model.selection) } label: { Label("Remove", systemImage: "trash") }
                    .disabled(model.selection.isEmpty)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Remove selected (⌘⌫)")
                if model.jobs.contains(where: { if case .done = $0.status { return true } else { return false } }) {
                    Button { model.removeFinished() } label: { Label("Clear Done", systemImage: "checkmark.circle") }
                }
                Divider().frame(height: 22).padding(.horizontal, 6)
                if model.isRunning {
                    Button(role: .cancel) { model.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button { model.start() } label: {
                        Label(model.readyCount > 0 ? "Start \(model.readyCount)" : "Start", systemImage: "play.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.readyCount == 0 || model.ffmpegURL == nil)
                }
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

// MARK: - Formatting

extension Job {
    /// Final size when done, otherwise the estimate if there is one.
    var expectedOutputBytes: Int64? {
        if case .done(_, let bytes) = status { return bytes }
        if case .value(let bytes, _) = estimate { return bytes }
        return nil
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func change(from source: Int64?, to output: Int64) -> String {
        guard let source, source > 0 else { return "" }
        let percent = Int((Double(output) / Double(source) - 1) * 100)
        return " (\(percent >= 0 ? "+" : "")\(percent)%)"
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func progress(fraction: Double, speed: Double?, duration: Double) -> String {
        var text = "Encoding \(Int(fraction * 100))%"
        if let speed, speed > 0 {
            text += String(format: " · %.2f× speed", speed)
            let remaining = duration * (1 - fraction) / speed
            text += " · \(self.duration(remaining)) left"
        }
        return text
    }

    /// Rough size of one hour at a given bitrate. Used to give bitrate numbers a meaning.
    static func perHour(kbps: Int) -> String {
        bytes(Int64(Double(kbps) * 1000 / 8 * 3600))
    }
}
