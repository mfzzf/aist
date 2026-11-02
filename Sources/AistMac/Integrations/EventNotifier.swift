import AppKit
import Combine
import UserNotifications

/// System notifications (top-right banners) for the merged 日程: a heads-up when a new schedule
/// appears, and reminders 15 and 5 minutes before each one starts.
@MainActor
final class EventNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var remindBefore15: Bool { didSet { save(); reschedule() } }
    @Published var remindBefore5: Bool { didSet { save(); reschedule() } }
    @Published var notifyNew: Bool { didSet { save() } }
    @Published private(set) var denied = false

    /// Tapping a notification (or its 录音 action).
    var onOpen: ((CalEvent) -> Void)?
    var onRecord: ((CalEvent) -> Void)?

    private let calendar: CalendarCenter
    private let center = UNUserNotificationCenter.current()
    private var subscription: AnyCancellable?
    private var events: [CalEvent] = []
    /// eventIDs seen before, so only genuinely new schedules are announced. nil until the first load.
    private var known: Set<String>?

    private static let prefix = "aist.event."
    private static let knownKey = "notify.knownEvents"

    init(calendar: CalendarCenter) {
        self.calendar = calendar
        let d = UserDefaults.standard
        d.register(defaults: ["notify.before15": true, "notify.before5": true, "notify.new": true])
        remindBefore15 = d.bool(forKey: "notify.before15")
        remindBefore5 = d.bool(forKey: "notify.before5")
        notifyNew = d.bool(forKey: "notify.new")
        if let saved = d.stringArray(forKey: Self.knownKey) { known = Set(saved) }
        super.init()

        center.delegate = self
        let record = UNNotificationAction(identifier: "record", title: "开始录音", options: [.foreground])
        let join = UNNotificationAction(identifier: "join", title: "加入会议", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "event", actions: [record], intentIdentifiers: []),
            UNNotificationCategory(identifier: "meeting", actions: [join, record], intentIdentifiers: []),
        ])
        // First launch asks in the onboarding's 权限 step instead of out of nowhere.
        if UserDefaults.standard.bool(forKey: Onboarding.doneKey) {
            Task {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                denied = !granted
            }
        }
        subscription = calendar.$events
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] list in self?.update(list) }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(remindBefore15, forKey: "notify.before15")
        d.set(remindBefore5, forKey: "notify.before5")
        d.set(notifyNew, forKey: "notify.new")
    }

    private func update(_ list: [CalEvent]) {
        events = list
        announceNew(list)
        reschedule()
    }

    /// Banner for schedules that weren't there on the previous refresh (the first load only records).
    private func announceNew(_ list: [CalEvent]) {
        let upcoming = list.filter { $0.end > .now }
        let ids = Set(upcoming.map(\.eventID))
        defer {
            // Remember past ones too for a while, so an edit that moves an event doesn't re-announce it.
            known = ids.union(known ?? []).intersection(Set(list.map(\.eventID)))
            UserDefaults.standard.set(Array(known ?? []), forKey: Self.knownKey)
        }
        guard notifyNew, let known, !list.isEmpty else { return }
        let fresh = upcoming.filter { !known.contains($0.eventID) && !$0.isAllDay }
        for e in fresh.prefix(5) {
            post(id: "\(Self.prefix)new.\(e.id)", event: e, title: "新日程：\(e.title)", body: Self.when(e), at: nil)
        }
    }

    /// Replaces all pending reminders with ones for the next events (macOS keeps at most 64 pending).
    private func reschedule() {
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            var offsets: [Int] = []
            if remindBefore15 { offsets.append(15) }
            if remindBefore5 { offsets.append(5) }
            guard !offsets.isEmpty else { return }
            let next = events.filter { !$0.isAllDay && $0.start > .now }.sorted { $0.start < $1.start }.prefix(25)
            for e in next {
                for minutes in offsets {
                    let fire = e.start.addingTimeInterval(TimeInterval(-minutes * 60))
                    guard fire > .now.addingTimeInterval(5) else { continue }
                    var body = Self.when(e)
                    if let place = e.location { body += " · \(place)" }
                    post(id: "\(Self.prefix)\(minutes).\(e.id)", event: e,
                         title: "\(minutes) 分钟后：\(e.title)", body: body, at: fire)
                }
            }
        }
    }

    private func post(id: String, event: CalEvent, title: String, body: String, at date: Date?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = event.joinURL != nil ? "meeting" : "event"
        content.userInfo = ["event": event.id]
        content.threadIdentifier = "calendar"
        if event.source == .wecom { content.subtitle = "企业微信" }
        let trigger = date.map {
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0),
                repeats: false)
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private static func when(_ e: CalEvent) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(e.start) ? "今天" : cal.isDateInTomorrow(e.start) ? "明天"
            : e.start.formatted(.dateTime.month().day().weekday(.abbreviated))
        return "\(day) \(DueFormatter.time(e.start)) – \(DueFormatter.time(e.end))"
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while Aist is the active app (it's a menu-bar app, so often is).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["event"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let id, let event = calendar.event(id) else { return }
            switch action {
            case "join": if let url = event.joinURL { NSWorkspace.shared.open(url) }
            case "record": onRecord?(event)
            default: onOpen?(event)
            }
        }
    }
}
