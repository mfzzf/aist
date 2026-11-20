@testable import AistCore
import Foundation
import Testing

// Synthetic tracks only: bursts of noise shaped like syllables, never recorded audio.

/// Repeatable "random" numbers in 0..<1.
private struct Dice {
    var state: UInt64
    mutating func roll() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
}

private let bands = 8
private let hop = 0.01

/// Someone talking during `spans` (seconds): syllables of uneven length and loudness, quiet between.
private func voice(seconds: Double, spans: [ClosedRange<Double>], level: Float, seed: UInt64) -> [Float] {
    var dice = Dice(state: seed)
    let n = Int(seconds / hop)
    var out = [Float](repeating: 0, count: n * bands)
    var on = false
    var left = 0
    for i in 0 ..< n {
        if left == 0 {
            on.toggle()
            left = on ? 10 + Int(dice.roll() * 25) : 4 + Int(dice.roll() * 12)
        }
        left -= 1
        let t = Double(i) * hop
        guard on, spans.contains(where: { $0.contains(t) }) else { continue }
        let loud = level * (0.3 + 1.4 * dice.roll())
        for b in 0 ..< bands { out[i * bands + b] = loud * (0.4 + 1.2 * dice.roll()) }
    }
    return out
}

/// What a microphone makes of it: the room's hiss, the user, and the system track `delay` frames
/// later through `leak` per band (unevenly, as a room does).
private func microphone(system: [Float], user: [Float], delay: Int, leak: [Float], seed: UInt64) -> [Float] {
    var dice = Dice(state: seed)
    var out = [Float](repeating: 0, count: system.count)
    for i in 0 ..< system.count / bands {
        for b in 0 ..< bands {
            var value = 1e-7 * (0.8 + 0.4 * dice.roll()) + user[i * bands + b]
            if i >= delay { value += leak[b] * system[(i - delay) * bands + b] * (0.6 + dice.roll()) }
            out[i * bands + b] = value
        }
    }
    return out
}

// The other side talks 5–50 s and 80–110 s; the user alone 55–75 s, and over them 90–100 s.
private let far = voice(seconds: 120, spans: [5 ... 50, 80 ... 110], level: 1e-2, seed: 1)
private let near = voice(seconds: 120, spans: [55 ... 75, 90 ... 100], level: 4e-3, seed: 2)
private let leak: [Float] = [0.004, 0.01, 0.02, 0.03, 0.03, 0.02, 0.015, 0.01]

@Test func speakersAreHeardAsEcho() {
    let mic = microphone(system: far, user: near, delay: 11, leak: leak, seed: 3)
    let profile = EchoMeter.analyze(system: BandFrames(bands: bands, values: far), mic: BandFrames(bands: bands, values: mic))
    #expect(profile.hasEcho)
    // The delay comes out at the 110 ms put in, wherever there was enough to measure it.
    let delays = profile.windows.filter(\.measured).map(\.delay)
    #expect(delays.count >= 6)
    #expect(delays.allSatisfy { abs($0 - 0.11) <= 0.011 })
    // The loss, close to the 1–3% put in.
    #expect(profile.leak > 0.005 && profile.leak < 0.05)

    // The other side alone: echo, not the user.
    let echo = profile.share(from: 10, to: 40)
    #expect(echo.voiced > 10 && echo.echo > 0.7 && echo.near < 0.05)
    // The user with the other side quiet.
    let alone = profile.share(from: 57, to: 73)
    #expect(alone.voiced > 5 && alone.mine > 0.95)
    // The user over the other side is the user.
    let over = profile.share(from: 91, to: 99)
    #expect(over.near > 0.6 && over.echo < 0.25)
    // And once they stop, it is echo again.
    #expect(profile.share(from: 101, to: 109).echo > 0.6)
}

@Test func tracksOffByAStretchStillLineUp() {
    // The microphone track lost its first 0.8 s and its last 3 s: on the shared clock the echo now
    // comes 0.69 s before the system track plays it, and the system track runs on past the end.
    let whole = microphone(system: far, user: near, delay: 11, leak: leak, seed: 3)
    let mic = Array(whole[(80 * bands) ..< (whole.count - 300 * bands)])
    let profile = EchoMeter.analyze(system: BandFrames(bands: bands, values: far), mic: BandFrames(bands: bands, values: mic))
    let delays = profile.windows.filter(\.measured).map(\.delay)
    #expect(delays.count >= 6 && delays.allSatisfy { abs($0 + 0.69) <= 0.011 })
    #expect(profile.share(from: 10, to: 39).echo > 0.7)
    #expect(profile.share(from: 57, to: 72).mine > 0.95)
}

@Test func headphonesLeaveNothingToCallEcho() {
    let mic = microphone(system: far, user: near, delay: 0, leak: [Float](repeating: 0, count: bands), seed: 4)
    let profile = EchoMeter.analyze(system: BandFrames(bands: bands, values: far), mic: BandFrames(bands: bands, values: mic))
    #expect(!profile.hasEcho && !profile.frames.contains(.echo))
    // The other side talking is silence at the microphone; the user is the user throughout.
    #expect(profile.share(from: 10, to: 40).voiced < 0.5)
    #expect(profile.share(from: 57, to: 73).near > 0.95)
    #expect(profile.share(from: 91, to: 99).near > 0.95)
}

@Test func tracksOfNoUseGiveAnEmptyAnswer() {
    let empty = EchoMeter.analyze(system: BandFrames(bands: bands), mic: BandFrames(bands: bands))
    #expect(empty.frames.isEmpty && !empty.hasEcho)
    // Nothing played: whatever the microphone heard is the user.
    let mic = microphone(system: [Float](repeating: 0, count: far.count), user: near, delay: 0, leak: leak, seed: 5)
    let quiet = EchoMeter.analyze(system: BandFrames(bands: bands, values: [Float](repeating: 0, count: far.count)),
                                  mic: BandFrames(bands: bands, values: mic))
    #expect(!quiet.hasEcho && quiet.share(from: 57, to: 73).mine > 0.95)
    // A track that started late lines up once the silence is put back in front.
    let late = BandFrames(bands: bands, values: [1, 1, 1, 1, 1, 1, 1, 1]).delayed(by: 0.03)
    #expect(late.count == 4 && late.values[..<24].allSatisfy { $0 == 0 } && late.duration == 0.04)
}

@Test func echoVerdictsWeighAudioOverWords() {
    let mic = microphone(system: far, user: near, delay: 11, leak: leak, seed: 3)
    let profile = EchoMeter.analyze(system: BandFrames(bands: bands, values: far), mic: BandFrames(bands: bands, values: mic))
    let others = [
        TranscriptSegment(speaker: .others, start: 10, end: 14, text: "我们下个月开始第二阶段的测试"),
        TranscriptSegment(speaker: .others, start: 58, end: 60, text: "好的没问题"),
    ]
    func mine(_ start: Double, _ end: Double, _ text: String) -> EchoFilter.Verdict {
        EchoFilter.verdict(TranscriptSegment(speaker: .me, start: start, end: end, text: text), others: others, profile: profile)
    }
    // The speakers, heard word for word.
    #expect(mine(10.2, 14.2, "我们下个月开始第二阶段的测试") == .both)
    // The speakers, garbled into other words: only the audio knows.
    #expect(mine(20, 24, "窝门夏个月开始地而接短") == .acoustic)
    // The user's own words.
    #expect(mine(62, 66, "文档我周三之前发出来") == .kept)
    // The user repeating the other side is still the user.
    #expect(mine(60.5, 62.5, "好的没问题") == .kept)
    // A line too short to carry real times is listened to around its start.
    #expect(mine(22, 22.1, "窝门夏个月") == .acoustic)
    #expect(mine(63, 63.1, "好的") == .kept)
    // No measurement: the words are all there is.
    let line = TranscriptSegment(speaker: .me, start: 10.2, end: 14.2, text: "我们下个月开始第二阶段的测试")
    #expect(EchoFilter.verdict(line, others: others, profile: nil) == .text)
    #expect(EchoFilter.verdict(TranscriptSegment(speaker: .me, start: 62, end: 66, text: "文档我周三之前发出来"),
                               others: others, profile: nil) == .kept)
    // On headphones the microphone can't have heard them: the same words are the user's.
    let quiet = microphone(system: far, user: near, delay: 0, leak: [Float](repeating: 0, count: bands), seed: 4)
    let headphones = EchoMeter.analyze(system: BandFrames(bands: bands, values: far), mic: BandFrames(bands: bands, values: quiet))
    #expect(EchoFilter.verdict(line, others: others, profile: headphones) == .kept)

    // Marking keeps every line; only what is spoken goes on to the minutes and exports.
    let transcript = others + [
        TranscriptSegment(speaker: .me, start: 10.2, end: 14.2, text: "我们下个月开始第二阶段的测试"),
        TranscriptSegment(speaker: .me, start: 62, end: 66, text: "文档我周三之前发出来"),
    ]
    let marked = EchoFilter.marked(transcript, profile: profile)
    #expect(marked.map(\.echo) == [nil, nil, true, nil])
    #expect(marked.spoken.map(\.text) == ["我们下个月开始第二阶段的测试", "好的没问题", "文档我周三之前发出来"])
    #expect(MeetingSummarizer.format(marked.spoken).components(separatedBy: "\n").count == 3)
    #expect(MeetingExport.srt(marked).contains("\n3\n") && !MeetingExport.srt(marked).contains("\n4\n"))
    // Marking again with nothing to go on clears what no longer holds.
    #expect(EchoFilter.marked(marked, profile: headphones).allSatisfy { $0.echo == nil })
}
