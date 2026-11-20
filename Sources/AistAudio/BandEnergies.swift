import Accelerate
import AistCore
import AVFoundation
import Foundation

/// Turns audio into `BandFrames`: every 10 ms, the power in a handful of bands across the range a
/// voice lives in. Fed sample by sample (a live capture) or from a file.
public final class BandAnalyzer {
    public static let hop = 0.01
    public let bands: Int
    /// `bands` values per frame, frame after frame.
    public private(set) var values: [Float] = []

    private let step: Int
    private let length: Int
    private let size: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private let scale: Float
    /// First and one-past-last spectrum bin of each band.
    private let edges: [(Int, Int)]
    private var pending: [Float] = []
    private var padded: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var power: [Float]

    /// `low`…`high` in Hz: the bands divide that range evenly by ratio, as hearing does.
    public init?(sampleRate: Double, bands: Int = 8, low: Double = 300, high: Double = 4000) {
        let step = Int((sampleRate * Self.hop).rounded())
        guard step >= 8, bands > 0, low > 0, high > low, high <= sampleRate / 2 else { return nil }
        self.bands = bands
        self.step = step
        // Frames twice the hop, each overlapping the next by half.
        length = step * 2
        let log2n = vDSP_Length((log2(Double(length))).rounded(.up))
        size = 1 << log2n
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: length, isHalfWindow: false)
        // So a band reads the power of the sound in it, A²/2 for a tone of amplitude A, whatever the
        // frame size: the bins' squares add up to size · Σwindow² times that, and vDSP's real FFT
        // returns twice the transform (four times the squares), of which only one half is summed.
        let energy = window.reduce(0) { $0 + $1 * $1 }
        scale = 0.5 / (Float(1 << log2n) * energy)
        edges = (0 ..< bands).map { b in
            let from = low * pow(high / low, Double(b) / Double(bands))
            let to = low * pow(high / low, Double(b + 1) / Double(bands))
            let first = Int((from * Double(1 << log2n) / sampleRate).rounded())
            let last = max(first + 1, Int((to * Double(1 << log2n) / sampleRate).rounded()))
            return (first, min(last, (1 << log2n) / 2))
        }
        padded = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        outReal = [Float](repeating: 0, count: size / 2)
        outImag = [Float](repeating: 0, count: size / 2)
        power = [Float](repeating: 0, count: size / 2)
    }

    public var frames: BandFrames { BandFrames(hop: Self.hop, bands: bands, values: values) }

    /// The frames analyzed since the last call, handed over (a live capture doesn't keep them here).
    public func take() -> [Float] {
        defer { values = [] }
        return values
    }

    /// More of the track, mono.
    public func push(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var at = 0
        while pending.count - at >= length {
            analyze(at)
            at += step
        }
        if at > 0 { pending.removeFirst(at) }
    }

    private func analyze(_ at: Int) {
        let half = vDSP_Length(size / 2)
        pending.withUnsafeBufferPointer { samples in
            padded.withUnsafeMutableBufferPointer { out in
                vDSP_vmul(samples.baseAddress! + at, 1, window, 1, out.baseAddress!, 1, vDSP_Length(length))
            }
        }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                outReal.withUnsafeMutableBufferPointer { ore in
                    outImag.withUnsafeMutableBufferPointer { oim in
                        var packed = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        var spectrum = DSPSplitComplex(realp: ore.baseAddress!, imagp: oim.baseAddress!)
                        // Even samples to the real half, odd ones to the imaginary: the packing the real FFT takes.
                        padded.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &packed, 1, half)
                        }
                        fft.forward(input: packed, output: &spectrum)
                        power.withUnsafeMutableBufferPointer { p in
                            vDSP_zvmags(&spectrum, 1, p.baseAddress!, 1, half)
                        }
                    }
                }
            }
        }
        for (first, last) in edges {
            var sum: Float = 0
            if first < last { for k in first ..< last { sum += power[k] } }
            values.append(sum * scale)
        }
    }
}

public enum BandEnergies {
    public enum ReadError: LocalizedError {
        case unsupported(URL)

        public var errorDescription: String? {
            switch self {
            case let .unsupported(url): "读不了这段录音：\(url.lastPathComponent)"
            }
        }
    }

    /// The band energies of an audio file, all channels mixed to one.
    public static func read(_ url: URL, bands: Int = 8) throws -> BandFrames {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let analyzer = BandAnalyzer(sampleRate: format.sampleRate, bands: bands),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16)
        else { throw ReadError.unsupported(url) }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            analyzer.push(mono(buffer))
        }
        return analyzer.frames
    }

    /// A buffer's channels averaged into one.
    public static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard n > 0, channels > 0, let data = buffer.floatChannelData else { return [] }
        var out = [Float](repeating: 0, count: n)
        // Interleaved audio is one run of samples, a frame's channels side by side; otherwise each
        // channel has a run of its own.
        let interleaved = buffer.format.isInterleaved
        out.withUnsafeMutableBufferPointer { o in
            for c in 0 ..< channels {
                if interleaved {
                    vDSP_vadd(o.baseAddress!, 1, data[0] + c, vDSP_Stride(channels), o.baseAddress!, 1, vDSP_Length(n))
                } else {
                    vDSP_vadd(o.baseAddress!, 1, data[c], 1, o.baseAddress!, 1, vDSP_Length(n))
                }
            }
            var count = Float(channels)
            vDSP_vsdiv(o.baseAddress!, 1, &count, o.baseAddress!, 1, vDSP_Length(n))
        }
        return out
    }
}

/// The echo measurement of a recording folder (`system.m4a` + `mic.m4a`), on the transcript's timeline.
public enum RecordingEcho {
    public struct Measured: Sendable {
        public var system: BandFrames
        public var mic: BandFrames
        public var profile: EchoMeter.Profile
    }

    /// `micOffset`: seconds the microphone track starts after the system one (`TodoRecording.micOffset`).
    /// The transcript's clock starts with whichever track started first.
    public static func measure(folder: URL, micOffset: Double, settings: EchoMeter.Settings = EchoMeter.Settings()) throws -> Measured {
        let system = try BandEnergies.read(folder.appendingPathComponent("system.m4a")).delayed(by: max(0, -micOffset))
        let mic = try BandEnergies.read(folder.appendingPathComponent("mic.m4a")).delayed(by: max(0, micOffset))
        return Measured(system: system, mic: mic, profile: EchoMeter.analyze(system: system, mic: mic, settings: settings))
    }
}
