import SwiftUI

/// Smooth reveal of streamed text, after AstraFlow's `useSmoothStreamedText`: text already
/// received is shown at an adaptive speed that eases towards "drain the backlog in 0.16 s"
/// (capped at 2000 chars/s), never more than 0.25 s behind, and sleeps when caught up.
/// Providers flush in bursts; this turns the bursts into a steady flow.
@MainActor
final class StreamReveal: ObservableObject {
    static let drainWindow = 0.16
    static let maxCharsPerSecond = 2000.0
    static let maxBacklog = maxCharsPerSecond * 0.25
    static let maxFrame = 0.05

    @Published private(set) var shown = ""
    private var target: [Character] = []
    private var targetString = ""
    private var position = 0.0
    private var velocity = 0.0
    private var emitted = 0
    private var ticker: Task<Void, Never>?

    /// New provider text. Append-only updates animate; anything else snaps.
    func update(_ text: String, animate: Bool) {
        guard animate, text.hasPrefix(targetString) else {
            snap(text)
            return
        }
        guard text.count != target.count else { return }
        targetString = text
        target = Array(text)
        if ticker == nil { run() }
    }

    func snap(_ text: String) {
        ticker?.cancel()
        ticker = nil
        targetString = text
        target = Array(text)
        position = Double(target.count)
        emitted = target.count
        velocity = 0
        shown = text
    }

    private func run() {
        ticker = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self else { return }
                let now = ContinuousClock.now
                let dt = min(Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds), Self.maxFrame)
                last = now
                if !self.step(dt) { self.ticker = nil; return }
            }
        }
    }

    /// One frame; false once caught up.
    private func step(_ dt: Double) -> Bool {
        let length = Double(target.count)
        let backlog = length - position
        guard backlog > 0 else { velocity = 0; return false }
        let targetVelocity = min(Self.maxCharsPerSecond, backlog / Self.drainWindow)
        // AstraFlow eases 15% per 60 Hz frame; scale that to the real frame time.
        let ease = 1 - pow(0.85, dt * 60)
        velocity += (targetVelocity - velocity) * ease
        position = min(length, max(position + velocity * dt, length - Self.maxBacklog))
        let n = Int(position)
        if n != emitted {
            emitted = n
            shown = n >= target.count ? targetString : String(target[..<n])
        }
        return position < length
    }
}

/// Markdown that reveals smoothly while `streaming`, and shows the exact text otherwise.
struct StreamingMarkdown: View {
    let text: String
    var compact: Bool
    @StateObject private var reveal = StreamReveal()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MarkdownText(reveal.shown, compact: compact, streaming: true)
            .onAppear { reveal.update(text, animate: !reduceMotion) }
            .onChange(of: text) { _, new in reveal.update(new, animate: !reduceMotion) }
    }
}
