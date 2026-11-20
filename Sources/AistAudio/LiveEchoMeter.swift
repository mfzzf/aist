import AistCore
import AVFoundation
import Foundation

/// `EchoMeter` while the meeting is still running: fed the capture's buffers from both sides, it
/// measures the last minute once a second and keeps, for the whole meeting so far, what each moment
/// of the microphone held. Safe to feed from the capture queue and read from anywhere.
public final class LiveEchoMeter: @unchecked Sendable {
    /// Seconds of audio one measurement looks back over, how often it is made, and how far behind
    /// the newest audio its answers are taken as settled.
    static let window = 60.0
    static let interval = 1.0
    static let margin = 0.3

    private struct Side {
        let analyzer: BandAnalyzer
        let rate: Double
        /// Frame (10 ms) of the meeting this side's first sample fell in.
        let startFrame: Int
        /// Seconds into the meeting of its first sample, and samples taken since (silence filled in).
        let start: Double
        var samples = 0
        /// Band energies not yet let go of, from frame `first` of this side.
        var values: [Float] = []
        var first = 0

        var bands: Int { analyzer.bands }
        /// Frames of the meeting this side has reached.
        var reached: Int { startFrame + first + values.count / bands }
    }

    private let lock = NSLock()
    private var sides: [TranscriptSegment.Speaker: Side] = [:]
    private var frames: [EchoMeter.Frame] = []
    private var leak: Float = 0
    private var analyzed = 0

    public init() {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        sides = [:]
        frames = []
        leak = 0
        analyzed = 0
    }

    /// What the microphone held, moment by moment, up to about now. `leak` stays 0 until an echo
    /// has been measured.
    public var profile: EchoMeter.Profile {
        lock.lock()
        defer { lock.unlock() }
        return EchoMeter.Profile(hop: BandAnalyzer.hop, frames: frames, leak: leak)
    }

    /// One capture buffer. `time`: seconds into the meeting of its first sample, on the capture's
    /// clock, so that a stretch the capture skipped stays a stretch of silence here.
    public func push(_ buffer: AVAudioPCMBuffer, speaker: TranscriptSegment.Speaker, at time: Double) {
        let mono = BandEnergies.mono(buffer)
        guard !mono.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if sides[speaker] == nil {
            let rate = buffer.format.sampleRate
            guard let analyzer = BandAnalyzer(sampleRate: rate) else { return }
            sides[speaker] = Side(analyzer: analyzer, rate: rate, startFrame: Int((max(0, time) / BandAnalyzer.hop).rounded()),
                                  start: max(0, time))
        }
        guard var side = sides[speaker] else { return }
        let gap = time - (side.start + Double(side.samples) / side.rate)
        if gap > 0.02 {
            let missing = Int(min(gap, 10) * side.rate)
            side.analyzer.push([Float](repeating: 0, count: missing))
            side.samples += missing
        }
        side.analyzer.push(mono)
        side.samples += mono.count
        side.values += side.analyzer.take()
        sides[speaker] = side
        measureIfDue()
    }

    private func measureIfDue() {
        guard let system = sides[.others], let mic = sides[.me] else { return }
        let hop = BandAnalyzer.hop
        let now = min(system.reached, mic.reached)
        guard now - analyzed >= Int(Self.interval / hop) else { return }
        analyzed = now
        let from = max(0, now - Int(Self.window / hop))
        let profile = EchoMeter.analyze(system: Self.slice(system, from: from, to: now), mic: Self.slice(mic, from: from, to: now))
        if profile.hasEcho { leak = profile.leak }
        // Everything up to a moment ago is settled; the newest frames wait for the next measurement.
        let settled = now - Int(Self.margin / hop)
        while frames.count < settled {
            let k = frames.count - from
            frames.append(k >= 0 && k < profile.frames.count ? profile.frames[k] : .silent)
        }
        // Keep only what the next measurement looks back over.
        for speaker in [TranscriptSegment.Speaker.others, .me] {
            guard var side = sides[speaker] else { continue }
            let drop = from - side.startFrame - side.first
            if drop > 0 {
                side.values.removeFirst(min(side.values.count, drop * side.bands))
                side.first += drop
                sides[speaker] = side
            }
        }
    }

    /// Frames `from..<to` of the meeting from one side, silent where it has nothing.
    private static func slice(_ side: Side, from: Int, to: Int) -> BandFrames {
        let bands = side.bands
        var values = [Float](repeating: 0, count: max(0, to - from) * bands)
        let have = side.values.count / bands
        for frame in from ..< max(from, to) {
            let i = frame - side.startFrame - side.first
            guard i >= 0, i < have else { continue }
            for b in 0 ..< bands { values[(frame - from) * bands + b] = side.values[i * bands + b] }
        }
        return BandFrames(hop: BandAnalyzer.hop, bands: bands, values: values)
    }
}
