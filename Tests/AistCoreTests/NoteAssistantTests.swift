@testable import AistCore
import Foundation
import Testing

private func item(_ title: String, due: Date? = nil, priority: TodoPriority = .medium, done: Bool = false) -> TodoItem {
    var t = TodoItem(title: title, requester: nil, source: nil, dueText: nil, dueAt: due, priority: priority,
                     evidence: nil, origin: .manual, createdAt: .now)
    if done {
        t.status = .done
        t.completedAt = .now
    }
    return t
}

@Test func listingNumbersInScreenOrderAndResolvesHandles() throws {
    let parcel = item("今晚去拿快递", due: Date().addingTimeInterval(3600), priority: .high)
    let quote = item("把报价发给 Kevin")
    let expenses = item("交季度报销", done: true)
    let todos = [quote, parcel, expenses] // store order ≠ screen order
    let listing = NoteAssistant.listing(todos)

    let lines = listing.text.split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0].hasPrefix("#1 今晚去拿快递"))
    #expect(lines[1].hasPrefix("#2 把报价发给 Kevin"))
    #expect(lines[2].hasPrefix("#3 交季度报销") && lines[2].contains("已完成"))
    #expect(listing.handles["#1"] == parcel.id)

    let raw = NoteResult(
        reply: "好",
        complete: [.init(id: "#2")],
        reopen: [.init(id: "3")],
        update: [.init(id: "#1 今晚去拿快递", title: "去拿快递", dueText: nil, dueAt: nil, priority: nil, details: nil, reason: nil)],
        remove: [.init(id: "#9", reason: "牙医那条")]
    )
    let resolved = NoteAssistant.resolve(raw, listing: listing, todos: todos)
    #expect(resolved.complete.map(\.id) == [quote.id.uuidString])
    #expect(resolved.reopen.map(\.id) == [expenses.id.uuidString])
    #expect(resolved.update.map(\.id) == [parcel.id.uuidString])
    #expect(resolved.remove.isEmpty)
    #expect(resolved.unresolved == ["牙医那条"])
}

@Test func handlesComeInManySpellings() {
    #expect(NoteAssistant.handle(in: "#3") == "#3")
    #expect(NoteAssistant.handle(in: "＃12") == "#12")
    #expect(NoteAssistant.handle(in: "t2") == "#2")
    #expect(NoteAssistant.handle(in: "7") == "#7")
    #expect(NoteAssistant.handle(in: "#3 把报价发给 Kevin") == "#3")
    #expect(NoteAssistant.handle(in: "#3「把报价发给 Kevin」") == "#3")
    #expect(NoteAssistant.handle(in: UUID().uuidString) == nil)
    #expect(NoteAssistant.handle(in: "把报价发给 Kevin") == nil)
    #expect(NoteAssistant.handle(in: "3rd") == nil)
}

@Test func addedItemsGetTheNoteSourceAndTitlesResolveAsLastResort() {
    let quote = item("把报价发给 Kevin")
    let listing = NoteAssistant.listing([quote])
    let raw = NoteResult(add: [ExtractedTodo(title: "买猫粮")], complete: [.init(id: "「把报价发给 Kevin」")])
    let resolved = NoteAssistant.resolve(raw, listing: listing, todos: [quote])
    #expect(resolved.add.first?.source == "随手记")
    #expect(resolved.complete.map(\.id) == [quote.id.uuidString])
    #expect(resolved.unresolved.isEmpty)
}

@Test func decodeToleratesMissingArrays() throws {
    let json = Data(#"{"analysis": "问清单", "reply": "今天还有 2 件。"}"#.utf8)
    let r = try JSONDecoder().decode(NoteResult.self, from: json)
    #expect(r.add.isEmpty && r.complete.isEmpty && r.reopen.isEmpty && r.update.isEmpty && r.remove.isEmpty)
    #expect(r.suggestions.isEmpty && r.unresolved.isEmpty)
    #expect(r.reply == "今天还有 2 件。")
    #expect(!r.isEmpty)
}

@MainActor @Test func applyingANoteCanBeUndone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aist-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TodoStore(fileURL: url)
    let ids = store.apply([ExtractedTodo(title: "寄样品给 Acme"), ExtractedTodo(title: "订会议室")], origin: .manual).added

    let result = NoteResult(
        reply: "好的",
        add: [ExtractedTodo(title: "周五前把报价发给 Kevin")],
        complete: [.init(id: ids[0].uuidString)],
        update: [.init(id: ids[1].uuidString, title: "订周三的会议室")],
        remove: [.init(id: UUID().uuidString)],  // made up: skipped
        unresolved: ["上周那个"]
    )
    let report = store.apply(result, said: "报价周五前发给 Kevin，样品寄了，会议室改周三")
    #expect(report.added.count == 1)
    #expect(report.completed == [ids[0]])
    #expect(report.changed == [ids[1]])
    #expect(report.removed.isEmpty)
    #expect(report.reply == "好的\n没找到对应的待办：上周那个")
    #expect(store.describe(report).contains("新增「周五前把报价发给 Kevin」"))

    store.undo(report)
    #expect(store.openItems.map(\.title).sorted() == ["寄样品给 Acme", "订会议室"].sorted())
}
