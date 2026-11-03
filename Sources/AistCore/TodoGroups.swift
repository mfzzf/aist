import Foundation

/// One heading in the to-do list.
public struct TodoGroup: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case pinned, overdue, today, tomorrow, thisWeek, later
        /// Undated to-dos that came out of one meeting.
        case meeting(UUID)
        case undated
    }

    public var kind: Kind
    public var title: String
    /// For a meeting: when it happened.
    public var date: Date?
    public var items: [TodoItem]

    public var id: Kind { kind }

    public init(kind: Kind, title: String, date: Date? = nil, items: [TodoItem]) {
        self.kind = kind
        self.title = title
        self.date = date
        self.items = items
    }

    public var meetingID: UUID? {
        if case let .meeting(id) = kind { return id }
        return nil
    }

    public var isMeeting: Bool { meetingID != nil }

    /// Unique even when two meetings share a title.
    public var key: String { meetingID?.uuidString ?? title }
}

/// The open list, aggregated: deadlines first (what's due soon is what matters), then the undated rest
/// gathered under the meeting it came from, newest meeting first, then everything else.
public enum TodoGrouping {
    public struct MeetingInfo: Sendable {
        public var title: String
        public var startedAt: Date
        public init(title: String, startedAt: Date) {
            self.title = title
            self.startedAt = startedAt
        }
    }

    /// `open` should already be in screen order; each group keeps that order.
    public static func groups(_ open: [TodoItem], meetings: [UUID: MeetingInfo],
                              now: Date = .now, calendar: Calendar = .current) -> [TodoGroup] {
        var timed: [TodoGroup.Kind: [TodoItem]] = [:]
        var byMeeting: [UUID: [TodoItem]] = [:]
        var undated: [TodoItem] = []
        for item in open {
            if let kind = timeKind(item, now: now, calendar: calendar) {
                timed[kind, default: []].append(item)
            } else if let id = item.meetingID, meetings[id] != nil {
                byMeeting[id, default: []].append(item)
            } else {
                undated.append(item)
            }
        }

        var out: [TodoGroup] = []
        let order: [(TodoGroup.Kind, String)] = [
            (.pinned, "置顶"), (.overdue, "已过期"), (.today, "今天"),
            (.tomorrow, "明天"), (.thisWeek, "本周"), (.later, "以后"),
        ]
        for (kind, title) in order {
            if let items = timed[kind] { out.append(TodoGroup(kind: kind, title: title, items: items)) }
        }
        let meetingGroups = byMeeting.compactMap { id, items -> TodoGroup? in
            guard let m = meetings[id] else { return nil }
            return TodoGroup(kind: .meeting(id), title: m.title, date: m.startedAt, items: items)
        }
        out += meetingGroups.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if !undated.isEmpty { out.append(TodoGroup(kind: .undated, title: "无期限", items: undated)) }
        return out
    }

    /// Pinned and dated to-dos go by time; nil means undated.
    static func timeKind(_ item: TodoItem, now: Date, calendar: Calendar) -> TodoGroup.Kind? {
        if item.pinned == true { return .pinned }
        guard let due = item.dueAt else { return nil }
        if due < now, !calendar.isDate(due, inSameDayAs: now) { return .overdue }
        if calendar.isDate(due, inSameDayAs: now) { return due < now ? .overdue : .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(due, inSameDayAs: tomorrow) { return .tomorrow }
        return due.timeIntervalSince(now) < 7 * 86400 ? .thisWeek : .later
    }
}
