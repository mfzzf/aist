import Foundation

/// The energy of one audio track over time: `bands` values (power, lowest band first) for every
/// `hop` seconds. What `EchoMeter` works on; computed from audio in AistAudio.
public struct BandFrames: Sendable, Equatable {
    public var hop: Double
    public var bands: Int
    /// `count` × `bands`, frame after frame.
    public var values: [Float]

    public init(hop: Double = 0.01, bands: Int, values: [Float] = []) {
        self.hop = hop
        self.bands = bands
        self.values = values
    }

    public var count: Int { bands > 0 ? values.count / bands : 0 }
    public var duration: Double { Double(count) * hop }
    /// Nothing audible anywhere on the track.
    public var isSilent: Bool { !values.contains { $0 > 1e-9 } }

    /// The same track starting `seconds` later, with silence in front.
    public func delayed(by seconds: Double) -> BandFrames {
        let pad = max(0, Int((seconds / hop).rounded()))
        guard pad > 0 else { return self }
        return BandFrames(hop: hop, bands: bands, values: [Float](repeating: 0, count: pad * bands) + values)
    }
}

/// Tells how much of what the microphone picked up was the other side coming out of the speakers,
/// from the energy of the two tracks alone.
///
/// The echo is the system track again, later (speaker → room → microphone, and the two devices'
/// buffers) and quieter, by an amount that depends on the pitch. Both are measured here: the delay
/// by sliding one track's loudness over the other's (window by window: it jumps when a track loses
/// audio while recording), the loss as the ratio the microphone keeps returning to while the other
/// side talks (the user talking over them only adds energy). With that,
/// every moment of the microphone track is the echo alone, the user alone, or the user over the
/// other side. On headphones no delay is found, or the loss is total, and nothing counts as echo.
public enum EchoMeter {
    public struct Settings: Sendable {
        /// Seconds of audio one delay and loss estimate is made from; estimates overlap by half.
        public var window = 15.0
        /// The delays tried, in seconds. In the room the echo trails by a tenth of a second or so, but
        /// the two files don't keep one clock: a track that lost a stretch of audio while recording
        /// runs ahead of the other from there on, by seconds over a long meeting, in either direction.
        public var minLag = -5.0
        public var maxLag = 5.0
        /// How far, in seconds, the delay is looked for around the last one found before the whole
        /// range is tried again.
        public var track = 0.3
        /// How well the two loudness curves must agree before a delay is believed: near the last one
        /// found, and anywhere in the whole range (where chance has many more tries).
        public var minCorrelation: Float = 0.35
        public var minCorrelationAnywhere: Float = 0.5
        /// An echo path weaker than this (a ratio of power) is no echo: nothing audible gets through.
        public var minLeak: Float = 1e-4
        /// Where in the spread of microphone-to-system ratios the echo alone sits: below the middle,
        /// since the user talking over the other side pushes ratios up, never down.
        public var gainQuantile = 0.3
        /// Ratio samples a band needs for its own estimate in a window.
        public var minGainFrames = 30
        /// How fast the room lets a sound die: what is left of its power after one frame.
        public var decay: Float = 0.7
        /// The microphone holding up to this many times the predicted echo is the echo.
        public var echoExcess: Float = 2.5
        /// From this many times on, the user is talking too.
        public var nearExcess: Float = 6
        /// How far over its quietest the microphone must be to count as someone speaking.
        public var voiceOverNoise: Float = 6

        public init() {}
    }

    /// What one moment of the microphone track holds.
    public enum Frame: UInt8, Sendable {
        /// Nobody audible.
        case silent
        /// The other side through the speakers, nothing else.
        case echo
        /// More than the echo should be, not clearly the user.
        case unsure
        /// The user talking while the other side plays.
        case both
        /// The user, with the other side quiet.
        case mine
    }

    /// One estimate of the delay, from `window` seconds of audio.
    public struct Window: Sendable {
        /// Seconds into the recording.
        public var start: Double
        /// Seconds the echo trails the system track.
        public var delay: Double
        /// How well the tracks' loudness agreed at that delay (1 = identical shape).
        public var correlation: Float
        /// false: too little to go on here, `delay` is borrowed from the nearest window that had enough.
        public var measured: Bool
    }

    /// How a stretch of the microphone track divides up.
    public struct Share: Sendable {
        /// Seconds with someone audible.
        public var voiced: Double
        /// Parts of `voiced`, adding up to 1 (all 0 when nothing was audible).
        public var echo: Double
        public var unsure: Double
        public var both: Double
        public var mine: Double
        /// The user speaking, alone or over the other side.
        public var near: Double { both + mine }
    }

    public struct Profile: Sendable {
        public var hop: Double
        /// One per microphone frame.
        public var frames: [Frame]
        public var windows: [Window] = []
        /// How much of the system track's power reaches the microphone, band by band (0…: a ratio).
        public var gain: [Float] = []
        /// The same over all bands. 0: no echo found.
        public var leak: Float = 0

        public init(hop: Double, frames: [Frame], windows: [Window] = [], gain: [Float] = [], leak: Float = 0) {
            self.hop = hop
            self.frames = frames
            self.windows = windows
            self.gain = gain
            self.leak = leak
        }

        /// A delay was found somewhere: the microphone does hear the speakers.
        public var hasEcho: Bool { leak > 0 }

        public func share(from start: Double, to end: Double) -> Share {
            let a = max(0, Int((start / hop).rounded(.down)))
            let b = min(frames.count, Int((end / hop).rounded(.up)))
            var counts = [Int](repeating: 0, count: 5)
            if a < b { for i in a ..< b { counts[Int(frames[i].rawValue)] += 1 } }
            let voiced = counts[1] + counts[2] + counts[3] + counts[4]
            guard voiced > 0 else { return Share(voiced: 0, echo: 0, unsure: 0, both: 0, mine: 0) }
            let v = Double(voiced)
            return Share(voiced: v * hop, echo: Double(counts[1]) / v, unsure: Double(counts[2]) / v,
                         both: Double(counts[3]) / v, mine: Double(counts[4]) / v)
        }
    }

    /// `system` and `mic` on one timeline (see `BandFrames.delayed(by:)` for a track that started late).
    public static func analyze(system: BandFrames, mic: BandFrames, settings: Settings = Settings()) -> Profile {
        let n = mic.count
        let bands = min(system.bands, mic.bands)
        var profile = Profile(hop: mic.hop, frames: [Frame](repeating: .silent, count: n))
        guard n > 0, bands > 0, system.bands == mic.bands, abs(system.hop - mic.hop) < 1e-9 else { return profile }
        let ns = system.count

        // Loudness of each frame, all bands together. The tracks needn't be the same length: the
        // system one is kept whole (an echo that comes early is looked up past the microphone's end)
        // and reads as silence where the microphone outlasts it.
        var s = [Float](repeating: 0, count: max(n, ns))
        var m = [Float](repeating: 0, count: n)
        for i in 0 ..< ns {
            var sum: Float = 0
            for b in 0 ..< bands { sum += system.values[i * bands + b] }
            s[i] = sum
        }
        for i in 0 ..< n {
            var sum: Float = 0
            for b in 0 ..< bands { sum += mic.values[i * bands + b] }
            m[i] = sum
        }
        // The system track is silent or playing; the microphone always hears the room.
        let sysOn = max(1e-12, quantile(s.filter { $0 > 0 }, 0.95) * 1e-4)
        let noise = max(1e-12, quantile(m.filter { $0 > 0 }, 0.05))
        let micOn = noise * settings.voiceOverNoise
        let smoothM = smoothed(m)

        func withoutEcho() -> Profile {
            for i in 0 ..< n where smoothM[i] > micOn { profile.frames[i] = .mine }
            return profile
        }
        guard s.contains(where: { $0 > sysOn }) else { return withoutEcho() }

        // MARK: Delay, window by window

        // Loudness in dB over the floor, 0 when quiet, so silence on both tracks doesn't count as agreement.
        let es = s.map { $0 > sysOn ? log10($0 / sysOn) : 0 }
        let em = m.map { $0 > noise ? log10($0 / noise) : 0 }
        let w = max(1, Int((settings.window / mic.hop).rounded()))
        let step = max(1, w / 2)
        let minLag = Int((settings.minLag / mic.hop).rounded())
        let maxLag = max(minLag, Int((settings.maxLag / mic.hop).rounded()))
        let track = max(1, Int((settings.track / mic.hop).rounded()))
        // The same curves at a fifth of the detail, to try the whole range cheaply.
        let coarse = 5
        let esCoarse = averaged(es, by: coarse)
        let emCoarse = averaged(em, by: coarse)
        func best(_ x: [Float], _ y: [Float], from: Int, to: Int, lags: ClosedRange<Int>) -> (lag: Int, score: Float) {
            var best: (lag: Int, score: Float) = (lags.lowerBound, -1)
            for lag in lags {
                let score = correlation(x, y, from: from, to: to, lag: lag)
                if score > best.score { best = (lag, score) }
            }
            return best
        }
        var starts: [Int] = []
        var a = 0
        repeat {
            starts.append(a)
            a += step
        } while a + step < n
        var delays: [Int?] = []
        var scores: [Float] = []
        var last: Int?
        for a in starts {
            let b = min(n, a + w)
            var active = 0
            for i in a ..< b where s[i] > sysOn { active += 1 }
            guard active * 10 >= b - a else {
                delays.append(nil)
                scores.append(0)
                continue
            }
            var found: Int?
            var score: Float = 0
            // Where it was a moment ago, give or take.
            if let last {
                let near = best(es, em, from: a, to: b, lags: max(minLag, last - track) ... min(maxLag, last + track))
                score = near.score
                if near.score >= settings.minCorrelation { found = near.lag }
            }
            // Not there (or the first time): anywhere, roughly, then to the frame around the best.
            if found == nil {
                let rough = best(esCoarse, emCoarse, from: a / coarse, to: b / coarse, lags: minLag / coarse ... maxLag / coarse)
                let center = rough.lag * coarse
                let lower = min(maxLag, max(minLag, center - coarse - 1))
                let exact = best(es, em, from: a, to: b, lags: lower ... max(lower, min(maxLag, center + coarse + 1)))
                score = max(score, exact.score)
                if exact.score >= settings.minCorrelationAnywhere { found = exact.lag }
            }
            if let found { last = found }
            delays.append(found)
            scores.append(max(0, score))
        }
        let measured = delays.map { $0 != nil }
        guard measured.contains(true) else { return withoutEcho() }
        // Windows with too little to go on borrow from the nearest one that had enough.
        var filled = delays.indices.map { k -> Int in
            if let d = delays[k] { return d }
            let near = delays.indices.filter { delays[$0] != nil }.min { abs($0 - k) < abs($1 - k) }!
            return delays[near]!
        }
        // One odd window between two that agree is a mismeasurement.
        if filled.count >= 3 {
            let raw = filled
            for k in 1 ..< raw.count - 1 { filled[k] = [raw[k - 1], raw[k], raw[k + 1]].sorted()[1] }
        }
        profile.windows = starts.indices.map {
            Window(start: Double(starts[$0]) * mic.hop, delay: Double(filled[$0]) * mic.hop,
                   correlation: scores[$0], measured: measured[$0])
        }

        // MARK: Loss, band by band

        // Per window: the ratio the microphone keeps coming back to while the other side is clearly
        // audible. Index `bands` is all bands together.
        var gains = [[Float?]](repeating: [Float?](repeating: nil, count: bands + 1), count: starts.count)
        for (k, a) in starts.enumerated() {
            let b = min(n, a + w)
            let d = filled[k]
            var ratios = [[Float]](repeating: [], count: bands + 1)
            for i in a ..< b where m[i] > micOn {
                let j = i - d
                guard j >= 0, j < ns, s[j] > sysOn * 10 else { continue }
                ratios[bands].append(m[i] / s[j])
                for band in 0 ..< bands {
                    let from = system.values[j * bands + band]
                    // A band with next to none of the sound in it says nothing about the echo.
                    if from > s[j] * 0.01 { ratios[band].append(mic.values[i * bands + band] / from) }
                }
            }
            for band in 0 ... bands where ratios[band].count >= settings.minGainFrames {
                gains[k][band] = quantile(ratios[band], settings.gainQuantile)
            }
        }
        // The user talking over the other side for most of a window lifts its estimate; the echo
        // itself doesn't get several times louder from one window to the next. Hold each window to
        // twice what its neighbours measured (a real change of volume shows in them soon enough).
        let raw = gains
        for k in gains.indices {
            for band in 0 ... bands {
                guard let g = raw[k][band] else { continue }
                let around = (max(0, k - 2) ... min(gains.count - 1, k + 2)).compactMap { raw[$0][band] }
                gains[k][band] = min(g, 2 * quantile(around, 0.5))
            }
        }
        // A window short of samples takes the recording's usual value.
        let usual = (0 ... bands).map { band in quantile(gains.compactMap { $0[band] }, 0.5) }
        profile.gain = Array(usual[0 ..< bands])
        profile.leak = usual[bands]
        guard profile.leak >= settings.minLeak else {
            profile.leak = 0
            return withoutEcho()
        }

        // MARK: Frame by frame

        // What the echo should measure now: the system track `delay` ago through the loss, dying
        // away as a room lets it.
        var predicted = [Float](repeating: 0, count: n)
        var playing = [Float](repeating: 0, count: n)
        var held = [Float](repeating: 0, count: bands)
        for i in 0 ..< n {
            let k = min(i / step, starts.count - 1)
            let d = filled[k]
            var echo: Float = 0
            var total: Float = 0
            for band in 0 ..< bands {
                var from: Float = 0
                // A frame either way: the delay is only known to the frame.
                for j in (i - d - 1) ... (i - d + 1) where j >= 0 && j < ns {
                    from = max(from, system.values[j * bands + band])
                }
                held[band] = max(from, held[band] * settings.decay)
                total += held[band]
                echo += (gains[k][band] ?? usual[band]) * held[band]
            }
            predicted[i] = echo
            playing[i] = total
        }
        let smoothP = smoothed(predicted)
        for i in 0 ..< n {
            guard smoothM[i] > micOn else { continue }
            if playing[i] <= sysOn {
                profile.frames[i] = .mine
                continue
            }
            let excess = smoothM[i] / max(smoothP[i], 1e-20)
            profile.frames[i] = excess <= settings.echoExcess ? .echo : (excess >= settings.nearExcess ? .both : .unsure)
        }
        return profile
    }

    // MARK: Helpers

    /// How alike `x[from..<to]` and `y` shifted `lag` frames later are in shape: −1…1.
    static func correlation(_ x: [Float], _ y: [Float], from: Int, to: Int, lag: Int) -> Float {
        let a = max(from, -lag)
        let b = min(to, y.count - lag)
        guard b - a >= 10 else { return -1 }
        var sx: Float = 0, sy: Float = 0
        for i in a ..< b {
            sx += x[i]
            sy += y[i + lag]
        }
        let mx = sx / Float(b - a), my = sy / Float(b - a)
        var xy: Float = 0, xx: Float = 0, yy: Float = 0
        for i in a ..< b {
            let dx = x[i] - mx, dy = y[i + lag] - my
            xy += dx * dy
            xx += dx * dx
            yy += dy * dy
        }
        guard xx > 0, yy > 0 else { return -1 }
        return xy / (xx * yy).squareRoot()
    }

    /// Every `by` values averaged into one (a last, shorter group included).
    static func averaged(_ x: [Float], by: Int) -> [Float] {
        stride(from: 0, to: x.count, by: by).map { a in
            let b = min(x.count, a + by)
            var sum: Float = 0
            for i in a ..< b { sum += x[i] }
            return sum / Float(b - a)
        }
    }

    /// The value `q` of the way up the sorted values (0 for none).
    static func quantile(_ values: [Float], _ q: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))]
    }

    /// Each value averaged with its two neighbours on either side: single frames are too jumpy to judge.
    static func smoothed(_ x: [Float]) -> [Float] {
        guard x.count > 4 else { return x }
        var out = x
        for i in x.indices {
            let a = max(0, i - 2), b = min(x.count - 1, i + 2)
            var sum: Float = 0
            for j in a ... b { sum += x[j] }
            out[i] = sum / Float(b - a + 1)
        }
        return out
    }
}
