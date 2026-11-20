import Foundation

/// Turns a meeting transcript into minutes: title, overview, the discussion topic by topic, decisions,
/// open questions, the user's own to-dos (which go to the to-do list) and other people's.
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
        /// Which lettered voice at the microphone is the user, when the model was asked to tell.
        public var meVoice: String?

        enum CodingKeys: String, CodingKey {
            case title
            case myTodos = "my_todos"
            case meVoice = "me_voice"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "会议"
            meVoice = try? c.decodeIfPresent(String.self, forKey: .meVoice)
            myTodos = (try c.decodeIfPresent([ExtractedTodo].self, forKey: .myTodos) ?? [])
                .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            summary = try MeetingSummary(from: decoder)
        }

        /// Valid JSON with none of the minutes in it (a wrapper object, a refusal): not minutes.
        var isEmpty: Bool {
            summary.overview.isEmpty && summary.topics == nil && summary.keyPoints.isEmpty && summary.decisions.isEmpty
                && myTodos.isEmpty && summary.othersActions.isEmpty
        }
    }

    /// Room for topic-by-topic minutes of a long meeting. Providers that cap output lower reject the
    /// request, and it is sent again with `fallbackTokens`.
    static let maxTokens = 16000
    static let fallbackTokens = 8000

    /// `voices`: the recording's voices told apart, when they were; lines then carry 说话人A… or names.
    public func summarize(transcript: [TranscriptSegment], voices: [MeetingVoice]? = nil, startedAt: Date, existing: [TodoItem],
                          notes: String?, calendar: String? = nil,
                          now: Date = .now, timeZone: TimeZone = .current) async throws -> Output {
        var text = "会议开始于 \(startedAt.formatted(.iso8601))\n已有待办：\(TodoExtractor.existingJSON(existing))\n"
        if let calendar, !calendar.isEmpty { text += "\n会议信息：\n\(calendar)\n\n" }
        if let notes, !notes.isEmpty { text += "用户的会议备注：\(notes)\n" }
        if let roster = SpeakerLabels.roster(voices) { text += "\n说话人（按录音里的声音分出来的）：\n\(roster)\n" }
        text += "\n转写：\n" + Self.format(transcript.spoken, voices: voices)
        let system = Self.systemPrompt(identity: identity, background: background, now: now, timeZone: timeZone)
        let result: LLMClient.ToolResult
        do {
            result = try await client.callTool(system: system, parts: [.text(text)], tool: TodoPrompt.recordMinutes,
                                               maxTokens: Self.maxTokens)
        } catch let LLMClient.ClientError.http(code, _) where code == 400 || code == 422 {
            result = try await client.callTool(system: system, parts: [.text(text)], tool: TodoPrompt.recordMinutes,
                                               maxTokens: Self.fallbackTokens)
        }
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

    public static func format(_ transcript: [TranscriptSegment], voices: [MeetingVoice]? = nil) -> String {
        zip(transcript, SpeakerLabels.labels(transcript, voices: voices)).map { seg, who in
            "[\(MeetingTime.stamp(seg.start))] \(who)：\(seg.text)"
        }.joined(separator: "\n")
    }

    /// Minutes on top of the shared to-do judgment (TodoPrompt), so meetings decide "is this mine?" the same way
    /// screenshots and email do.
    static func systemPrompt(identity: [String], background: String = "", now: Date, timeZone: TimeZone) -> String {
        // The minutes get mailed to the other attendees: the user appears in them by name.
        let me = identity.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "我"
        return """
        你是 Aist，用户的会议助理。你会收到一场会议的机器转写，要写出会议纪要，并找出【用户本人接下来需要去做】的事。

        \(TodoPrompt.notes(.meeting))

        \(TodoPrompt.shared(identity: identity, background: background, now: now, timeZone: timeZone))

        ## 纪要
        用中文，写得具体、详细：没参会的人读完，要能知道会上谈了什么、谁是什么意见、最后怎么定的。不写空话，也不要为了简短丢掉信息。
        纪要会发给其他参会人看：提到用户本人时写「\(me)」，不要写「用户」；其他人写名字，实在认不出才写「对方」。
        - speakers：除用户外实际发言的人（按上面「认人」的方法），每人一句话说明他主要讲了什么。转写里有「说话人A」这类标签时，每个标签一项：voice 填标签里的字母，name 填认出的名字（认不出就照写「说话人A」），basis 用一句话写依据
        - me_voice：只在「说话人」里注明「麦克风上有几个人、还不知道哪个是用户」时才判断：填用户本人那个标签的字母，看不出来填 null；其余情况一律 null
        - title：会议主题，不超过 16 字
        - overview：3～5 句的概要：这场会为什么开、谈成了什么、接下来要做什么
        - topics：按时间顺序把会议分成议题。会上集中讨论的一件事算一个议题，大约每 5～10 分钟一个，十分钟以内的短会一两个就够；寒暄、调试设备不算议题。每个议题：
          · title：议题名，不超过 14 字
          · at：开始谈这个议题的时间
          · points：这个议题下的讨论内容，按发言顺序，一般 3～8 条，谈得久的可以更多。每条一两句话，说清谁提出了什么、依据是什么、别人怎么回应、分歧在哪里；数字、日期、金额、型号、例子照实写进去。不要写「讨论了排期」这种只有题目没有内容的话
          · conclusion：这个议题最后的结论；没谈出结论写 null，并把悬而未决的问题放进 open_questions
        - decisions：做出的决定，把各议题里定下来的事汇总在这里，每条单独读也能看懂
        - open_questions：没有结论、需要跟进的问题（包括讨论过但没落到具体人的事）
        - my_todos：用户本人的待办，按上面的判断方式和写法，source 为 null
        - others_todos：落在别人身上的事：{"who": "谁或 null", "task": "...", "due_text": "原文期限或 null", "at": "mm:ss 或 null"}
        - 时间：topics 和 points 的 at、others_todos 的 at、decision_at（与 decisions 一一对应），都写最能支撑该条的那句转写的时间（照抄行首 [mm:ss] 里的 mm:ss），找不到写 null
        - terms：会上出现的人名、公司、产品、术语。name 写正确写法（参照会议信息、上下文推断），heard 列出转写里把它听错的写法（原样照抄，供日后搜索），note 一句话说明它是什么。纪要正文里一律用正确写法

        ## 提交结果
        调用 record_minutes 工具提交，没有的项给空数组。如果无法调用工具，就只输出同样结构的 JSON 对象，不要任何其他文字：
        {"analysis": "1～3 句：谁主导、谈了什么、哪些事落在用户身上", "speakers": [{"voice": "A 或 null", "name": "...", "said": "...", "certain": true, "basis": "... 或 null"}], "me_voice": null, "title": "...", "overview": "...", "topics": [{"title": "...", "at": "mm:ss", "points": [{"text": "...", "at": "mm:ss"}], "conclusion": "... 或 null"}], "decisions": [], "decision_at": [], "open_questions": [], "my_todos": [], "others_todos": [], "terms": [{"name": "...", "note": "...", "heard": []}]}
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
