import Foundation

/// Notes written while the meeting is still going: refreshed every ~45 s from the new lines, so the
/// user sees the gist and the to-dos (theirs and the other side's) pile up before it ends. The full
/// minutes are still written once over the whole transcript afterwards (MeetingSummarizer).
public struct LiveNotes: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Hashable, Sendable {
        public var text: String
        /// Who it falls on (others' to-dos).
        public var who: String?
        /// "mm:ss" of the line it came from.
        public var at: String?

        public init(text: String, who: String? = nil, at: String? = nil) {
            self.text = text
            self.who = who
            self.at = at
        }

        public var time: Double? { MeetingTime.seconds(at) }
    }

    public struct Topic: Codable, Equatable, Hashable, Sendable {
        public var title: String
        public var points: [String]
    }

    public var summary = ""
    public var topics: [Topic] = []
    public var decisions: [Item] = []
    public var myTodos: [Item] = []
    public var othersTodos: [Item] = []
    public var terms: [MeetingTerm] = []
    /// How many transcript lines these notes cover.
    public var covered = 0

    public init() {}

    public var isEmpty: Bool { summary.isEmpty && topics.isEmpty && myTodos.isEmpty && othersTodos.isEmpty }

    enum CodingKeys: String, CodingKey {
        case summary, topics, decisions, terms, covered
        case myTodos = "my_todos"
        case othersTodos = "others_todos"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        topics = try c.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        decisions = try c.decodeIfPresent([Item].self, forKey: .decisions) ?? []
        myTodos = try c.decodeIfPresent([Item].self, forKey: .myTodos) ?? []
        othersTodos = try c.decodeIfPresent([Item].self, forKey: .othersTodos) ?? []
        terms = try c.decodeIfPresent([MeetingTerm].self, forKey: .terms) ?? []
        covered = try c.decodeIfPresent(Int.self, forKey: .covered) ?? 0
    }
}

/// One LLM call: the notes so far plus the lines since, back comes the whole updated notes.
public struct LiveNotesWriter: Sendable {
    public let client: LLMClient
    public var identity: [String]
    /// The user's own description of their work (see `TodoPrompt.background`).
    public var background: String

    public init(client: LLMClient, identity: [String] = [], background: String = "") {
        self.client = client
        self.identity = identity
        self.background = background
    }

    public func update(_ notes: LiveNotes, transcript: [TranscriptSegment], calendar: String?) async throws -> LiveNotes {
        let new = Array(transcript.dropFirst(min(notes.covered, transcript.count)))
        var text = ""
        if let calendar, !calendar.isEmpty { text += "会议信息：\n\(calendar)\n\n" }
        if notes.isEmpty {
            text += "目前还没有速记。\n\n"
        } else {
            let data = (try? JSONEncoder().encode(notes)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            text += "当前速记（JSON）：\n\(data)\n\n"
            // A little context before the new lines: a sentence may continue across the boundary.
            let before = transcript.prefix(notes.covered).suffix(6)
            if !before.isEmpty { text += "上次已看到的最后几句：\n\(MeetingSummarizer.format(Array(before)))\n\n" }
        }
        text += "新的转写：\n\(MeetingSummarizer.format(new))"
        let result = try await client.callTool(system: Self.systemPrompt(identity: identity, background: background), parts: [.text(text)],
                                               tool: Self.tool, maxTokens: 3000)
        var out: LiveNotes
        switch result {
        case let .arguments(data):
            guard let decoded = try? JSONDecoder().decode(LiveNotes.self, from: data) else {
                throw TodoExtractor.ExtractError.unparsable(String(decoding: data, as: UTF8.self))
            }
            out = decoded
        case let .text(raw):
            guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
                  let decoded = try? JSONDecoder().decode(LiveNotes.self, from: Data(raw[start ... end].utf8))
            else { throw TodoExtractor.ExtractError.unparsable(raw) }
            out = decoded
        }
        // An odd reply never wipes out good notes.
        if out.isEmpty, !notes.isEmpty { throw TodoExtractor.ExtractError.unparsable("empty notes") }
        out.covered = transcript.count
        return out
    }

    static func systemPrompt(identity: [String], background: String = "") -> String {
        let me = identity.isEmpty ? "" : "（用户的名字：\(identity.joined(separator: "、"))）"
        let work = TodoPrompt.background(background).map { "\n\n" + $0 } ?? ""
        return """
        你是 Aist，在会议进行中帮用户做实时速记。转写里「我」是用户本人\(me)，「对方」是其他参会人。转写是机器识别的，会有错字和断句错误，按上下文理解。

        你会收到当前速记和新的几句转写，返回【完整的】更新后速记：
        - summary：两三句话，到目前为止这场会在谈什么、进展到哪
        - topics：按议题分组，每个议题一个简短标题和几条要点；新内容并入已有议题或新开议题
        - decisions：已经拍板的结论
        - my_todos：明确落在用户本人身上的事（别人请用户做、用户自己答应要做）
        - others_todos：落在其他人身上的事，who 写谁（认不出就写「对方」）
        - terms：人名、产品名、术语的正确写法，heard 列出转写里听错的写法
        - 每条 decisions / my_todos / others_todos 的 at 写依据那句话的时间（照抄行首 [mm:ss] 里的 mm:ss）

        要求：中文，简短具体，不写空话；保留之前速记里仍然成立的内容，修正被新内容推翻的；不要编造转写里没有的事。
        调用 update_live_notes 工具提交。\(work)
        """
    }

    static let tool = LLMClient.Tool(
        name: "update_live_notes",
        description: "提交更新后的完整会议速记。",
        schema: """
            {"type": "object", "additionalProperties": false,
             "required": ["summary", "topics", "decisions", "my_todos", "others_todos", "terms"],
             "properties": {
               "summary": {"type": "string"},
               "topics": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["title", "points"],
                 "properties": {"title": {"type": "string"}, "points": {"type": "array", "items": {"type": "string"}}}}},
               "decisions": {"type": "array", "items": \(itemSchema)},
               "my_todos": {"type": "array", "items": \(itemSchema)},
               "others_todos": {"type": "array", "items": \(itemSchema)},
               "terms": {"type": "array", "items": {"type": "object", "additionalProperties": false, "required": ["name", "note", "heard"],
                 "properties": {"name": {"type": "string"}, "note": {"type": "string"}, "heard": {"type": "array", "items": {"type": "string"}}}}}
             }}
            """
    )

    private static let itemSchema = """
        {"type": "object", "additionalProperties": false, "required": ["text", "who", "at"],
         "properties": {"text": {"type": "string"}, "who": {"type": ["string", "null"]}, "at": {"type": ["string", "null"]}}}
        """
}
