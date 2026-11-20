import Foundation

/// A recorded meeting: audio → on-device transcript → AI summary, plus the to-dos it produced.
public struct Meeting: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case recording, transcribing, summarizing, ready, failed }

    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var status: Status
    /// Why processing failed, or why there's no summary.
    public var error: String?
    public var recording: TodoRecording?
    public var transcript: [TranscriptSegment]?
    public var summary: MeetingSummary?
    /// To-dos this meeting added to (or merged into) the list.
    public var todoIDs: [UUID]?
    public var notes: String?
    /// The user renamed it; regenerating the minutes keeps their title.
    public var titleEdited: Bool?
    /// The calendar event this recording belongs to (EKEvent.eventIdentifier).
    public var calendarEventID: String?
    /// Who was invited, from the calendar event; helps the minutes name people.
    public var attendees: [String]?
    /// Their email addresses, where the calendar has them: who gets the minutes by mail.
    public var attendeeEmails: [String]?
    /// When `summary` was written. Missing on minutes from before versions were kept.
    public var summaryCreatedAt: Date?
    /// Minutes that "重新分析整理" replaced, oldest first.
    public var summaryHistory: [MeetingSummaryVersion]?
    /// The voices told apart in the recording, with the names found for them.
    public var voices: [MeetingVoice]?

    public init(id: UUID = UUID(), startedAt: Date = .now) {
        self.id = id
        self.startedAt = startedAt
        self.duration = 0
        self.status = .recording
        self.title = "会议 " + startedAt.formatted(
            Date.FormatStyle().month(.defaultDigits).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
                .locale(Locale(identifier: "zh_CN")))
    }

    public var isProcessing: Bool { status == .transcribing || status == .summarizing }

    // MARK: Versions of the minutes

    /// Puts new minutes in place and keeps the ones they replace in `summaryHistory`.
    public mutating func replaceSummary(_ new: MeetingSummary, title newTitle: String, at date: Date = .now) {
        if let old = summary {
            summaryHistory = (summaryHistory ?? []) + [
                MeetingSummaryVersion(createdAt: summaryCreatedAt ?? startedAt, title: title, summary: old),
            ]
        }
        summary = new
        title = newTitle
        summaryCreatedAt = date
    }

    /// Makes an earlier version the current minutes; the current ones take its place in the history.
    public mutating func restoreSummary(_ versionID: UUID) {
        guard var history = summaryHistory, let i = history.firstIndex(where: { $0.id == versionID }) else { return }
        let version = history.remove(at: i)
        if let current = summary {
            history.append(MeetingSummaryVersion(createdAt: summaryCreatedAt ?? startedAt, title: title, summary: current))
        }
        history.sort { $0.createdAt < $1.createdAt }
        summaryHistory = history.isEmpty ? nil : history
        summary = version.summary
        summaryCreatedAt = version.createdAt
        // A title the user typed outlives any version.
        if titleEdited != true { title = version.title }
    }

    public mutating func deleteSummaryVersion(_ versionID: UUID) {
        summaryHistory?.removeAll { $0.id == versionID }
        if summaryHistory?.isEmpty == true { summaryHistory = nil }
    }

    /// The meeting as it read with an earlier version of the minutes (nil or unknown id: as it is now).
    public func showing(version versionID: UUID?) -> Meeting {
        guard let versionID, let version = summaryHistory?.first(where: { $0.id == versionID }) else { return self }
        var copy = self
        copy.summary = version.summary
        copy.summaryCreatedAt = version.createdAt
        if titleEdited != true { copy.title = version.title }
        return copy
    }
}

/// Earlier minutes of a meeting, kept when they were regenerated.
public struct MeetingSummaryVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    /// The meeting's title while these were the minutes.
    public var title: String
    public var summary: MeetingSummary

    public init(id: UUID = UUID(), createdAt: Date, title: String, summary: MeetingSummary) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.summary = summary
    }
}

/// One stretch of speech. `me` is the microphone track, `others` the system-audio track.
public struct TranscriptSegment: Codable, Hashable, Sendable {
    public enum Speaker: String, Codable, Sendable { case me, others }

    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String
    /// The line in the subtitle language, when live translation was on.
    public var translation: String?
    /// A microphone line that is only the other side heard through the speakers (see `EchoFilter`).
    /// Kept in the transcript, left out of what is shown, summarized and exported.
    public var echo: Bool?
    /// Whose voice it is, once the recording's voices were told apart: a `MeetingVoice.id`.
    public var voice: String?

    public init(speaker: Speaker, start: Double, end: Double, text: String, translation: String? = nil) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.translation = translation
    }
}

public extension Array where Element == TranscriptSegment {
    /// What people said: the transcript without the microphone's echoes of the other side.
    var spoken: [TranscriptSegment] { filter { $0.echo != true } }
}

public struct MeetingSummary: Codable, Hashable, Sendable {
    public var overview: String
    /// What was discussed, topic by topic in the order it came up. Minutes from before topics have
    /// `keyPoints` instead.
    public var topics: [MeetingTopic]?
    /// The flat list older minutes used; new ones leave it empty.
    public var keyPoints: [String]
    public var decisions: [String]
    /// Tasks that fell to other people (the user's own become to-dos).
    public var othersActions: [OthersAction]
    public var openQuestions: [String]
    /// Who spoke and about what, inferred from the attendee list (the transcript only knows 我/对方).
    public var speakers: [MeetingSpeaker]?
    /// Names and terms as the minutes spell them, with how speech recognition misheard them.
    public var terms: [MeetingTerm]?
    /// Where each key point / decision was said ("mm:ss" of its evidence line), parallel to the lists.
    public var keyPointAt: [String?]?
    public var decisionAt: [String?]?

    enum CodingKeys: String, CodingKey {
        case speakers, terms, topics
        case keyPointAt = "key_point_at"
        case decisionAt = "decision_at"
        case overview
        case keyPoints = "key_points"
        case decisions
        case othersActions = "others_todos"
        case openQuestions = "open_questions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        // Malformed topics shouldn't cost the rest of the minutes.
        let decoded = (try? c.decodeIfPresent([MeetingTopic].self, forKey: .topics)) ?? []
        let kept = decoded.filter { !$0.isEmpty }
        topics = kept.isEmpty ? nil : kept
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        othersActions = try c.decodeIfPresent([OthersAction].self, forKey: .othersActions) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        speakers = try c.decodeIfPresent([MeetingSpeaker].self, forKey: .speakers)
        terms = try c.decodeIfPresent([MeetingTerm].self, forKey: .terms)
        keyPointAt = try c.decodeIfPresent([String?].self, forKey: .keyPointAt)
        decisionAt = try c.decodeIfPresent([String?].self, forKey: .decisionAt)
    }

    /// Seconds into the meeting where key point / decision `i` was said.
    public func keyPointTime(_ i: Int) -> Double? { MeetingTime.at(keyPointAt, i) }
    public func decisionTime(_ i: Int) -> Double? { MeetingTime.at(decisionAt, i) }

    /// Every line of the discussion, for search: topic titles, their points and conclusions, or the
    /// key points of older minutes.
    public var discussionText: [String] {
        (topics ?? []).flatMap { [$0.title] + $0.points.map(\.text) + [$0.conclusion ?? ""] } + keyPoints
    }
}

/// One thing the meeting spent time on: what was said about it and where it ended up.
public struct MeetingTopic: Codable, Hashable, Sendable {
    public var title: String
    /// "mm:ss" where the meeting turned to it.
    public var at: String?
    public var points: [TopicPoint]
    /// Where the topic ended up; nil when it was left open.
    public var conclusion: String?

    enum CodingKeys: String, CodingKey { case title, at, points, conclusion }

    public init(title: String, at: String? = nil, points: [TopicPoint] = [], conclusion: String? = nil) {
        self.title = title
        self.at = at
        self.points = points
        self.conclusion = conclusion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try c.decodeIfPresent(String.self, forKey: .title) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        points = (try c.decodeIfPresent([TopicPoint].self, forKey: .points) ?? []).filter { !$0.text.isEmpty }
        let end = (try? c.decodeIfPresent(String.self, forKey: .conclusion))?.trimmingCharacters(in: .whitespacesAndNewlines)
        conclusion = end?.isEmpty == false ? end : nil
    }

    public var time: Double? { MeetingTime.seconds(at) }
    var isEmpty: Bool { points.isEmpty && conclusion == nil }
}

/// One thing said under a topic, with where to hear it.
public struct TopicPoint: Codable, Hashable, Sendable {
    public var text: String
    /// "mm:ss" of the line that best supports it.
    public var at: String?

    enum CodingKeys: String, CodingKey { case text, at }

    public init(text: String, at: String? = nil) {
        self.text = text
        self.at = at
    }

    /// `{"text": …, "at": …}`, or a bare string from a model that skipped the object.
    public init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            at = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try c.decodeIfPresent(String.self, forKey: .text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
    }

    public var time: Double? { MeetingTime.seconds(at) }
}

/// A name or term as the minutes settled on it, and how recognition heard it.
public struct MeetingTerm: Codable, Hashable, Sendable {
    public var name: String
    public var note: String
    public var heard: [String]

    enum CodingKeys: String, CodingKey { case name, note, heard }

    public init(name: String, note: String = "", heard: [String] = []) {
        self.name = name
        self.note = note
        self.heard = heard
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        self.name = name
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        heard = (try c.decodeIfPresent([String].self, forKey: .heard) ?? []).filter { $0 != name && !$0.isEmpty }
    }
}

/// "mm:ss" / "h:mm:ss" stamps the model copies from the transcript, as seconds.
public enum MeetingTime {
    public static func seconds(_ stamp: String?) -> Double? {
        guard let stamp else { return nil }
        let parts = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":").compactMap { Int($0) }
        guard (2 ... 3).contains(parts.count) else { return nil }
        return Double(parts.reduce(0) { $0 * 60 + $1 })
    }

    public static func stamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func at(_ list: [String?]?, _ i: Int) -> Double? {
        guard let list, i < list.count else { return nil }
        return seconds(list[i])
    }

    /// The line a quote (a to-do's evidence) came from: the one sharing most of its characters.
    public static func find(_ quote: String?, in transcript: [TranscriptSegment]) -> TranscriptSegment? {
        guard let quote, !quote.isEmpty else { return nil }
        let q = Array(quote.lowercased().filter { $0.isLetter || $0.isNumber })
        var best: (TranscriptSegment, Double)?
        for seg in transcript {
            let score = HeardText.similarity(q, Array(seg.text.lowercased().filter { $0.isLetter || $0.isNumber }))
            if score > (best?.1 ?? 0.45) { best = (seg, score) }
        }
        return best?.0
    }
}

public struct MeetingSpeaker: Codable, Hashable, Sendable {
    public var name: String
    /// What they mainly said or their role in the meeting.
    public var said: String
    /// false when the attribution is a guess.
    public var certain: Bool
    /// Which voice this is about: as the model wrote it, the letter the voice was shown under
    /// (说话人A → "A"); once saved, the `MeetingVoice.id`.
    public var voice: String?
    /// What the name was worked out from.
    public var basis: String?

    enum CodingKeys: String, CodingKey { case name, said, certain, voice, basis }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        said = try c.decodeIfPresent(String.self, forKey: .said) ?? ""
        certain = try c.decodeIfPresent(Bool.self, forKey: .certain) ?? false
        voice = try? c.decodeIfPresent(String.self, forKey: .voice)
        basis = try? c.decodeIfPresent(String.self, forKey: .basis)
    }
}

public struct OthersAction: Codable, Hashable, Sendable {
    public var who: String?
    public var task: String
    public var dueText: String?
    /// "mm:ss" of the line it was given in.
    public var at: String?

    enum CodingKeys: String, CodingKey {
        case who, task, at
        case dueText = "due_text"
    }

    public var time: Double? { MeetingTime.seconds(at) }
}
