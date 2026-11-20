import AistAudio
import AistCore
import Foundation
import Testing

/// A tone lands in the band that holds its pitch, at its power, whatever the sample rate.
@Test(arguments: [48000.0, 44100.0, 16000.0]) func toneReadsItsPowerInItsBand(rate: Double) throws {
    let analyzer = try #require(BandAnalyzer(sampleRate: rate))
    let amplitude: Float = 0.5
    // 1 kHz sits in the fourth of eight bands between 300 Hz and 4 kHz (792…1095 Hz).
    let tone = (0 ..< Int(rate)).map { amplitude * sin(2 * Float.pi * 1000 * Float($0) / Float(rate)) }
    // In uneven pieces, as a capture delivers it.
    var at = 0
    for size in [1, 700, 4096, 33, 20000, Int(rate)] where at < tone.count {
        let end = min(tone.count, at + size)
        analyzer.push(Array(tone[at ..< end]))
        at = end
    }
    let frames = analyzer.frames
    #expect(frames.hop == 0.01 && frames.bands == 8)
    // A frame per 10 ms, less the one the last half-frame is still waiting for.
    #expect((98 ... 100).contains(frames.count))
    let middle = Array(frames.values[50 * 8 ..< 51 * 8])
    #expect(abs(middle[3] - amplitude * amplitude / 2) < 0.02)
    for (band, power) in middle.enumerated() where band != 3 { #expect(power < 0.002) }
}

@Test func silenceReadsNothingAndBadRatesAreRefused() throws {
    let analyzer = try #require(BandAnalyzer(sampleRate: 48000))
    analyzer.push([Float](repeating: 0, count: 4800))
    #expect(analyzer.values.allSatisfy { $0 == 0 } && analyzer.frames.count == 9)
    // The bands reach 4 kHz: a track sampled below 8 kHz can't hold them.
    #expect(BandAnalyzer(sampleRate: 6000) == nil)
}
