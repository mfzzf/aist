import Foundation

/// One stretch of one voice on a track, as speaker separation found it: who (a label that only means
/// something within that track of that recording) and when, in seconds from the track's start.
public struct VoiceTurn: Codable, Hashable, Sendable {
    public var voice: String
    public var start: Double
    public var end: Double

    public init(voice: String, start: Double, end: Double) {
        self.voice = voice
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// What telling a track's voices apart gives: the turns, and for each voice a voiceprint (a vector;
/// two of the same person lie close together).
public struct TrackVoices: Codable, Hashable, Sendable {
    public var turns: [VoiceTurn]
    public var prints: [String: [Float]]

    public init(turns: [VoiceTurn], prints: [String: [Float]]) {
        self.turns = turns
        self.prints = prints
    }

    /// The voices, the one who spoke most first.
    public var voices: [String] {
        var time: [String: Double] = [:]
        for turn in turns { time[turn.voice, default: 0] += turn.duration }
        return time.keys.sorted { (time[$0] ?? 0, $1) > (time[$1] ?? 0, $0) }
    }

    public func speaking(_ voice: String) -> Double {
        turns.reduce(0) { $0 + ($1.voice == voice ? $1.duration : 0) }
    }
}

public enum VoiceMatch {
    /// How far apart two voiceprints point: 0 the same direction, 1 unrelated, 2 opposite.
    public static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i])
            aa += Double(a[i]) * Double(a[i])
            bb += Double(b[i]) * Double(b[i])
        }
        guard aa > 0, bb > 0 else { return 2 }
        return 1 - dot / (aa * bb).squareRoot()
    }
}
