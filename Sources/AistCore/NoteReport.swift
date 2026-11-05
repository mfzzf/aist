import Foundation

/// What one note (typed or spoken to Aist) did to the list, kept so it can be shown and undone.
public struct NoteReport: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var text: String
    public var reply: String?
    public var added: [UUID] = []
    /// New items the AI recognised as repeats and merged into existing ones.
    public var merged: [UUID] = []
    public var completed: [UUID] = []
    /// Finished items the note said weren't actually done.
    public var reopened: [UUID] = []
    public var changed: [UUID] = []
    public var removed: [TodoItem] = []
    public var suggestions: [ExtractedTodo] = []
    /// Existing items as they were before this note touched them.
    public var before: [TodoItem] = []

    public init(text: String, reply: String? = nil, suggestions: [ExtractedTodo] = []) {
        self.text = text
        self.reply = reply
        self.suggestions = suggestions
    }

    public var hasChanges: Bool {
        !added.isEmpty || !merged.isEmpty || !completed.isEmpty || !reopened.isEmpty || !changed.isEmpty || !removed.isEmpty
    }

    public var rowCount: Int {
        added.count + merged.count + completed.count + reopened.count + changed.count + removed.count + suggestions.count
    }
}

extension TodoStore {
    /// Carries out what the AI read from a note. Ids it made up or that no longer exist are skipped.
    public func apply(_ result: NoteResult, said text: String) -> NoteReport {
        let prior = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var report = NoteReport(text: text, reply: result.reply?.trimmingCharacters(in: .whitespacesAndNewlines),
                                suggestions: result.suggestions)
        func existing(_ id: String) -> UUID? {
            UUID(uuidString: id).flatMap { prior[$0] != nil ? $0 : nil }
        }

        let added = apply(result.add, origin: .manual)
        report.added = added.added
        report.merged = added.updated

        for ref in result.complete {
            guard let id = existing(ref.id), prior[id]?.status == .open else { continue }
            setDone(id)
            report.completed.append(id)
        }
        for ref in result.reopen {
            guard let id = existing(ref.id), prior[id]?.status == .done else { continue }
            setDone(id, false)
            report.reopened.append(id)
        }
        for change in result.update {
            guard let id = existing(change.id) else { continue }
            update(id) { item in
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
            delete(id)
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

    /// Puts everything back the way it was before the note.
    public func undo(_ report: NoteReport) {
        delete(report.added)
        for item in report.before { update(item.id) { $0 = item } }
        for item in report.removed { insert(item) }
    }

    /// What a note did, in words the model can match against the list (titles, not ids) — the `did`
    /// of the next `NoteAssistant.Turn`.
    public func describe(_ r: NoteReport) -> String {
        func titles(_ ids: [UUID]) -> String {
            ids.compactMap { id in items.first { $0.id == id }?.title }.map { "「\($0)」" }.joined()
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
}
