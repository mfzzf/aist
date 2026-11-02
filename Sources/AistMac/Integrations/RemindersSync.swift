import AistCore
import AppKit
import Combine
import EventKit

/// Two-way sync between aist's to-dos and an "aist" list in the system Reminders app.
/// The list lives in the default (usually iCloud) account, so iCloud carries it to iPhone,
/// iPad and Apple Watch; ticking an item off anywhere comes back here.
///
/// Every pass compares fields; when an item and its reminder disagree, the newer edit wins
/// (`TodoItem.updatedAt` vs `EKReminder.lastModifiedDate`).
@MainActor
final class RemindersSync: ObservableObject {
    enum Status: Equatable {
        case off
        case denied
        case on(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastSync: Date?

    private let ek: EKEventStore
    private let store: TodoStore
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: DispatchWorkItem?
    private var running = false

    private static let enabledKey = "remindersSync.enabled"
    private static let listKey = "remindersSync.listID"

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    init(ek: EKEventStore, store: TodoStore) {
        self.ek = ek
        self.store = store
        store.$items.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &subscriptions)
        if isEnabled, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { schedule(after: 0.5) }
    }

    func enable() async {
        do {
            guard try await ek.requestFullAccessToReminders() else {
                status = .denied
                return
            }
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        await reconcile()
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        status = .off
    }

    /// Debounced: edits come in bursts (typing a title, a sync from iCloud).
    func schedule(after delay: Double = 1.0) {
        guard isEnabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { await self?.reconcile() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Sync

    private func reconcile() async {
        guard isEnabled, !running else { return }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            status = .denied
            return
        }
        running = true
        defer { running = false }
        do {
            let list = try ensureList()
            var remaining = Dictionary(uniqueKeysWithValues: await fetch(list).map { ($0.calendarItemIdentifier, $0) })
            var changed = false

            for item in store.items {
                if let rid = item.reminderID {
                    if let reminder = remaining.removeValue(forKey: rid) {
                        changed = sync(item, reminder) || changed
                    } else {
                        // Gone from Reminders (deleted on some device): keep the to-do, as done, unlinked.
                        store.update(item.id) { $0.reminderID = nil }
                        if item.status == .open { store.setDone(item.id, true) }
                    }
                } else if item.status == .open {
                    let reminder = EKReminder(eventStore: ek)
                    reminder.calendar = list
                    push(item, to: reminder)
                    try ek.save(reminder, commit: false)
                    changed = true
                    store.update(item.id) { $0.reminderID = reminder.calendarItemIdentifier }
                }
            }

            // New in Reminders (added on iPhone, by Siri…): becomes a to-do.
            for reminder in remaining.values where !reminder.isCompleted {
                var item = TodoItem(
                    title: reminder.title ?? "（无标题）",
                    dueAt: Self.date(reminder.dueDateComponents),
                    priority: Self.priority(reminder.priority),
                    origin: .manual,
                    createdAt: reminder.creationDate ?? .now
                )
                item.notes = reminder.notes
                item.source = "提醒事项"
                item.reminderID = reminder.calendarItemIdentifier
                store.insert(item)
            }

            if changed { try ek.commit() }
            status = .on(list.title)
            lastSync = .now
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Returns true if the reminder was changed (needs a commit).
    private func sync(_ item: TodoItem, _ reminder: EKReminder) -> Bool {
        guard !same(item, reminder) else { return false }
        let remoteNewer = (reminder.lastModifiedDate ?? .distantPast) > item.updatedAt
        if remoteNewer {
            let done = reminder.isCompleted
            store.update(item.id) {
                $0.title = reminder.title?.nonEmpty ?? $0.title
                $0.dueAt = Self.date(reminder.dueDateComponents)
                $0.priority = Self.priority(reminder.priority)
                $0.notes = reminder.notes?.nonEmpty
            }
            if done != (item.status == .done) { store.setDone(item.id, done) }
            return false
        }
        push(item, to: reminder)
        try? ek.save(reminder, commit: false)
        return true
    }

    private func same(_ item: TodoItem, _ r: EKReminder) -> Bool {
        let due = Self.date(r.dueDateComponents)
        let sameDue: Bool = switch (due, item.dueAt) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 60
        default: false
        }
        return (r.title ?? "") == item.title
            && sameDue
            && r.isCompleted == (item.status == .done)
            && Self.priority(r.priority) == item.priority
            && (r.notes?.nonEmpty) == (item.notes?.nonEmpty)
    }

    private func push(_ item: TodoItem, to r: EKReminder) {
        r.title = item.title
        r.notes = item.notes
        r.priority = switch item.priority {
        case .high: 1
        case .medium: 5
        case .low: 9
        }
        if let due = item.dueAt {
            r.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .timeZone], from: due)
            // An alarm at the deadline: the iPhone / Watch notification.
            r.alarms?.forEach { r.removeAlarm($0) }
            if due > .now { r.addAlarm(EKAlarm(absoluteDate: due)) }
        } else {
            r.dueDateComponents = nil
            r.alarms?.forEach { r.removeAlarm($0) }
        }
        if r.isCompleted != (item.status == .done) {
            r.isCompleted = item.status == .done
            r.completionDate = item.status == .done ? (item.completedAt ?? .now) : nil
        }
    }

    // MARK: Helpers

    /// The "aist" list, created in the default reminders account (iCloud when signed in).
    private func ensureList() throws -> EKCalendar {
        if let id = UserDefaults.standard.string(forKey: Self.listKey), let list = ek.calendar(withIdentifier: id) {
            return list
        }
        if let existing = ek.calendars(for: .reminder).first(where: { $0.title == "aist" }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: Self.listKey)
            return existing
        }
        let list = EKCalendar(for: .reminder, eventStore: ek)
        list.title = "aist"
        list.cgColor = NSColor.systemIndigo.cgColor
        let iCloud = ek.sources.first { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }
        guard let source = ek.defaultCalendarForNewReminders()?.source ?? iCloud ?? ek.sources.first(where: { $0.sourceType == .local })
        else { throw NSError(domain: "aist", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到可用的提醒事项账户"]) }
        list.source = source
        try ek.saveCalendar(list, commit: true)
        UserDefaults.standard.set(list.calendarIdentifier, forKey: Self.listKey)
        return list
    }

    private func fetch(_ list: EKCalendar) async -> [EKReminder] {
        let predicate = ek.predicateForReminders(in: [list])
        return await withCheckedContinuation { continuation in
            ek.fetchReminders(matching: predicate) { reminders in
                nonisolated(unsafe) let result = reminders ?? []
                continuation.resume(returning: result)
            }
        }
    }

    /// A date-only reminder means "that day"; aist reads it as 18:00 like the extractor does.
    private static func date(_ components: DateComponents?) -> Date? {
        guard var c = components, c.year != nil, c.month != nil, c.day != nil else { return nil }
        if c.hour == nil {
            c.hour = 18
            c.minute = 0
        }
        return Calendar.current.date(from: c)
    }

    private static func priority(_ value: Int) -> TodoPriority {
        switch value {
        case 1...4: .high
        case 6...9: .low
        default: .medium
        }
    }
}
