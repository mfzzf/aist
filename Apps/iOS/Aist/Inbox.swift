import AistCore
import Foundation

/// What the user typed or said, waiting for the AI. Saved to disk first, so nothing is lost when the
/// network or the AI is down; processed one at a time, oldest first.
struct PendingNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var voice: Bool
    /// Attached images, JPEG files in `Inbox.imageFolder` (removed once the note is handled).
    var images: [String]?
    var createdAt = Date()
    var error: String?
}

/// What one note did to the list, for the result card and its undo.
struct NoteReport: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var reply: String?
    var added: [UUID] = []
    /// New items the AI recognised as repeats and merged into existing ones.
    var merged: [UUID] = []
    var completed: [UUID] = []
    /// Finished items the note said weren't actually done.
    var reopened: [UUID] = []
    var changed: [UUID] = []
    var removed: [TodoItem] = []
    var suggestions: [ExtractedTodo] = []
    /// Existing items as they were before this note touched them.
    var before: [TodoItem] = []

    var hasChanges: Bool { !added.isEmpty || !merged.isEmpty || !completed.isEmpty || !reopened.isEmpty || !changed.isEmpty || !removed.isEmpty }
    var rowCount: Int { added.count + merged.count + completed.count + reopened.count + changed.count + removed.count + suggestions.count }
}

@MainActor
final class Inbox: ObservableObject {
    enum Outcome: Equatable {
        case report(NoteReport)
        case failed(id: UUID, message: String, needsSetup: Bool)
    }

    @Published private(set) var pending: [PendingNote] = []
    @Published private(set) var working: PendingNote?
    @Published var outcome: Outcome?

    private let store: TodoStore
    private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("aist/inbox.json")
    private var running = false
    /// The last few exchanges, so 「刚才那个改成周三」 can refer back to them.
    private var turns: [NoteAssistant.Turn] = []

    init(store: TodoStore) {
        self.store = store
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([PendingNote].self, from: data) {
            pending = saved
        }
        if Demo.report { outcome = .report(Self.demoReport(store)) }
    }

    /// Screenshot data: a mixed note against whatever is in the list.
    private static func demoReport(_ store: TodoStore) -> NoteReport {
        let open = store.openItems.map(\.id)
        let day = { (d: Int, h: Int) in
            Calendar.current.date(bySettingHour: h, minute: 0, second: 0,
                                  of: Calendar.current.date(byAdding: .day, value: d, to: .now)!)!
        }
        let iso = ISO8601DateFormatter()
        var r = NoteReport(text: "报价发了。快递改到明天。下周一去新加坡出差，帮我想想要准备什么",
                           reply: "「发报价」已勾掉，快递挪到明天。出差按「证件 → 机酒 → 落地」排了 4 条，挑几条加上吧。")
        r.added = Array(open.suffix(1))
        r.completed = Array(open.prefix(1))
        r.changed = Array(open.dropFirst().prefix(1))
        r.suggestions = [
            ExtractedTodo(title: "确认护照有效期和新加坡签证", dueAt: iso.string(from: day(3, 18)), priority: .high),
            ExtractedTodo(title: "订往返机票和酒店", dueAt: iso.string(from: day(1, 18)), priority: .high),
            ExtractedTodo(title: "填新加坡入境卡 SG Arrival Card", dueAt: iso.string(from: day(5, 9)), priority: .medium),
            ExtractedTodo(title: "开通境外漫游或买 eSIM", priority: .low),
        ]
        return r
    }

    static let imageFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("aist/inbox", isDirectory: true)

    func submit(_ text: String, voice: Bool, images: [Data] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.imageFolder, withIntermediateDirectories: true)
        let files = images.compactMap { data -> String? in
            let name = UUID().uuidString + ".jpg"
            return (try? data.write(to: Self.imageFolder.appendingPathComponent(name))) != nil ? name : nil
        }
        pending.append(PendingNote(text: text, voice: voice, images: files.isEmpty ? nil : files))
        save()
        Task { await process() }
    }

    private func images(of note: PendingNote) -> [Data] {
        (note.images ?? []).compactMap { try? Data(contentsOf: Self.imageFolder.appendingPathComponent($0)) }
    }

    private func removeImages(of note: PendingNote) {
        for name in note.images ?? [] { try? FileManager.default.removeItem(at: Self.imageFolder.appendingPathComponent(name)) }
    }

    /// Works through the queue; stops at the first failure (usually no network or no key) and leaves
    /// the rest for the next try.
    func process() async {
        guard !running else { return }
        running = true
        defer { running = false; working = nil }
        while let note = pending.first {
            working = note
            do {
                let assistant = NoteAssistant(client: LLMClient(config: try Self.config()), identity: Profile.names)
                let result = try await assistant.handle(note.text, images: images(of: note), todos: store.items, recent: turns)
                removeImages(of: note)
                pending.removeAll { $0.id == note.id }
                save()
                let report = apply(result, text: note.text)
                remember(note.text, report)
                outcome = .report(report)
                report.hasChanges || !report.suggestions.isEmpty ? Haptics.success() : Haptics.warning()
            } catch {
                if let i = pending.firstIndex(where: { $0.id == note.id }) {
                    pending[i].error = error.localizedDescription
                    save()
                }
                outcome = .failed(id: note.id, message: error.localizedDescription,
                                  needsSetup: error is LLMConfig.ConfigError)
                return
            }
        }
    }

    /// Carries out what the AI read from the note. Ids it made up or that no longer exist are skipped.
    private func apply(_ result: NoteResult, text: String) -> NoteReport {
        let prior = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var report = NoteReport(text: text, reply: result.reply?.trimmingCharacters(in: .whitespacesAndNewlines),
                                suggestions: result.suggestions)
        func existing(_ id: String) -> UUID? {
            UUID(uuidString: id).flatMap { prior[$0] != nil ? $0 : nil }
        }

        let added = store.apply(result.add, origin: .manual)
        report.added = added.added
        report.merged = added.updated

        for ref in result.complete {
            guard let id = existing(ref.id), prior[id]?.status == .open else { continue }
            store.setDone(id)
            report.completed.append(id)
        }
        for ref in result.reopen {
            guard let id = existing(ref.id), prior[id]?.status == .done else { continue }
            store.setDone(id, false)
            report.reopened.append(id)
        }
        for change in result.update {
            guard let id = existing(change.id) else { continue }
            store.update(id) { item in
                if let title = change.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { item.title = title }
                if let due = change.resolvedDueAt {
                    item.dueAt = due
                    item.dueText = change.dueText
                }
                if let priority = change.priority { item.priority = priority }
                item.notes = TodoStore.merging(change.details, into: item.notes)
            }
            report.changed.append(id)
        }
        for ref in result.remove {
            guard let id = existing(ref.id), let item = prior[id] else { continue }
            store.delete(id)
            report.removed.append(item)
        }
        report.before = (report.merged + report.completed + report.reopened + report.changed).compactMap { prior[$0] }
        if !result.unresolved.isEmpty {
            let missing = "没找到对应的待办：" + result.unresolved.joined(separator: "、")
            let base = (report.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            report.reply = base.isEmpty ? missing : base + "\n" + missing
        }
        return report
    }

    /// Keeps the last few exchanges for the next note's 「刚才那个」.
    private func remember(_ said: String, _ report: NoteReport) {
        turns.append(NoteAssistant.Turn(said: said, did: Self.describe(report, in: store)))
        turns = Array(turns.suffix(5))
    }

    /// What a note did, in words the model can match against the list (titles, not ids).
    static func describe(_ r: NoteReport, in store: TodoStore) -> String {
        func titles(_ ids: [UUID]) -> String {
            ids.compactMap { id in store.items.first { $0.id == id }?.title }.map { "「\($0)」" }.joined()
        }
        var parts: [String] = []
        if !r.added.isEmpty { parts.append("新增" + titles(r.added)) }
        if !r.merged.isEmpty { parts.append("并入已有的" + titles(r.merged)) }
        if !r.completed.isEmpty { parts.append("勾掉" + titles(r.completed)) }
        if !r.reopened.isEmpty { parts.append("恢复" + titles(r.reopened)) }
        if !r.changed.isEmpty { parts.append("修改" + titles(r.changed)) }
        if !r.removed.isEmpty { parts.append("取消" + r.removed.map { "「\($0.title)」" }.joined()) }
        if !r.suggestions.isEmpty { parts.append("给了 \(r.suggestions.count) 条建议让用户挑") }
        if let reply = r.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty { parts.append("回复「\(reply.prefix(120))」") }
        return parts.isEmpty ? "什么都没改" : parts.joined(separator: "；")
    }

    /// Puts everything back the way it was before the note.
    func undo(_ report: NoteReport) {
        store.delete(report.added)
        for item in report.before { store.update(item.id) { $0 = item } }
        for item in report.removed { store.insert(item) }
        outcome = nil
    }

    /// Adds the suggestions the user ticked; the card then shows them as added.
    func accept(_ picks: [ExtractedTodo], from report: NoteReport) {
        let result = store.apply(picks, origin: .manual)
        var updated = report
        updated.suggestions = []
        updated.added += result.added
        updated.merged += result.updated
        outcome = updated.hasChanges ? .report(updated) : nil
        if !picks.isEmpty {
            turns.append(NoteAssistant.Turn(said: "（从你的建议里挑了 \(picks.count) 条）",
                                            did: "新增" + picks.map { "「\($0.title)」" }.joined()))
        }
        Haptics.success()
    }

    /// Keep the words as one plain to-do when the AI found nothing.
    func keepAsTodo(_ text: String) {
        store.addManual(title: String(text.prefix(60)))
        outcome = nil
    }

    func discard(_ id: UUID) {
        if let note = pending.first(where: { $0.id == id }) { removeImages(of: note) }
        pending.removeAll { $0.id == id }
        save()
        if case let .failed(failed, _, _) = outcome, failed == id { outcome = nil }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
    }

    /// The provider chosen in Settings, with its key from the Keychain.
    static func config() throws -> LLMConfig {
        guard let provider = LLMProviderStore.load().current else { throw LLMConfig.ConfigError.missingKey("AI") }
        let config = provider.config
        if provider.needsKey, (config.apiKey ?? "").isEmpty { throw LLMConfig.ConfigError.missingKey(provider.name) }
        if config.model.isEmpty { throw LLMConfig.ConfigError.missingModel(provider.name) }
        return config
    }
}

/// The names the user goes by, so 「老板让 Alex…」 is understood as the user.
enum Profile {
    static let namesKey = "profile.names"

    static var names: [String] {
        (UserDefaults.standard.string(forKey: namesKey) ?? "")
            .split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
