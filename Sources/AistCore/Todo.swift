import Foundation

public enum TodoPriority: String, Codable, CaseIterable, Sendable, Comparable {
    case high, medium, low

    var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum TodoStatus: String, Codable, Sendable { case open, done }

/// Where a to-do came from: a Mac screenshot, a phone meeting recording, or typed by hand.
public enum TodoOrigin: String, Codable, Sendable { case screenshot, meeting, manual, email, github }

/// Points back at the email a to-do came from.
public struct EmailRef: Codable, Hashable, Sendable {
    public var accountID: UUID
    public var mailbox: String
    public var uid: UInt32
    public var subject: String?

    public init(accountID: UUID, mailbox: String, uid: UInt32, subject: String?) {
        self.accountID = accountID
        self.mailbox = mailbox
        self.uid = uid
        self.subject = subject
    }
}

/// One thing the user has to do. "One matter = one to-do": details of the same matter are merged, not split.
public struct TodoItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var requester: String?
    public var source: String?
    /// Deadline as written in the original ("Thursday 3pm", "最好今天内").
    public var dueText: String?
    /// Deadline resolved to an absolute time, if the model could.
    public var dueAt: Date?
    public var priority: TodoPriority
    /// Short verbatim excerpt the to-do was derived from.
    public var evidence: String?
    public var status: TodoStatus
    public var origin: TodoOrigin
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    /// Pinned to the top of the list. Optional so older saved data still decodes.
    public var pinned: Bool?
    /// Free-form notes the user added.
    public var notes: String?
    /// Legacy: audio once attached directly to a to-do. Recordings now belong to meetings.
    public var recordings: [TodoRecording]?
    /// The meeting this to-do came out of.
    public var meetingID: UUID?
    /// The email this to-do came out of.
    public var emailRef: EmailRef?
    /// The matching item in the system Reminders app (EKReminder.calendarItemIdentifier).
    public var reminderID: String?
    /// A web page the to-do came from (a GitHub pull request, an issue…).
    public var link: String?
    /// The AI's suggested next step (why it matters, what to do first, who to ask).
    public var suggestion: String?

    public init(
        id: UUID = UUID(), title: String, requester: String? = nil, source: String? = nil,
        dueText: String? = nil, dueAt: Date? = nil, priority: TodoPriority = .medium,
        evidence: String? = nil, status: TodoStatus = .open, origin: TodoOrigin,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.requester = requester
        self.source = source
        self.dueText = dueText
        self.dueAt = dueAt
        self.priority = priority
        self.evidence = evidence
        self.status = status
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

/// One recording attached to a to-do. Audio lives in `TodoStore.folder(for: id)`:
/// `system.m4a` (what the Mac played: the other side of a call, a video) and `mic.m4a` (the user).
/// Kept separate so later analysis can tell who said what.
public struct TodoRecording: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool
    /// Seconds the mic track starts after the system track (negative: before). For synced playback.
    public var micOffset: Double?
    public var transcript: String?
    public var summary: String?

    public init(id: UUID = UUID(), startedAt: Date, duration: TimeInterval,
                hasSystemAudio: Bool, hasMicrophone: Bool, micOffset: Double? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
        self.micOffset = micOffset
    }
}
