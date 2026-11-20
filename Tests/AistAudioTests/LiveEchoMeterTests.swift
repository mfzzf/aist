import AistAudio
import AistCore
import AVFoundation
import Foundation
import Testing

// Made-up sound: bursts of noise for voices, never recorded audio.

/// Repeatable "random" numbers in -1..<1.
private struct Dice {
    var state: UInt64
    mutating func roll() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 23) - 1
    }
}

/// `seconds` of noise in syllable-long bursts while `talking(t)`, silence otherwise.
private func speech(seconds: Double, rate: Double, level: Float, seed: UInt64, talking: (Double) -> Bool) -> [Float] {
    var dice = Dice(state: seed)
    var out = [Float](repeating: 0, count: Int(seconds * rate))
    var on = false
    var left = 0
    for i in out.indices {
        if left == 0 {
            on.toggle()
            left = Int(rate * Double(on ? 0.12 + 0.2 * abs(dice.roll()) : 0.05 + 0.1 * abs(dice.roll())))
        }
        left -= 1
        if on, talking(Double(i) / rate) { out[i] = level * dice.roll() }
    }
    return out
}

private func buffer(_ samples: ArraySlice<Float>, rate: Double) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buffer
}

@Test func liveMeterTellsEchoFromTheUserAsTheMeetingRuns() {
    let rate = 16000.0
    // The other side talks 2–30 s; the user alone 34–44 s. The microphone hears the other side
    // 80 ms late at a fifth of the amplitude, over a faint hiss.
    let far = speech(seconds: 48, rate: rate, level: 0.3, seed: 1) { (2 ... 30).contains($0) }
    let user = speech(seconds: 48, rate: rate, level: 0.2, seed: 2) { (34 ... 44).contains($0) }
    var hiss = Dice(state: 3)
    let delay = Int(0.08 * rate)
    let mic = far.indices.map { i in 0.0005 * hiss.roll() + user[i] + (i >= delay ? 0.2 * far[i - delay] : 0) }

    let meter = LiveEchoMeter()
    #expect(!meter.profile.hasEcho && meter.profile.frames.isEmpty)
    // In capture-sized pieces, the two sides taking turns.
    let chunk = 1600
    var early: EchoMeter.Share?
    for at in stride(from: 0, to: far.count, by: chunk) {
        let time = Double(at) / rate
        meter.push(buffer(far[at ..< at + chunk], rate: rate), speaker: .others, at: time)
        meter.push(buffer(mic[at ..< at + chunk], rate: rate), speaker: .me, at: time)
        // Half-way through the other side's turn it is already known to be echo.
        if at == Int(20 * rate) { early = meter.profile.share(from: 8, to: 18) }
    }
    #expect((early?.echo ?? 0) > 0.7)
    let profile = meter.profile
    #expect(profile.hasEcho)
    // Answers reach to within a second or so of the newest audio.
    #expect(Double(profile.frames.count) * profile.hop > 46)
    #expect(profile.share(from: 5, to: 28).echo > 0.7)
    #expect(profile.share(from: 35, to: 43).mine > 0.9)

    meter.reset()
    #expect(meter.profile.frames.isEmpty && !meter.profile.hasEcho)
}

@Test func liveMeterKeepsStepWhenTheCaptureSkips() {
    let rate = 16000.0
    let far = speech(seconds: 30, rate: rate, level: 0.3, seed: 4) { (2 ... 28).contains($0) }
    var hiss = Dice(state: 5)
    let delay = Int(0.08 * rate)
    let mic = far.indices.map { i in 0.0005 * hiss.roll() + (i >= delay ? 0.2 * far[i - delay] : 0) }
    let meter = LiveEchoMeter()
    let chunk = 1600
    for at in stride(from: 0, to: far.count, by: chunk) {
        let time = Double(at) / rate
        meter.push(buffer(far[at ..< at + chunk], rate: rate), speaker: .others, at: time)
        // The microphone loses half a second at 10 s; what comes after still arrives at its own time.
        if (10 ..< 10.5).contains(time) { continue }
        meter.push(buffer(mic[at ..< at + chunk], rate: rate), speaker: .me, at: time)
    }
    let profile = meter.profile
    #expect(profile.share(from: 4, to: 9).echo > 0.7)
    #expect(profile.share(from: 12, to: 26).echo > 0.7)
}

/// The capture delivers 48 kHz stereo, channels apart or interleaved: both mix down to the same mono.
@Test(arguments: [false, true]) func stereoBuffersMixDown(interleaved: Bool) throws {
    let n = 480
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
    buffer.frameLength = AVAudioFrameCount(n)
    let data = try #require(buffer.floatChannelData)
    for i in 0 ..< n {
        // Left ramps up, right is a constant: their mean is known at every frame.
        let left = Float(i) / Float(n), right: Float = 0.5
        if interleaved {
            data[0][i * 2] = left
            data[0][i * 2 + 1] = right
        } else {
            data[0][i] = left
            data[1][i] = right
        }
    }
    let mono = BandEnergies.mono(buffer)
    #expect(mono.count == n)
    #expect(abs(mono[0] - 0.25) < 1e-6 && abs(mono[240] - 0.5) < 1e-6 && abs(mono[479] - (479.0 / 480 + 0.5) / 2) < 1e-6)
    // And the live meter takes them as they come.
    let meter = LiveEchoMeter()
    for k in 0 ..< 300 {
        meter.push(buffer, speaker: .others, at: Double(k) * 0.01)
        meter.push(buffer, speaker: .me, at: Double(k) * 0.01)
    }
    // Three seconds in: settled up to the last measurement, a second or so back.
    #expect(meter.profile.frames.count > 100)
}
