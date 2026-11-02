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
}

/// One stretch of speech. `me` is the microphone track, `others` the system-audio track.
public struct TranscriptSegment: Codable, Hashable, Sendable {
    public enum Speaker: String, Codable, Sendable { case me, others }

    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: Speaker, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct MeetingSummary: Codable, Hashable, Sendable {
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [String]
    /// Tasks that fell to other people (the user's own become to-dos).
    public var othersActions: [OthersAction]
    public var openQuestions: [String]
    /// Who spoke and about what, inferred from the attendee list (the transcript only knows 我/对方).
    public var speakers: [MeetingSpeaker]?

    enum CodingKeys: String, CodingKey {
        case speakers
        case overview
        case keyPoints = "key_points"
        case decisions
        case othersActions = "others_todos"
        case openQuestions = "open_questions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        othersActions = try c.decodeIfPresent([OthersAction].self, forKey: .othersActions) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        speakers = try c.decodeIfPresent([MeetingSpeaker].self, forKey: .speakers)
    }
}

public struct MeetingSpeaker: Codable, Hashable, Sendable {
    public var name: String
    /// What they mainly said or their role in the meeting.
    public var said: String
    /// false when the attribution is a guess.
    public var certain: Bool

    enum CodingKeys: String, CodingKey { case name, said, certain }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        said = try c.decodeIfPresent(String.self, forKey: .said) ?? ""
        certain = try c.decodeIfPresent(Bool.self, forKey: .certain) ?? false
    }
}

public struct OthersAction: Codable, Hashable, Sendable {
    public var who: String?
    public var task: String
    public var dueText: String?

    enum CodingKeys: String, CodingKey {
        case who, task
        case dueText = "due_text"
    }
}
