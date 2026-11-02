import SwiftUI

enum AistBrand {
    static let blue = Color(red: 0.25, green: 0.62, blue: 0.97)
    static let violet = Color(red: 0.58, green: 0.47, blue: 0.96)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension View {
    /// Liquid Glass on iOS 26+; before that, the system's frosted material with a hairline edge,
    /// which is what glass looked like on those versions.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *), !Demo.noGlass {
            glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.85)) }
                }
                .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
            }
            .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
    }

    @available(iOS 26.0, *)
    private static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// Lets neighbouring glass shapes melt into each other while they move (iOS 26+).
    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// Groups glass shapes so they blend and morph together on iOS 26+; a plain container before.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Launch arguments for screenshots: `-demoListening` shows the listening panel with sample text,
/// `-noGlass` forces the pre-iOS 26 look.
enum Demo {
    static let listening = ProcessInfo.processInfo.arguments.contains("-demoListening")
    static let noGlass = ProcessInfo.processInfo.arguments.contains("-noGlass")
}

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
