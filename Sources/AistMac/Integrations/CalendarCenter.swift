import AistCore
import AppKit
import Combine
import EventKit
import SwiftUI

/// A calendar event as the UI needs it (EKEvent is a mutable class; this is a snapshot).
enum CalSource: Hashable { case system, wecom }

struct CalEvent: Identifiable, Hashable {
    /// Recurring events share an eventIdentifier, so the occurrence's start is part of the id.
    var id: String { "\(eventID)@\(start.timeIntervalSince1970)" }
    var eventID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: URL?
    var attendees: [String]
    var organizer: String?
    var calendarTitle: String
    var color: Color
    var source: CalSource = .system
    /// 企业微信 / 腾讯会议 meeting number.
    var meetingCode: String?
    var room: String?
    /// Attendees' addresses, where the calendar has them (for mailing the minutes).
    var attendeeEmails: [String] = []

    /// A call noticed in a meeting app (not on the calendar): offered for recording like an event.
    static func call(app: String, bundleID: String) -> CalEvent {
        CalEvent(eventID: "call:\(bundleID)", title: "\(app) 通话", start: .now, end: .now.addingTimeInterval(3600),
                 isAllDay: false, attendees: [], calendarTitle: app, color: .green)
    }

    var isCall: Bool { eventID.hasPrefix("call:") }

    /// 腾讯会议 is installed to open wemeet:// links.
    static var canJoinByCode: Bool {
        URL(string: "wemeet://page/inmeeting").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }

    /// The join link opens in 腾讯会议 rather than a browser.
    var joinsInTencentMeeting: Bool { joinURL?.scheme == "wemeet" }

    /// Has other people or a call link: a meeting worth recording, not a personal block.
    var isMeeting: Bool {
        if attendees.count > 1 || meetingCode != nil { return true }
        let text = [location, notes, url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["zoom.us", "meet.google", "teams.microsoft", "meeting.tencent", "voovmeeting", "feishu.cn/meeting", "larksuite", "webex"]
            .contains { text.contains($0) }
    }

    /// The call link, if any (opened by "加入会议").
    var joinURL: URL? {
        if let url, url.scheme?.hasPrefix("http") == true { return url }
        // 企业微信 schedules carry the meeting number but no link, and 企业微信 has no public URL into
        // its own meeting window; it joins through wemeet:// itself, which 腾讯会议 handles.
        if source == .wecom, let code = meetingCode, Self.canJoinByCode {
            return URL(string: "wemeet://page/inmeeting?meeting_code=\(code.filter(\.isNumber))")
        }
        let text = [location, notes].compactMap { $0 }.joined(separator: " ")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let links = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        return links.first { u in
            ["zoom.us", "meet.google", "teams.microsoft", "meeting.tencent", "voovmeeting", "feishu", "lark", "webex"]
                .contains { u.absoluteString.contains($0) }
        } ?? links.first
    }
}

/// Reads the system calendars (iCloud, Google, Exchange… whatever is set up in Calendar.app),
/// prompts to record when a meeting starts, and puts to-dos on the calendar.
@MainActor
final class CalendarCenter: ObservableObject {
    /// System calendars and 企业微信, merged.
    @Published private(set) var events: [CalEvent] = []
    private var systemEvents: [CalEvent] = []
    private var wecomEvents: [CalEvent] = []
    @Published private(set) var authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess

    /// Called once per meeting, at its start.
    var onMeetingStarting: ((CalEvent) -> Void)?

    let ek: EKEventStore
    private var subscriptions: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var prompted: Set<String> = []

    static let promptKey = "calendar.promptToRecord"
    var promptsToRecord: Bool {
        get { UserDefaults.standard.object(forKey: Self.promptKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.promptKey)
            objectWillChange.send()
        }
    }

    init(ek: EKEventStore) {
        self.ek = ek
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &subscriptions)
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkStarting()
                if Calendar.current.component(.minute, from: .now) == 0 { self?.reload() }
            }
        }
        reload()
    }

    func requestAccess() async {
        authorized = (try? await ek.requestFullAccessToEvents()) ?? false
        reload()
    }

    /// Today through the next 14 days.
    func reload() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard authorized else {
            systemEvents = []
            merge()
            return
        }
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start)!
        let predicate = ek.predicateForEvents(withStart: start, end: end, calendars: nil)
        systemEvents = ek.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(Self.snapshot)
        merge()
    }

    func setWeCom(_ list: [CalEvent]) {
        wecomEvents = list
        merge()
    }

    /// 企业微信 can also sync into Calendar.app; keep one copy of the same meeting.
    private func merge() {
        let seen = Set(systemEvents.map { "\($0.title)|\($0.start.timeIntervalSince1970)" })
        let extra = wecomEvents.filter { !seen.contains("\($0.title)|\($0.start.timeIntervalSince1970)") }
        events = (systemEvents + extra).sorted { $0.start < $1.start }
    }

    private static func snapshot(_ e: EKEvent) -> CalEvent {
        CalEvent(
            eventID: e.eventIdentifier ?? UUID().uuidString,
            title: e.title?.nonEmpty ?? "（无标题）",
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            location: e.location?.nonEmpty,
            notes: e.notes?.nonEmpty,
            url: e.url,
            attendees: (e.attendees ?? []).compactMap { p in
                p.name?.nonEmpty ?? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            },
            organizer: e.organizer?.name,
            calendarTitle: e.calendar?.title ?? "",
            color: Color(cgColor: e.calendar?.cgColor ?? NSColor.systemBlue.cgColor),
            attendeeEmails: (e.attendees ?? []).compactMap { p in
                let s = p.url.absoluteString
                return s.lowercased().hasPrefix("mailto:") ? String(s.dropFirst(7)).removingPercentEncoding : nil
            }
        )
    }

    func event(_ id: String) -> CalEvent? { events.first { $0.id == id } ?? events.first { $0.eventID == id } }

    /// Timed meetings that haven't ended, soonest first.
    var upcoming: [CalEvent] { events.filter { !$0.isAllDay && $0.end > .now } }

    /// What's on now, or the next thing today.
    var nextToday: CalEvent? {
        upcoming.first { Calendar.current.isDateInToday($0.start) }
    }

    private func checkStarting() {
        guard promptsToRecord else { return }
        let now = Date.now
        for e in upcoming where e.isMeeting && !prompted.contains(e.id) {
            // From one minute before the start until five minutes in.
            if e.start.timeIntervalSince(now) < 60, now.timeIntervalSince(e.start) < 300 {
                prompted.insert(e.id)
                onMeetingStarting?(e)
            }
        }
    }

    // MARK: Writing

    /// Blocks time for a to-do: the hour before its deadline, or tomorrow 10:00 when it has none.
    /// Returns the new event's id.
    func schedule(_ item: TodoItem) throws -> String {
        let cal = Calendar.current
        let start: Date
        if let due = item.dueAt, due.timeIntervalSinceNow > 3600 {
            start = due.addingTimeInterval(-3600)
        } else {
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now))!
            start = cal.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!
        }
        let event = EKEvent(eventStore: ek)
        event.title = item.title
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.notes = [item.notes, item.evidence.map { "原文：\($0)" }, "来自 Aist"].compactMap { $0 }.joined(separator: "\n\n")
        event.calendar = ek.defaultCalendarForNewEvents
        event.addAlarm(EKAlarm(relativeOffset: -600))
        try ek.save(event, span: .thisEvent, commit: true)
        reload()
        return event.eventIdentifier
    }

    /// Opens the event in Calendar.app.
    func reveal(_ e: CalEvent) {
        if e.source == .wecom {
            // Straight to 企业微信's 日程 page (it has no link to a single schedule).
            if let url = URL(string: "wxwork://calendar"), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
            } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.WeWorkMac") {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
            return
        }
        if let url = URL(string: "ical://ekevent/\(e.eventID)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
    }
}
