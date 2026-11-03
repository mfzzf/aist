@testable import AistCore
import Foundation
import Testing

private func todo(_ title: String, due: Date? = nil, meeting: UUID? = nil, pinned: Bool = false) -> TodoItem {
    var t = TodoItem(title: title, dueAt: due, origin: meeting == nil ? .manual : .meeting)
    t.meetingID = meeting
    t.pinned = pinned ? true : nil
    return t
}

@Test func groupsByTimeThenMeetingThenUndated() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 10))!
    let weekly = UUID(), standup = UUID(), gone = UUID()
    let meetings: [UUID: TodoGrouping.MeetingInfo] = [
        weekly: .init(title: "产品周会", startedAt: now.addingTimeInterval(-86400)),
        standup: .init(title: "站会", startedAt: now.addingTimeInterval(-3600)),
    ]
    let items = [
        todo("置顶的", pinned: true),
        todo("昨天该交", due: now.addingTimeInterval(-86400)),
        todo("今早九点", due: now.addingTimeInterval(-3600)),
        todo("今晚", due: now.addingTimeInterval(8 * 3600)),
        todo("明天", due: now.addingTimeInterval(86400)),
        todo("周五", due: now.addingTimeInterval(3 * 86400)),
        todo("下个月", due: now.addingTimeInterval(30 * 86400)),
        todo("周会的有期限", due: now.addingTimeInterval(8 * 3600), meeting: weekly),
        todo("周会的 A", meeting: weekly),
        todo("周会的 B", meeting: weekly),
        todo("站会的", meeting: standup),
        todo("会议被删了", meeting: gone),
        todo("随手记的"),
    ]
    let groups = TodoGrouping.groups(items, meetings: meetings, now: now, calendar: cal)
    #expect(groups.map(\.title) == ["置顶", "已过期", "今天", "明天", "本周", "以后", "站会", "产品周会", "无期限"])
    #expect(groups[1].items.map(\.title) == ["昨天该交", "今早九点"])
    #expect(groups[2].items.map(\.title) == ["今晚", "周会的有期限"])
    #expect(groups[7].items.map(\.title) == ["周会的 A", "周会的 B"])
    #expect(groups[8].items.map(\.title) == ["会议被删了", "随手记的"])
    #expect(groups.flatMap(\.items).count == items.count)
}
