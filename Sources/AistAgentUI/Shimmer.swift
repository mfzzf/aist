import SwiftUI

/// Secondary text with a highlight sweeping across it — "something is happening" without a spinner.
/// Static under Reduce Motion.
public struct ShimmerText: View {
    let text: String
    var font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String, font: Font = .callout) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        if reduceMotion {
            Text(text).font(font).foregroundStyle(.secondary)
        } else {
            TimelineView(.animation) { ctx in
                let period = 1.8
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let center = -0.3 + 1.6 * t
                Text(text)
                    .font(font)
                    .foregroundStyle(LinearGradient(
                        stops: [
                            .init(color: .secondary.opacity(0.55), location: center - 0.25),
                            .init(color: .primary, location: center),
                            .init(color: .secondary.opacity(0.55), location: center + 0.25),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    ))
            }
        }
    }
}

/// A row of three dots pulsing in turn, for the moment before the first token.
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * max(0, sin((t * 4) - Double(i) * 0.7)))
                }
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("正在回答")
    }
}
