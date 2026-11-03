@testable import AistAI
import XCTest

/// Feeds recorded-shape SSE payloads (invented content) through the parsers.
final class StreamParserTests: XCTestCase {
    private let model = Catalog.model(id: "deepseek-flash", provider: "deepseek", api: .anthropicMessages,
                                      baseURL: URL(string: "https://api.deepseek.com/anthropic")!)

    private func feedAnthropic(_ lines: [String]) throws -> (MessageBuilder, [AssistantEvent], StopReason) {
        var b = MessageBuilder(model: model)
        var p = AnthropicMessages.StreamParser()
        var events: [AssistantEvent] = []
        for l in lines { events += try p.handle(SSE.object(l)!, &b) }
        return (b, events, p.stopReason)
    }

    func testTextAndHostedSearch() throws {
        let (b, events, stop) = try feedAnthropic([
            #"{"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":64}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"我查"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"一下。"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{},"caller":{"type":"direct"}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"示例"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"城市 天气\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[{"type":"web_search_result","title":"示例天气","url":"https://weather.example.com/a","encrypted_content":"xyz"}]}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"晴，25~30°C。"}}"#,
            #"{"type":"content_block_stop","index":3}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
            #"{"type":"message_stop"}"#,
        ])
        XCTAssertEqual(stop, .stop)
        XCTAssertEqual(b.message.text, "我查一下。晴，25~30°C。")
        XCTAssertEqual(b.message.usage.input, 120)
        XCTAssertEqual(b.message.usage.cacheRead, 64)
        XCTAssertEqual(b.message.usage.output, 42)
        guard case let .hosted(h) = b.message.content[1] else { return XCTFail("no hosted block") }
        XCTAssertEqual(h.detail, "示例城市 天气")
        XCTAssertTrue(h.done)
        XCTAssertEqual(h.sources.map(\.host), ["weather.example.com"])
        XCTAssertEqual(h.raw.count, 2, "both provider blocks kept for replay")
        XCTAssertEqual(h.raw[0]["input"]?["query"]?.stringValue, "示例城市 天气")
        XCTAssertNil(h.raw[0]["caller"])
        XCTAssertTrue(events.contains { if case .hostedStart = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .hostedEnd = $0 { true } else { false } })

        // Replayed to the same provider verbatim, as one assistant turn.
        let body = AnthropicMessages.convertMessages([.user(UserMessage("问")), .assistant(b.message)])
        let blocks = body[1]["content"] as! [[String: Any]]
        XCTAssertEqual(blocks.map { $0["type"] as! String }, ["text", "server_tool_use", "web_search_tool_result", "text"])
    }

    func testToolCallStreamsArguments() throws {
        let (b, events, stop) = try feedAnthropic([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"fetch_page","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"url\":\"https://exa"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"mple.com\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
        ])
        XCTAssertEqual(stop, .toolUse)
        XCTAssertEqual(b.message.toolCalls.first?.arguments["url"]?.stringValue, "https://example.com")
        // A delta mid-way already exposes a usable partial argument.
        if case let .toolCallDelta(_, _, partial)? = events.first(where: { if case .toolCallDelta = $0 { true } else { false } }) {
            XCTAssertEqual(partial.toolCalls.first?.arguments["url"]?.stringValue, "https://exa")
        } else { XCTFail("no delta") }
    }

    func testProviderErrorEventThrows() {
        XCTAssertThrowsError(try feedAnthropic([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]))
    }

    func testOpenAIReasoningTextAndTools() throws {
        let m = Catalog.model(id: "deepseek-chat", provider: "x", api: .openaiCompletions, baseURL: URL(string: "https://api.deepseek.com")!)
        var b = MessageBuilder(model: m)
        var p = OpenAICompletions.StreamParser()
        for l in [
            #"{"choices":[{"delta":{"reasoning_content":"想一想"}}]}"#,
            #"{"choices":[{"delta":{"content":"好的"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"web_search","arguments":"{\"qu"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ery\":\"示例\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":20}}}"#,
        ] { _ = try p.handle(SSE.object(l)!, &b) }
        _ = p.close(&b)
        XCTAssertEqual(p.stopReason, .toolUse)
        XCTAssertEqual(b.message.content.count, 3)
        if case let .thinking(t, _) = b.message.content[0] { XCTAssertEqual(t, "想一想") } else { XCTFail() }
        XCTAssertEqual(b.message.text, "好的")
        XCTAssertEqual(b.message.toolCalls.first?.arguments["query"]?.stringValue, "示例")
        XCTAssertEqual(b.message.usage.input, 30)
        XCTAssertEqual(b.message.usage.cacheRead, 20)
    }

    func testPartialJSON() {
        XCTAssertEqual(JSONValue.parsePartial(#"{"a": "b"#)["a"]?.stringValue, "b")
        XCTAssertEqual(JSONValue.parsePartial(#"{"a": [1, 2"#)["a"], .array([1, 2]))
        XCTAssertEqual(JSONValue.parsePartial(#"{"a": "x", "#)["a"]?.stringValue, "x")
    }
}

final class TransformTests: XCTestCase {
    private let claude = Catalog.model(id: "claude-opus-5-5", provider: "anthropic", api: .anthropicMessages,
                                       baseURL: URL(string: "https://api.anthropic.com")!)

    func testHandoffFromAnotherProvider() {
        var a = AssistantMessage(api: .anthropicMessages, provider: "deepseek", model: "deepseek-flash")
        a.content = [
            .thinking("先想想", signature: "sig"),
            .hosted(HostedBlock(id: "srv", tool: .webSearch, input: ["query": "示例"],
                                sources: [WebSource(url: "https://a.example.com", title: "A")], done: true, raw: [["type": "server_tool_use"]])),
            .toolCall(ToolCall(id: "call.00:x", name: "fetch_page", arguments: ["url": "https://a.example.com"])),
        ]
        a.stopReason = .toolUse
        let out = Transform.prepare([.user(UserMessage("问")), .assistant(a)], for: claude)
        guard case let .assistant(m) = out[1] else { return XCTFail() }
        XCTAssertEqual(m.content.count, 3)
        if case let .text(t) = m.content[0] { XCTAssertTrue(t.contains("先想想")) } else { XCTFail("thinking → text") }
        if case let .text(t) = m.content[1] { XCTAssertTrue(t.contains("a.example.com")) } else { XCTFail("hosted → text") }
        XCTAssertEqual(m.toolCalls.first?.id, "call_00_x")
        // The call never got a result (turn aborted): a synthetic error result follows.
        guard case let .toolResult(r) = out[2] else { return XCTFail("missing synthetic result") }
        XCTAssertEqual(r.toolCallId, "call_00_x")
        XCTAssertTrue(r.isError)
    }

    func testEmptyFailedTurnDropped() {
        var a = AssistantMessage(api: .anthropicMessages, provider: "anthropic", model: "claude-opus-5-5")
        a.stopReason = .error
        XCTAssertEqual(Transform.prepare([.user(UserMessage("问")), .assistant(a)], for: claude).count, 1)
    }

    func testMessageCodingRoundTrip() throws {
        var a = AssistantMessage(for: claude)
        a.content = [.text("答"), .toolCall(ToolCall(id: "t", name: "n", arguments: ["k": 1]))]
        let msgs: [Message] = [.user(UserMessage("问")), .assistant(a),
                               .toolResult(ToolResultMessage(toolCallId: "t", toolName: "n", content: [.text("r")]))]
        let back = try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(msgs))
        XCTAssertEqual(back, msgs)
    }
}
