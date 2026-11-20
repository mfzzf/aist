import Foundation

/// Decides which microphone lines are only the other side heard through the speakers, from two kinds
/// of evidence: what the audio measured (`EchoMeter`) and whether the words repeat a line from the
/// other side (`HeardText.isEcho`).
///
/// Neither is enough alone. Recognition garbles an echo into other words, which only the audio
/// catches; and people do repeat each other ("好的" after "好的"), which the words alone would throw
/// away. So: the audio saying echo is enough; the words saying echo stand unless the audio says the
/// user was plainly the one speaking; and where the audio found no echo at all (headphones), nothing
/// is an echo, whatever the words.
public enum EchoFilter {
    public enum Verdict: String, Sendable {
        /// The user's own words.
        case kept
        /// An echo by the audio alone; the words came out different.
        case acoustic
        /// An echo by the audio and the words.
        case both
        /// An echo by the words; the audio doesn't say otherwise (or there is no audio to ask).
        case text

        public var isEcho: Bool { self != .kept }
    }

    public struct Settings: Sendable {
        /// This much of a line's audible time being echo makes it one on the audio alone…
        public var strongEcho = 0.6
        /// …unless more than this much of it is the user speaking.
        public var maxNear = 0.15
        /// A line repeating the other side's words is the user's all the same when this much of it
        /// is the user speaking.
        public var plainlyNear = 0.7
        /// Seconds of audible sound a line needs for the audio to have a say.
        public var minVoiced = 0.3
        /// Lines shorter than this (seconds) carry times too rough to look up exactly: a little
        /// before and this long from the start is listened to instead.
        public var shortLine = 1.0
        public var lead = 0.5

        public init() {}
    }

    /// `profile`: the recording's echo measurement on the transcript's timeline; nil when there is none.
    /// `whole`: it covers the whole recording, so finding no echo means there is none (headphones).
    /// While a meeting is still running that isn't known yet, and the words decide until it is.
    public static func verdict(_ mine: TranscriptSegment, others: [TranscriptSegment], profile: EchoMeter.Profile?,
                               whole: Bool = true, settings: Settings = Settings()) -> Verdict {
        let repeats = HeardText.isEcho(mine, of: others)
        guard let profile else { return repeats ? .text : .kept }
        // The microphone doesn't hear the speakers: whatever it heard was said in the room.
        guard profile.hasEcho else { return repeats && !whole ? .text : .kept }
        let short = mine.end - mine.start < settings.shortLine
        let share = profile.share(from: short ? mine.start - settings.lead : mine.start,
                                  to: short ? mine.start + settings.shortLine : mine.end)
        guard share.voiced >= settings.minVoiced else { return repeats ? .text : .kept }
        if share.echo >= settings.strongEcho, share.near <= settings.maxNear { return repeats ? .both : .acoustic }
        return repeats && share.near < settings.plainlyNear ? .text : .kept
    }

    /// The transcript with every microphone line marked as an echo or not. Nothing is removed.
    public static func marked(_ segments: [TranscriptSegment], profile: EchoMeter.Profile?, whole: Bool = true,
                              settings: Settings = Settings()) -> [TranscriptSegment] {
        let others = segments.filter { $0.speaker == .others }
        return segments.map { line in
            var line = line
            line.echo = line.speaker == .me
                && verdict(line, others: others, profile: profile, whole: whole, settings: settings).isEcho ? true : nil
            return line
        }
    }
}
