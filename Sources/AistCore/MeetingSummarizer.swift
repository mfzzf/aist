import Foundation

/// Turns a meeting transcript into minutes: title, overview, key points, decisions, open questions,
/// the user's own to-dos (which go to the to-do list) and other people's.
public struct MeetingSummarizer: Sendable {
    public let client: LLMClient
    public var identity: [String]
    /// The user's own description of their work (see `TodoPrompt.background`).
    public var background: String

    public init(client: LLMClient, identity: [String] = [], background: String = "") {
        self.client = client
        self.identity = identity
        self.background = background
    }

    public struct Output: Decodable, Sendable {
        public var title: String
        public var summary: MeetingSummary
        public var myTodos: [ExtractedTodo]

        enum CodingKeys: String, CodingKey {
            case title
            case myTodos = "my_todos"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "会议"
            myTodos = (try c.decodeIfPresent([ExtractedTodo].self, forKey: .myTodos) ?? [])
                .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            summary = try MeetingSummary(from: decoder)
        }

        /// Valid JSON with none of the minutes in it (a wrapper object, a refusal): not minutes.
        var isEmpty: Bool {
            summary.overview.isEmpty && summary.keyPoints.isEmpty && summary.decisions.isEmpty && myTodos.isEmpty
                && summary.othersActions.isEmpty
        }
    }

    public func summarize(transcript: [TranscriptSegment], startedAt: Date, existing: [TodoItem],
                          notes: String?, calendar: String? = nil,
                          now: Date = .now, timeZone: TimeZone = .current) async throws -> Output {
        var text = "会议开始于 \(startedAt.formatted(.iso8601))\n已有待办：\(TodoExtractor.existingJSON(existing))\n"
        if let calendar, !calendar.isEmpty { text += "\n会议信息：\n\(calendar)\n\n" }
        if let notes, !notes.isEmpty { text += "用户的会议备注：\(notes)\n" }
        text += "\n转写：\n" + Self.format(transcript)
        let result = try await client.callTool(
            system: Self.systemPrompt(identity: identity, background: background, now: now, timeZone: timeZone),
            parts: [.text(text)],
            tool: TodoPrompt.recordMinutes,
            maxTokens: 8000
        )
        switch result {
        case let .arguments(data):
            guard let out = try? JSONDecoder().decode(Output.self, from: data), !out.isEmpty else {
                throw TodoExtractor.ExtractError.unparsable(String(decoding: data, as: UTF8.self))
            }
            return out
        case let .text(raw):
            let out = try Self.parse(raw)
            if out.isEmpty { throw TodoExtractor.ExtractError.unparsable(raw) }
            return out
        }
    }

    public static func format(_ transcript: [TranscriptSegment]) -> String {
        transcript.map { seg in
            "[\(MeetingTime.stamp(seg.start))] " + (seg.speaker == .me ? "我" : "对方") + "：" + seg.text
        }.joined(separator: "\n")
    }

    /// Minutes on top of the shared to-do judgment (TodoPrompt), so meetings decide "is this mine?" the same way
    /// screenshots and email do.
    static func systemPrompt(identity: [String], background: String = "", now: Date, timeZone: TimeZone) -> String {
        """
        你是 Aist，用户的会议助理。你会收到一场会议的机器转写，要写出会议纪要，并找出【用户本人接下来需要去做】的事。

        \(TodoPrompt.notes(.meeting))

        \(TodoPrompt.shared(identity: identity, background: background, now: now, timeZone: timeZone))

        ## 纪要
        用中文，简洁、具体、不写空话：
        - speakers：除用户外实际发言的人（按上面「认人」的方法），每人一句话说明他主要讲了什么
        - title：会议主题，不超过 16 字
        - overview：两三句话的概要
        - key_points：讨论要点
        - decisions：做出的决定
        - open_questions：没有结论、需要跟进的问题（包括讨论过但没落到具体人的事）
        - my_todos：用户本人的待办，按上面的判断方式和写法，source 为 null
        - others_todos：落在别人身上的事：{"who": "谁或 null", "task": "...", "due_text": "原文期限或 null", "at": "mm:ss 或 null"}
        - key_point_at / decision_at：与 key_points / decisions 一一对应，写最能支撑该条的那句转写的时间（照抄行首 [mm:ss] 里的 mm:ss），找不到写 null
        - terms：会上出现的人名、公司、产品、术语。name 写正确写法（参照会议信息、上下文推断），heard 列出转写里把它听错的写法（原样照抄，供日后搜索），note 一句话说明它是什么。纪要正文里一律用正确写法

        ## 提交结果
        调用 record_minutes 工具提交，没有的项给空数组。如果无法调用工具，就只输出同样结构的 JSON 对象，不要任何其他文字：
        {"analysis": "1～3 句：谁主导、谈了什么、哪些事落在用户身上", "speakers": [{"name": "...", "said": "...", "certain": true}], "title": "...", "overview": "...", "key_points": [], "key_point_at": [], "decisions": [], "decision_at": [], "open_questions": [], "my_todos": [], "others_todos": [], "terms": [{"name": "...", "note": "...", "heard": []}]}
        my_todos 每项：{"title": "...", "requester": "谁提的或 null", "source": null, "due_text": "原文或 null", "due_at": "ISO 8601 或 null", "priority": "high|medium|low", "evidence": "转写中最能说明这件事的一句", "duplicate_of": "已有待办的 id 或 null", "suggestion": "下一步建议或 null"}
        """
    }

    public static func parse(_ raw: String) throws -> Output {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            throw TodoExtractor.ExtractError.unparsable(raw)
        }
        do {
            return try JSONDecoder().decode(Output.self, from: Data(raw[start ... end].utf8))
        } catch {
            throw TodoExtractor.ExtractError.unparsable(raw)
        }
    }
}
