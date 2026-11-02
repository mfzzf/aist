import Combine
import Foundation

/// Local to-do list persisted as JSON; `CloudSync` mirrors it to iCloud.
@MainActor
public final class TodoStore: ObservableObject {
    @Published public private(set) var items: [TodoItem] = []

    /// After every local edit is saved: ids added or changed, ids removed. Not called for `applyRemote`.
    public var onLocalChange: ((_ changed: Set<UUID>, _ deleted: Set<UUID>) -> Void)?

    private let fileURL: URL
    /// The items as last saved, to tell what an edit changed.
    private var snapshot: [UUID: TodoItem] = [:]

    public init(fileURL: URL = TodoStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([TodoItem].self, from: data) {
            items = decoded
        }
        snapshot = Self.index(items)
    }

    /// Changes that came from another device: written as-is, not reported back to the sync.
    public func applyRemote(upserts: [TodoItem], deletions: Set<UUID>) {
        guard !upserts.isEmpty || !deletions.isEmpty else { return }
        for item in upserts {
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                if items[i] != item { items[i] = item }
            } else {
                items.append(item)
            }
        }
        if !deletions.isEmpty { items.removeAll { deletions.contains($0.id) } }
        save(notify: false)
    }

    private static func index(_ items: [TodoItem]) -> [UUID: TodoItem] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aist/todos.json")
    }

    public nonisolated static var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aist/recordings", isDirectory: true)
    }

    public nonisolated static func folder(for recording: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(recording.uuidString, isDirectory: true)
    }

    /// Completed to-dos, most recently completed first. Nothing is thrown away on completion.
    public var doneItems: [TodoItem] {
        items.filter { $0.status == .done }.sorted {
            ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt)
        }
    }

    /// Open to-dos, most urgent first (see `urgencyRank`), then earliest deadline, then newest.
    public var openItems: [TodoItem] {
        Self.screenOrder(items.filter { $0.status == .open })
    }

    /// The order on screen: most urgent first (see `urgencyRank`), then earliest deadline, then newest.
    public nonisolated static func screenOrder(_ open: [TodoItem], now: Date = .now) -> [TodoItem] {
        open.sorted {
            let ra = Self.urgencyRank($0, now: now), rb = Self.urgencyRank($1, now: now)
            if ra != rb { return ra < rb }
            switch ($0.dueAt, $1.dueAt) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.createdAt > $1.createdAt
            }
        }
    }

    /// Pinned → overdue → due today → due within 2 days → high priority → due this week → medium → low.
    /// Only the first few hang on the rope, so this decides what the user is reminded of.
    public nonisolated static func urgencyRank(_ t: TodoItem, now: Date = .now) -> Int {
        if t.pinned == true { return 0 }
        if let due = t.dueAt {
            if due < now { return 1 }
            if Calendar.current.isDateInToday(due) { return 2 }
            if due.timeIntervalSince(now) < 2 * 86400 { return 3 }
        }
        if t.priority == .high { return 4 }
        if let due = t.dueAt, due.timeIntervalSince(now) < 7 * 86400 { return 5 }
        return t.priority == .medium ? 6 : 7
    }

    /// No deadline and untouched for two weeks: probably no longer relevant.
    public nonisolated static func isStale(_ t: TodoItem, now: Date = .now) -> Bool {
        t.dueAt == nil && t.pinned != true && now.timeIntervalSince(t.updatedAt) > 14 * 86400
    }

    public struct ApplyResult: Sendable {
        public var added: [UUID] = []
        public var updated: [UUID] = []
        public var isEmpty: Bool { added.isEmpty && updated.isEmpty }
    }

    /// Adds new to-dos and merges repeats into existing ones (by the model's duplicate_of, or identical title).
    @discardableResult
    public func apply(_ extracted: [ExtractedTodo], origin: TodoOrigin, meetingID: UUID? = nil,
                      emailRef: EmailRef? = nil, now: Date = .now) -> ApplyResult {
        var result = ApplyResult()
        for e in extracted {
            let dupIndex = e.duplicateOf.flatMap(UUID.init(uuidString:)).flatMap { id in
                items.firstIndex { $0.id == id }
            } ?? items.firstIndex { $0.status == .open && Self.normalize($0.title) == Self.normalize(e.title) }

            if let i = dupIndex {
                var item = items[i]
                let before = item
                if item.dueAt == nil, let due = e.resolvedDueAt { item.dueAt = due }
                if item.dueText == nil { item.dueText = e.dueText }
                if item.requester == nil { item.requester = e.requester }
                if let p = e.priority, p < item.priority { item.priority = p }
                // A repeat (another CI failure, a follow-up email) carries the newest read on the matter.
                if let tip = e.suggestion, !tip.isEmpty { item.suggestion = tip }
                if let ev = e.evidence, !ev.isEmpty, item.evidence != ev, item.origin == origin { item.evidence = ev }
                item.notes = Self.merging(e.details, into: item.notes)
                if item != before {
                    item.updatedAt = now
                    items[i] = item
                    result.updated.append(item.id)
                }
            } else {
                var item = TodoItem(
                    title: e.title, requester: e.requester, source: e.source, dueText: e.dueText,
                    dueAt: e.resolvedDueAt, priority: e.priority ?? .medium, evidence: e.evidence,
                    origin: origin, createdAt: now
                )
                item.meetingID = meetingID
                item.emailRef = emailRef
                item.suggestion = e.suggestion
                item.notes = Self.merging(e.details, into: nil)
                items.append(item)
                result.added.append(item.id)
            }
        }
        if !result.isEmpty { save() }
        return result
    }

    public func setDone(_ id: UUID, _ done: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = done ? .done : .open
        items[i].completedAt = done ? .now : nil
        items[i].updatedAt = .now
        save()
    }

    public func delete(_ id: UUID) {
        delete([id])
    }

    public func delete(_ ids: [UUID]) {
        let set = Set(ids)
        for item in items where set.contains(item.id) {
            for rec in item.recordings ?? [] { try? FileManager.default.removeItem(at: Self.folder(for: rec.id)) }
        }
        items.removeAll { set.contains($0.id) }
        save()
    }

    public func setNotes(_ id: UUID, _ notes: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : notes
        guard items[i].notes != value else { return }
        items[i].notes = value
        items[i].updatedAt = .now
        save()
    }

    /// Returns false if the to-do no longer exists (the caller should discard the audio).
    @discardableResult
    public func addRecording(_ recording: TodoRecording, to id: UUID) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items[i].recordings = (items[i].recordings ?? []) + [recording]
        items[i].updatedAt = .now
        save()
        return true
    }

    public func removeRecording(_ recordingID: UUID, from id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].recordings?.removeAll { $0.id == recordingID }
        if items[i].recordings?.isEmpty == true { items[i].recordings = nil }
        items[i].updatedAt = .now
        save()
        try? FileManager.default.removeItem(at: Self.folder(for: recordingID))
    }

    /// Edit one to-do in place (title, priority, deadline…); bumps `updatedAt`.
    public func update(_ id: UUID, _ change: (inout TodoItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[i]
        change(&item)
        guard item != items[i] else { return }
        item.updatedAt = .now
        items[i] = item
        save()
    }

    /// Adds a fully formed item (e.g. one created in the Reminders app).
    public func insert(_ item: TodoItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        save()
    }

    /// A to-do typed in by hand.
    @discardableResult
    public func addManual(title: String) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let result = apply([ExtractedTodo(title: title)], origin: .manual)
        return result.added.first ?? result.updated.first
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = pinned ? true : nil
        items[i].updatedAt = .now
        save()
    }

    private func save(notify: Bool = true) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(items).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("aist: failed to save todos: \(error)")
        }
        let current = Self.index(items)
        if notify, let onLocalChange {
            let changed = Set(current.compactMap { id, item in snapshot[id] == item ? nil : id })
            let deleted = Set(snapshot.keys).subtracting(current.keys)
            if !changed.isEmpty || !deleted.isEmpty { onLocalChange(changed, deleted) }
        }
        snapshot = current
    }

    /// Adds the AI's details to a to-do's notes, skipping lines that are already there.
    public nonisolated static func merging(_ details: String?, into notes: String?) -> String? {
        let new = (details ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !(notes ?? "").contains($0) }
        guard !new.isEmpty else { return notes }
        let base = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let added = new.joined(separator: "\n")
        return base.isEmpty ? added : base + "\n" + added
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
