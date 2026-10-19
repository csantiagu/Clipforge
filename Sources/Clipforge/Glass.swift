import SwiftUI

// Liquid Glass exists only in the macOS 26 SDK (Xcode 26, Swift 6.2) and only runs on macOS 26.
// Everything here checks both, so the app still builds with older tools and still runs on
// macOS 13–15, where the same views fall back to frosted material.

/// A floating surface: Liquid Glass on macOS 26, frosted material before that.
/// Use it only on things that sit directly on the background, never glass on glass.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            fallback(content, shape)
        }
        #else
        fallback(content, shape)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif

    private func fallback(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.25)) }
                }
            }
            .overlay { shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1) }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 18, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }

    /// Glass button on macOS 26, bordered before that.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            legacyButton(prominent: prominent)
        }
        #else
        legacyButton(prominent: prominent)
        #endif
    }

    @ViewBuilder private func legacyButton(prominent: Bool) -> some View {
        if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}

/// Fades scrolling content out over the last few points at the top and bottom, so it
/// disappears softly at the edge of a panel instead of being cut off.
struct ScrollEdgeFade: ViewModifier {
    var top: CGFloat = 14
    var bottom: CGFloat = 14

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: top)
                Rectangle().fill(Color.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottom)
            }
        }
    }
}

extension View {
    func scrollEdgeFade(top: CGFloat = 14, bottom: CGFloat = 14) -> some View {
        modifier(ScrollEdgeFade(top: top, bottom: bottom))
    }
}

/// Lets neighbouring glass shapes blend into each other on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Slowly drifting colour field behind the glass. Shifts to teal/green while encoding.
/// Static when Reduce Motion is on.
struct AuroraBackground: View {
    var energized: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let calm: [Color] = [
        Color(red: 0.16, green: 0.13, blue: 0.45), Color(red: 0.33, green: 0.18, blue: 0.62), Color(red: 0.10, green: 0.30, blue: 0.66),
        Color(red: 0.52, green: 0.22, blue: 0.58), Color(red: 0.24, green: 0.27, blue: 0.72), Color(red: 0.08, green: 0.45, blue: 0.72),
        Color(red: 0.82, green: 0.34, blue: 0.48), Color(red: 0.42, green: 0.28, blue: 0.78), Color(red: 0.12, green: 0.56, blue: 0.68),
    ]
    private static let busy: [Color] = [
        Color(red: 0.04, green: 0.25, blue: 0.35), Color(red: 0.05, green: 0.42, blue: 0.45), Color(red: 0.10, green: 0.30, blue: 0.55),
        Color(red: 0.10, green: 0.55, blue: 0.45), Color(red: 0.08, green: 0.40, blue: 0.60), Color(red: 0.20, green: 0.62, blue: 0.50),
        Color(red: 0.30, green: 0.70, blue: 0.45), Color(red: 0.06, green: 0.50, blue: 0.62), Color(red: 0.45, green: 0.75, blue: 0.40),
    ]

    private var palette: [Color] { energized ? Self.busy : Self.calm }

    var body: some View {
        content
            .overlay(colorScheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.12))
            .animation(.easeInOut(duration: 1.5), value: energized)
            .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            if reduceMotion {
                mesh(time: 0)
            } else {
                // 15 fps is plenty for a drift this slow and keeps the GPU mostly idle during encodes.
                TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
                    mesh(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        } else {
            linear
        }
        #else
        linear
        #endif
    }

    private var linear: some View {
        LinearGradient(colors: [palette[0], palette[4], palette[8]], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    #if compiler(>=6.0)
    @available(macOS 15.0, *)
    private func mesh(time: Double) -> some View {
        let t = time.truncatingRemainder(dividingBy: 100_000)
        func drift(_ phase: Double, _ amount: Double = 0.09) -> Float {
            Float(sin(t * 0.22 + phase) * amount)
        }
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5 + drift(0), 0], [1, 0],
            [0, 0.5 + drift(1.3)], [0.5 + drift(2.1), 0.5 + drift(0.7)], [1, 0.5 + drift(2.9)],
            [0, 1], [0.5 + drift(3.7), 1], [1, 1],
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: palette)
    }
    #endif
}
