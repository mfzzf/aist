import AistAI
@testable import AistAgent
import XCTest

final class ConversationStoreTests: XCTestCase {
    func testAppendSearchTruncateDelete() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ConversationStore(url: url)
        let c = try await store.create(title: "周末计划")
        var a = AssistantMessage(api: .anthropicMessages, provider: "p", model: "m")
        a.content = [.text("可以去植物园散步")]
        try await store.append([.user(UserMessage("周末去哪儿玩")), .assistant(a)], to: c.id)
        try await store.append([.user(UserMessage("下雨怎么办"))], to: c.id)

        let back = try await store.messages(of: c.id)
        XCTAssertEqual(back.count, 3)
        let byBody = try await store.search("植物园")
        let byTitle = try await store.search("周末")
        let none = try await store.search("火星基地")
        let otherScope = try await store.conversations(scope: "mail:1")
        XCTAssertEqual(byBody.map(\.id), [c.id], "message text via FTS trigram")
        XCTAssertEqual(byTitle.map(\.id), [c.id], "short query matches the title")
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(otherScope.isEmpty, "scopes are separate")

        try await store.truncate(c.id, keeping: 2)
        let kept = try await store.messages(of: c.id)
        XCTAssertEqual(kept.count, 2)
        try await store.delete(c.id)
        let left = try await store.conversations()
        XCTAssertTrue(left.isEmpty)
    }
}

final class WebToolTests: XCTestCase {
    func testDuckDuckGoHTML() {
        let html = """
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&amp;rut=1">Example <b>Page</b></a>
        <a class="result__snippet" href="x">A &amp; B snippet</a>
        """
        let r = WebSearch.parseDuckDuckGo(html)
        XCTAssertEqual(r.first?.url, "https://example.com/page")
        XCTAssertEqual(r.first?.title, "Example Page")
        XCTAssertEqual(r.first?.snippet, "A & B snippet")
    }

    func testDuckDuckGoLite() {
        let html = """
        <a rel="nofollow" href="https://example.org/a?x=1&amp;y=2" class='result-link'>Title A</a>
        <td class='result-snippet'>Snippet A</td>
        """
        let r = WebSearch.parseDuckDuckGoLite(html)
        XCTAssertEqual(r.first?.url, "https://example.org/a?x=1&y=2")
        XCTAssertEqual(r.first?.snippet, "Snippet A")
    }

    func testHTMLToText() {
        let page = HTMLText.page("""
        <html><head><title>标题 &amp; 副标题</title><script>var x=1</script></head>
        <body><nav>菜单</nav><h2>小节</h2><p>第一段&#x4E00;</p><ul><li>甲</li><li>乙</li></ul></body></html>
        """, fallbackTitle: "x")
        XCTAssertEqual(page.title, "标题 & 副标题")
        XCTAssertTrue(page.text.contains("## 小节"))
        XCTAssertTrue(page.text.contains("第一段一"))
        XCTAssertTrue(page.text.contains("- 甲"))
        XCTAssertFalse(page.text.contains("菜单"))
        XCTAssertFalse(page.text.contains("var x"))
    }

    func testSetupPrefersHostedSearch() {
        let ds = Catalog.model(id: "deepseek-flash", provider: "deepseek", api: .anthropicMessages,
                               baseURL: URL(string: "https://api.deepseek.com/anthropic")!)
        let s = WebTools.setup(WebConfig(backend: .auto), for: ds)
        XCTAssertEqual(s.hosted, [.webSearch])
        XCTAssertEqual(s.tools.map(\.tool.name), ["fetch_page"])
        let other = Catalog.model(id: "m", provider: "x", api: .openaiCompletions, baseURL: URL(string: "https://example.com/v1")!)
        XCTAssertEqual(WebTools.setup(WebConfig(backend: .auto, tavilyKey: "k"), for: other).tools.map(\.tool.name), ["web_search", "fetch_page"])
        XCTAssertTrue(WebTools.setup(WebConfig(backend: .off), for: other).tools.isEmpty)
    }
}

/// The loop with a scripted model: one tool call, then an answer.
final class AgentLoopTests: XCTestCase {
    func testRunsToolThenAnswers() async {
        let fake = Model(id: "fake", api: .openaiCompletions, provider: "fake-provider", baseURL: URL(string: "https://fake.invalid")!)
        // Replace the protocol's implementation for this test only.
        ApiRegistry.register(.openaiCompletions) { model, ctx, _ in
            AsyncStream { c in
                var m = AssistantMessage(for: model)
                if ctx.messages.contains(where: { if case .toolResult = $0 { true } else { false } }) {
                    m.content = [.text("答案是 42")]
                    m.stopReason = .stop
                } else {
                    m.content = [.toolCall(ToolCall(id: "c1", name: "lookup", arguments: ["q": "x"]))]
                    m.stopReason = .toolUse
                }
                c.yield(.done(reason: m.stopReason, message: m))
                c.finish()
            }
        }
        defer { ApiRegistry.register(.openaiCompletions) { OpenAICompletions.stream($0, $1, $2) } }
        let tool = AgentTool(name: "lookup", label: "查", description: "", parameters: ["type": "object"]) { args in
            .init("查到：\(args["q"]?.stringValue ?? "")")
        }
        var added: [Message] = []
        for await e in AgentLoop.run(prompt: [.user(UserMessage("问"))], history: [], config: AgentConfig(model: fake, tools: [tool])) {
            if case let .agentEnd(m) = e { added = m }
        }
        XCTAssertEqual(added.count, 4) // user, call, result, answer
        guard case let .toolResult(r) = added[2], case let .assistant(a) = added[3] else { return XCTFail() }
        XCTAssertEqual(r.text, "查到：x")
        XCTAssertEqual(a.text, "答案是 42")
    }
}
