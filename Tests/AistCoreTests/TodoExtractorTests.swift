@testable import AistCore
import Foundation
import Testing

@Test func parsesFencedJSONWithProse() throws {
    let raw = """
    好的，以下是待办：
    ```json
    [{"title": "跟 Ahmad 确认 vendor quote", "requester": "Sarah Lim", "source": "Mail",
      "due_text": "最好今天内", "due_at": "2026-11-01T23:59:00+08:00", "priority": "high",
      "evidence": "Also please 跟 Ahmad confirm 一下 vendor quote", "duplicate_of": null}]
    ```
    """
    let todos = try TodoExtractor.parse(raw)
    #expect(todos.count == 1)
    #expect(todos[0].priority == .high)
    #expect(todos[0].resolvedDueAt == ISO8601DateFormatter().date(from: "2026-11-01T15:59:00Z"))
}

@Test func emptyArrayMeansNoTodos() throws {
    #expect(try TodoExtractor.parse("[]").isEmpty)
}

@Test func garbageThrows() {
    #expect(throws: TodoExtractor.ExtractError.self) { try TodoExtractor.parse("sorry, I can't") }
}

@MainActor @Test func duplicatesMergeInsteadOfAdding() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aist-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TodoStore(fileURL: url)

    let first = store.apply([ExtractedTodo(title: "发送 Q4 slides", priority: .medium)], origin: .screenshot)
    #expect(first.added.count == 1)

    let id = first.added[0].uuidString
    let second = store.apply([
        ExtractedTodo(title: "把 Q4 slides 发给 Sarah", dueText: "Thursday 3pm", priority: .high, duplicateOf: id),
        ExtractedTodo(title: "发送 Q4 Slides！"),  // same title modulo case/punctuation
    ], origin: .screenshot)
    #expect(second.added.isEmpty)
    #expect(store.openItems.count == 1)
    #expect(store.openItems[0].priority == .high)
    #expect(store.openItems[0].dueText == "Thursday 3pm")
}

@MainActor @Test func pinnedAndOverdueHangFirst() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aist-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TodoStore(fileURL: url)
    let now = Date.now
    let fmt = ISO8601DateFormatter()
    store.apply([
        ExtractedTodo(title: "low later", priority: .low),
        ExtractedTodo(title: "high no date", priority: .high),
        ExtractedTodo(title: "overdue", dueAt: fmt.string(from: now.addingTimeInterval(-3600)), priority: .low),
        ExtractedTodo(title: "pin me", priority: .low),
    ], origin: .screenshot)
    let pin = try #require(store.items.first { $0.title == "pin me" })
    store.setPinned(pin.id, true)
    #expect(store.openItems.map(\.title) == ["pin me", "overdue", "high no date", "low later"])
}

@MainActor @Test func completedItemsStayInHistory() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aist-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TodoStore(fileURL: url)
    let id = try #require(store.apply([ExtractedTodo(title: "写周报")], origin: .screenshot).added.first)
    store.setNotes(id, "记得附上数据表")
    store.addRecording(TodoRecording(startedAt: .now, duration: 61, hasSystemAudio: true, hasMicrophone: true), to: id)
    store.setDone(id)
    #expect(store.openItems.isEmpty)
    #expect(store.doneItems.map(\.id) == [id])
    #expect(store.doneItems[0].notes == "记得附上数据表")
    #expect(store.doneItems[0].recordings?.count == 1)
    // Survives a reload from disk.
    #expect(TodoStore(fileURL: url).doneItems.first?.recordings?.first?.duration == 61)
    store.setDone(id, false)
    #expect(store.openItems.map(\.id) == [id])
}

@Test func parsesMeetingMinutes() throws {
    let raw = """
    ```json
    {"title": "Q4 汇报准备", "overview": "确认了 Q4 汇报的分工。", "key_points": ["slides 周三前定稿"],
     "decisions": ["由我负责 slides"], "open_questions": [],
     "my_todos": [{"title": "周三前把 Q4 slides 发给 Sarah", "requester": "Sarah", "source": null,
                   "due_text": "下周三之前", "due_at": "2026-11-04T18:00:00+08:00", "priority": "high",
                   "evidence": "我们下周三之前要把 Q4 slides 发给 Sarah", "duplicate_of": null}],
     "others_todos": [{"who": "Ahmad", "task": "跟 vendor 确认 quote", "due_text": "明天"}]}
    ```
    """
    let out = try MeetingSummarizer.parse(raw)
    #expect(out.title == "Q4 汇报准备")
    #expect(out.myTodos.count == 1)
    #expect(out.myTodos[0].resolvedDueAt != nil)
    #expect(out.summary.othersActions.first?.who == "Ahmad")
    #expect(out.summary.openQuestions.isEmpty)
}

@Test func parsesAnalysisEnvelope() throws {
    let raw = """
    {"analysis": "Sophia 问测试归属，用户已答「嗯」，了结；收拾桌子用户回「1」接下。",
     "todos": [{"title": "找行政小助手安排阿姨收拾桌子", "requester": "Sophia", "source": "企业微信",
                "due_text": null, "due_at": null, "priority": "medium", "evidence": "直接找行政小助手", "duplicate_of": null}]}
    """
    let todos = try TodoExtractor.parse(raw)
    #expect(todos.map(\.title) == ["找行政小助手安排阿姨收拾桌子"])
    #expect(try TodoExtractor.parse(#"{"analysis": "纯通知", "todos": []}"#).isEmpty)
}

@Test func promptCarriesIdentityAndSourceNotes() {
    let p = TodoPrompt.extraction(.screenshot, identity: ["张三", "alex.zhang"], now: .now, timeZone: .current)
    #expect(p.contains("张三、alex.zhang"))
    #expect(p.contains("右侧"))
    #expect(!TodoPrompt.extraction(.email, identity: [], now: .now, timeZone: .current).contains("右侧（通常蓝/绿色）"))
}
