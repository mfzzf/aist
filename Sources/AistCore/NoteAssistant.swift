import Foundation

/// What the user typed or said to Aist on the phone, read for intent: record new things (any number),
/// tick off, reopen, reschedule or cancel existing ones, ask for suggestions, or ask a question.
public struct NoteResult: Codable, Sendable, Equatable {
    public struct Ref: Codable, Sendable, Equatable {
        public var id: String
        public var reason: String?

        public init(id: String, reason: String? = nil) {
            self.id = id
            self.reason = reason
        }
    }

    public struct Change: Codable, Sendable, Equatable {
        public var id: String
        public var title: String?
        public var dueText: String?
        public var dueAt: String?
        public var priority: TodoPriority?
        /// New specifics to add to the to-do's notes (a phone number, an address…).
        public var details: String?
        public var reason: String?

        enum CodingKeys: String, CodingKey {
            case id, title, priority, reason, details
            case dueText = "due_text"
            case dueAt = "due_at"
        }

        public var resolvedDueAt: Date? { dueAt.flatMap(TodoExtractor.parseDate) }
    }

    public var analysis: String?
    /// One or two sentences back to the user: what was done, the answer to their question, or which
    /// to-do they meant when it was unclear.
    public var reply: String?
    public var add: [ExtractedTodo]
    public var complete: [Ref]
    /// Finished to-dos the user says aren't actually done.
    public var reopen: [Ref]
    public var update: [Change]
    public var remove: [Ref]
    /// Things the AI proposes when asked for ideas; the user picks which to add.
    public var suggestions: [ExtractedTodo]
    /// References the model made that matched no to-do (dropped from the lists above), in its words.
    public var unresolved: [String]

    public init(analysis: String? = nil, reply: String? = nil, add: [ExtractedTodo] = [], complete: [Ref] = [],
                reopen: [Ref] = [], update: [Change] = [], remove: [Ref] = [], suggestions: [ExtractedTodo] = [],
                unresolved: [String] = []) {
        self.analysis = analysis
        self.reply = reply
        self.add = add
        self.complete = complete
        self.reopen = reopen
        self.update = update
        self.remove = remove
        self.suggestions = suggestions
        self.unresolved = unresolved
    }

    enum CodingKeys: String, CodingKey { case analysis, reply, add, complete, reopen, update, remove, suggestions, unresolved }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        analysis = try c.decodeIfPresent(String.self, forKey: .analysis)
        reply = try c.decodeIfPresent(String.self, forKey: .reply)
        add = (try c.decodeIfPresent([ExtractedTodo].self, forKey: .add) ?? []).filter { !$0.title.isEmpty }
        complete = try c.decodeIfPresent([Ref].self, forKey: .complete) ?? []
        reopen = try c.decodeIfPresent([Ref].self, forKey: .reopen) ?? []
        update = try c.decodeIfPresent([Change].self, forKey: .update) ?? []
        remove = try c.decodeIfPresent([Ref].self, forKey: .remove) ?? []
        suggestions = (try c.decodeIfPresent([ExtractedTodo].self, forKey: .suggestions) ?? []).filter { !$0.title.isEmpty }
        unresolved = try c.decodeIfPresent([String].self, forKey: .unresolved) ?? []
    }

    public var isEmpty: Bool {
        add.isEmpty && complete.isEmpty && reopen.isEmpty && update.isEmpty && remove.isEmpty && suggestions.isEmpty
            && (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct NoteAssistant: Sendable {
    /// One earlier exchange, so 「刚才那个改成周三」 can refer back to it.
    public struct Turn: Sendable, Equatable {
        public var said: String
        /// What Aist did in answer, in words the model can match against the list (titles, not ids).
        public var did: String
        public var at: Date

        public init(said: String, did: String, at: Date = .now) {
            self.said = said
            self.did = did
            self.at = at
        }
    }

    /// The to-do list as shown to the model: numbered in screen order, with a map back to the real ids.
    public struct Listing: Sendable {
        public var text: String
        public var handles: [String: UUID]
    }

    public let client: LLMClient
    public var identity: [String]

    public init(client: LLMClient, identity: [String] = []) {
        self.client = client
        self.identity = identity
    }

    /// - Parameters:
    ///   - images: JPEGs the user attached (screenshots, photos), read together with the words.
    ///   - recent: the last few exchanges, newest last; only those from the last quarter hour are shown.
    public func handle(_ note: String, images: [Data] = [], todos: [TodoItem], recent: [Turn] = [],
                       now: Date = .now, timeZone: TimeZone = .current) async throws -> NoteResult {
        let said = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = Self.listing(todos, now: now, timeZone: timeZone)
        var text = "## 待办清单（编号就是 id，顺序和用户屏幕上一样）\n\(listing.text)\n\n"
        let turns = recent.filter { now.timeIntervalSince($0.at) < 15 * 60 }.suffix(3)
        if !turns.isEmpty {
            text += "## 刚才的对话\n" + turns.map { t in
                let minutes = max(1, Int(now.timeIntervalSince(t.at) / 60))
                return "- \(minutes) 分钟前用户说：「\(t.said.prefix(300))」→ 你做了：\(t.did.prefix(300))"
            }.joined(separator: "\n") + "\n\n"
        }
        text += "## 用户这次说\n"
        if !images.isEmpty { text += "（附了 \(images.count) 张图片，见上）\n" }
        text += said.isEmpty ? "（没有写字，只发了图片）" : String(said.prefix(12_000))
        let parts = images.map { LLMClient.Part.image($0, mediaType: "image/jpeg") } + [.text(text)]
        let result = try await client.callTool(
            system: TodoPrompt.noteAssistant(identity: identity, now: now, timeZone: timeZone, withImages: !images.isEmpty),
            parts: parts,
            tool: TodoPrompt.handleNote
        )
        return Self.resolve(try Self.parse(result), listing: listing, todos: todos)
    }

    // MARK: - The list as the model sees it

    /// Open to-dos in screen order, then those finished in the last two days (so 「刚才那个没做完」 can
    /// find them), each as one line: `#3 把报价发给 Kevin · 截止 11/03 周二 15:00 · 高 · Kevin 交代`.
    /// Short numbers instead of UUIDs: small models copy 36-character ids wrong, and 「第一条」 needs an order.
    public static func listing(_ items: [TodoItem], now: Date = .now, timeZone: TimeZone = .current) -> Listing {
        let open = TodoStore.screenOrder(items.filter { $0.status == .open }, now: now)
        let done = items.filter { $0.status == .done && ($0.completedAt.map { now.timeIntervalSince($0) < 2 * 86400 } ?? false) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        guard !open.isEmpty || !done.isEmpty else { return Listing(text: "（清单是空的）", handles: [:]) }

        let due = DateFormatter()
        due.locale = Locale(identifier: "zh_CN")
        due.timeZone = timeZone
        due.dateFormat = "MM/dd EEE HH:mm"
        func age(_ date: Date) -> String {
            let days = Int(now.timeIntervalSince(date) / 86400)
            return days <= 0 ? "今天" : days == 1 ? "昨天" : "\(days) 天前"
        }

        var handles: [String: UUID] = [:]
        var lines: [String] = []
        for (i, t) in (open + done).enumerated() {
            let handle = "#\(i + 1)"
            handles[handle] = t.id
            var parts = ["\(handle) \(t.title)"]
            if t.status == .done {
                parts.append("已完成（\(age(t.completedAt ?? t.updatedAt))勾掉的）")
            } else {
                if let d = t.dueAt {
                    parts.append("截止 \(due.string(from: d))" + (d < now ? "（已过）" : "") + (t.dueText.map { "，原话「\($0)」" } ?? ""))
                }
                parts.append(t.priority == .high ? "高" : t.priority == .low ? "低" : "中")
                if let who = t.requester, !who.isEmpty { parts.append("\(who) 交代") }
                if let notes = t.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    parts.append("备注：" + notes.replacingOccurrences(of: "\n", with: "；").prefix(80))
                }
                parts.append("\(age(t.createdAt))记的")
            }
            lines.append(parts.joined(separator: " · "))
        }
        return Listing(text: lines.joined(separator: "\n"), handles: handles)
    }

    // MARK: - Back to real ids

    /// Maps the model's `#3` handles back to UUIDs; a reference that matches nothing is dropped and
    /// listed in `unresolved`, so the app never edits the wrong to-do and can tell the user.
    public static func resolve(_ result: NoteResult, listing: Listing, todos: [TodoItem]) -> NoteResult {
        var out = result
        var unresolved: [String] = []
        func uuid(_ raw: String, _ reason: String?) -> String? {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let handle = handle(in: key), let id = listing.handles[handle] { return id.uuidString }
            if let id = UUID(uuidString: key), todos.contains(where: { $0.id == id }) { return id.uuidString }
            let bare = key.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'“”"))
            if let item = todos.first(where: { $0.title == bare }) { return item.id.uuidString }
            unresolved.append(handle(in: key) == nil && !bare.isEmpty ? bare : (reason ?? key))
            return nil
        }
        func refs(_ list: [NoteResult.Ref]) -> [NoteResult.Ref] {
            list.compactMap { ref in uuid(ref.id, ref.reason).map { NoteResult.Ref(id: $0, reason: ref.reason) } }
        }
        out.complete = refs(result.complete)
        out.reopen = refs(result.reopen)
        out.remove = refs(result.remove)
        out.update = result.update.compactMap { change in
            guard let id = uuid(change.id, change.reason) else { return nil }
            var c = change
            c.id = id
            return c
        }
        out.add = result.add.map { e in
            var e = e
            if (e.source ?? "").isEmpty { e.source = "随手记" }
            e.duplicateOf = e.duplicateOf.flatMap { handle(in: $0) }.flatMap { listing.handles[$0]?.uuidString } ?? e.duplicateOf
            return e
        }
        out.unresolved = unresolved
        return out
    }

    /// `#3`, `＃3`, `3`, `t3`, `#3 把报价发给 Kevin` → `#3`; anything else nil.
    static func handle(in raw: String) -> String? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") || s.hasPrefix("＃") { s = s.dropFirst() } else if s.hasPrefix("t") { s = s.dropFirst() }
        let digits = s.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = s.dropFirst(digits.count)
        guard rest.isEmpty || rest.first!.isWhitespace || "「:：·".contains(rest.first!) else { return nil }
        return "#\(digits)"
    }

    public static func parse(_ result: LLMClient.ToolResult) throws -> NoteResult {
        let data: Data
        switch result {
        case let .arguments(d):
            data = d
        case let .text(raw):
            guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
                throw TodoExtractor.ExtractError.unparsable(raw)
            }
            data = Data(raw[start ... end].utf8)
        }
        if ProcessInfo.processInfo.environment["AIST_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[note] \(String(decoding: data, as: UTF8.self).prefix(2000))\n".utf8))
        }
        do {
            return try JSONDecoder().decode(NoteResult.self, from: data)
        } catch {
            throw TodoExtractor.ExtractError.unparsable(String(decoding: data, as: UTF8.self))
        }
    }
}

extension TodoPrompt {
    /// System prompt for the phone's input bar. Unlike the extraction prompts, the user is talking *to*
    /// Aist: the first job is to tell what they want done, the second is to find which to-do they mean.
    public static func noteAssistant(identity: [String], now: Date, timeZone: TimeZone, withImages: Bool = false) -> String {
        [
            noteRole,
            who(identity),
            noteIntents,
            noteWriting,
            clock(now: now, timeZone: timeZone),
            noteExamples,
            withImages ? imageNotes : nil,
            noteOutput,
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    static let noteRole = """
        你是 Aist，用户手机上的待办助理。用户对你说一句话（打字，或语音转写），你要听懂他想让你做什么，直接替他操作待办清单，再用一两句话回复。
        你能做的：记新待办（add）、把已有的勾掉（complete）、把勾掉的恢复（reopen）、改已有的（update：时间、标题、优先级、补充细节）、取消已有的（remove）、出主意让用户挑（suggestions）、回答关于清单的问题（reply）。
        输入里有「待办清单」：每条带编号（#1、#2…），顺序和用户屏幕上看到的一样，勾掉的排在最后。complete / reopen / update / remove 里的 id 就填这个编号。编号只用在工具参数里，用户屏幕上看不到它，回复里要用待办的标题或简称。
        """

    static let noteIntents = """
        ## 怎么听懂
        三步，过程写进 analysis：
        1. 切句：把这段话拆成一件件事。换行、顿号、列表符号、「还有」「然后」「另外」「顺便」「对了」都是分隔；语音转写里的口头禅（嗯、那个、就是）、重复、错字和中英马来文混杂按意思还原。同一件事的补充说明不要拆成两件。
        2. 定意图，每件事一种：
           - 说某件事「发了」「拿到了」「搞定了」「做完了」「已经…了」→ complete
           - 说某件已勾掉的事「其实还没做完」「重新打开」「放回来」→ reopen
           - 改时间（「改到」「推迟」「提前」「挪到」「下周再说」）、改优先级（「不急」「很急」）、换说法、补充信息（电话、地址、金额、要求）→ update
           - 「取消」「不用了」「算了不弄了」「删掉」→ remove
           - 让你出主意（「帮我想想」「要准备什么」「要做哪些事」「怎么安排」）→ suggestions：3～8 条，每条具体可执行、带合理期限和优先级；不要直接 add
           - 问清单（「今天有什么」「还有几件」「X 什么时候截止」「X 做了没」）→ 只在 reply 里回答，什么都不改
           - 闲聊、感叹、犹豫（「好累」「要不要去呢」，没有决定要做什么）→ 什么都不做，reply 一句即可，不要记成待办
           - 其余说要做的、提醒自己的、答应别人的 → add；明确说让别人去做的，记成自己的跟进（「跟进小王订会议室」）
        3. 对号：complete / reopen / update / remove 必须落到清单里的某一条。按意思对，不按字面：「报价那个」「Kevin 那件事」= 「把报价发给 Kevin」；「第一条」「最上面那个」「最后一条」按清单顺序数。只有标了「已完成」的才能 reopen。
           对不上、或有两条都像、或用户说的和清单里的明显是两件事：绝不猜着改。这件事不填进任何数组，在 reply 里问清楚，写出候选的标题（「你说的是「…」还是「…」？」或「清单里没有这条，要新记一条吗？」）。用户的回答会连同「刚才的对话」一起再发给你。
           要加的事和清单里某条是同一件事时，不要 add，用 update 把新信息补进去。
        一段话里常常同时有好几种意图，各自处理。「刚才的对话」里写着上一轮用户说了什么、你做了什么：「刚才那个」「改一下」「不对，是周三」「第二个」指的就是上一轮涉及的那条，或你上一轮问的候选。
        """

    static let noteWriting = """
        ## 怎么写
        - title：中文动宾短语，不超过 18 字，写清动作和对象（「去菜鸟驿站拿快递」）。标题里不放时间（时间放 due_at）；改时间时，旧标题里的「今晚」「明天」要去掉。专有名词、人名、英文术语照原样。
        - due_at：ISO 8601 带时区偏移；due_text 保留原话（「周三前」「下班前」）。换算：只说日期没说钟点 = 当天 18:00；「早上」09:00、「上午」10:00、「中午」12:00、「下午」15:00、「晚上」20:00（说了具体钟点就用具体的）；「下班前」「今天内」= 当天 18:00；「周末」= 本周六 10:00；「过两天」= 两天后 18:00；「下周」没说哪天 = 下周一 18:00；「月底」= 当月最后一天 18:00；会议、活动取开始时间。没提时间就 null，不要编。
        - priority：「急」「马上」「今天必须」「老板/客户在催」= high；「不急」「有空再」= low；其余 medium。
        - details：用户顺口说的电话、地址、金额、单号、链接、要带的东西、对方的要求，分行写成「电话：0123456789」这样的短条目，号码照抄。只是一句备忘（「Kevin 的电话是…」）就用 update 放进最相关那条的 details，别单独记一条。没有就 null。
        - requester：用户转述别人交代的（「老板让我」「Kevin 要我」）填那个人，否则 null。
        - update 里只填要改的字段，其余 null。
        """

    static let noteExamples = """
        ## 例子
        （清单：#1 今晚去拿快递（截止今天 21:00）· #2 参加产品评审会（明天 14:00）· #3 把报价发给 Kevin（明天 15:00）· #4 修改 Q4 slides（周五）· #5 预约牙医复诊 · #6 给妈妈打电话 · #7 交季度报销（已完成））
        例 1 「报价发了，快递明天再拿，牙医不用约了」
          → complete #3；update #1：due_at 明天 18:00、title「去拿快递」；remove #5。reply「报价已勾掉，快递挪到明天，牙医那条取消了。」
        例 2 「Kevin 那个不急，下周再说」
          → update #3：priority low，due_at 下周一 18:00。
        例 3 「周三前交差旅报销，还有买猫粮」
          → add 2 条：「交差旅报销」（周三 18:00）、「买猫粮」。#7 是已完成的季度报销，不是同一件事。
        例 4 「把和 Kevin 签合同那个改到周三」
          → 清单里没有签合同的事，#3 是报价不是合同：什么都不改。reply「清单里没有「和 Kevin 签合同」这条。你是指「把报价发给 Kevin」，还是要新记一条？」
        例 5 「报销那个其实还没交完」
          → reopen #7，不要新记一条。
        例 6 「帮我想想搬家前要做哪些事」
          → suggestions 5～6 条（「确认搬家日期并请假」「预约搬家公司」「办理退租和退押金」…各带期限），add 为空。reply 一句说明建议的顺序。
        例 7 「今天还有什么要做」
          → 什么都不改。reply「今天还有 1 件：去拿快递（21:00 前）。明天有评审会和给 Kevin 的报价。」
        例 8 「今天好累啊」
          → 什么都不做。reply「辛苦了，这句没记。」不要顺带提醒别的事。
        例 9 刚才的对话：用户说「周五前把月报交给老板」，你新增了「把月报交给老板」。这次说「刚才那个改成周三，不是周五」
          → update「把月报交给老板」那条：due_at 周三 18:00，due_text「周三」。
        例 10 「第一条推到明天」
          → update #1：due_at 明天 18:00，title「去拿快递」。
        例 11 语音转写「嗯那个 就是 Kevin 那个报价 我已经发了啊 然后牙医的话 下周再约吧」
          → complete #3；update #5：due_at 下周一 18:00，due_text「下周」。
        例 12 「Kevin 的电话是 012-345 6789」
          → 只是备忘：update #3，details「电话：012-345 6789」。reply「记到报价那条里了。」
        """

    static let noteOutput = """
        ## 提交结果
        调用 handle_note 工具。analysis 按「切句 → 意图 → 编号」逐件写，一件一行：『原话片段』→ 意图 → #编号（或「新」「没找到」）。然后填各数组，没有的给空数组。
        reply 是助理的口头回复：确认做了什么时不超过 40 字（「记下 3 件，报价已勾掉。」）；回答问题可以到 80 字；需要问清楚时列出候选。提到待办用标题或简称，不要写编号（用户看不到编号）。只说用户问的和你做的，不要附加提醒、建议或关心的话。
        如果无法调用工具，就只输出同样结构的 JSON 对象，不要任何其他文字。
        """

    static let imageNotes = """
        ## 用户附了图片
        图片可能是：聊天记录、邮件、通知的截图；海报、活动页、报名表；票据、账单、快递单、取件短信；白板、PPT、会议现场照片；名片；文件、合同、表格；日历、行程单、机票酒店订单；地图、地址；手写便签。
        - 先看清每张图是什么，再按上面同样的规则判断要做的事。聊天截图按聊天读：右侧（通常蓝/绿色）气泡是用户本人发的，左侧是别人；以最新几条为准。截图里别人说「收到了」「已处理」对应清单里的某条时，那条 complete。
        - 把图里和这件事有关的信息尽量都读出来写进 details：日期时间、地点/地址/会议室/链接、人名和联系方式、金额、单号/订单号/取件码/航班号/座位、要带的东西、报名或提交的截止要求。号码逐字照抄，看不清的字不要猜，写「（看不清）」。
        - 用户的文字优先：用户说了「帮我记一下」「这个周五前弄好」，按用户说的定事情和期限，图片补细节；只发图不说话时，自己判断图里有什么要用户去做的。
        - 活动、会议、课程类：需要报名/提交/付款的记一条（期限取截止时间），用户要去参加的再记一条「参加 X」（due_at 取开始时间），两条的 details 都带上时间地点等信息。
        - 图里只有信息、没有要做的事（如一张名片、一个地址）：用 update 放进最相关待办的 details；都不相关就在 reply 里简短说你看到了什么、问用户要不要记。
        - source 填图里的应用或文件类型（如「微信截图」「快递单照片」）。
        """

    /// One to-do as the phone's assistant records it: no evidence (the user's own words), no
    /// duplicate_of (repeats go through `update`), no per-item suggestion.
    static let noteItemSchema = """
        {"type": "object", "additionalProperties": false,
         "required": ["title", "requester", "source", "due_text", "due_at", "priority", "details"],
         "properties": {
           "title": {"type": "string", "description": "中文动宾短语，不超过 18 字，写具体动作和对象，不带时间"},
           "requester": {"type": ["string", "null"], "description": "用户转述的交代人；自己定的为 null"},
           "source": {"type": ["string", "null"], "description": "「随手记」；来自图片时填图的类型，如「微信截图」"},
           "due_text": {"type": ["string", "null"], "description": "用户原话里的期限说法"},
           "due_at": {"type": ["string", "null"], "description": "ISO 8601 截止时间，带时区偏移；没提为 null"},
           "priority": {"type": "string", "enum": ["high", "medium", "low"]},
           "details": {"type": ["string", "null"], "description": "和这件事有关的具体信息，分行短条目：联系人/电话/地址/金额/单号/链接/要带的东西/要求；照抄号码；没有为 null"}
         }}
        """

    public static let handleNote = LLMClient.Tool(
        name: "handle_note",
        description: "执行用户对 Aist 说的话：新增、完成、恢复、修改、取消待办，给出建议，或回答问题。id 填清单里的编号（如 #3）。没有的项给空数组。",
        schema: """
            {"type": "object", "additionalProperties": false,
             "required": ["analysis", "reply", "add", "complete", "reopen", "update", "remove", "suggestions"],
             "properties": {
               "analysis": {"type": "string", "description": "逐件一行：『原话片段』→ 意图 → #编号（或「新」「没找到」）"},
               "reply": {"type": "string", "description": "给用户的口头回复：做了什么（≤40 字）、问题的答案，或问清楚是哪一条；用标题指待办，不写编号"},
               "add": {"type": "array", "description": "要新记的待办，一件事一条", "items": \(noteItemSchema)},
               "complete": {"type": "array", "description": "用户说已经办完的待办", "items": {"type": "object", "additionalProperties": false,
                 "required": ["id", "reason"],
                 "properties": {"id": {"type": "string", "description": "清单编号，如 #3"}, "reason": {"type": ["string", "null"]}}}},
               "reopen": {"type": "array", "description": "用户说其实还没做完的、已完成的待办", "items": {"type": "object", "additionalProperties": false,
                 "required": ["id", "reason"],
                 "properties": {"id": {"type": "string", "description": "清单编号，如 #7"}, "reason": {"type": ["string", "null"]}}}},
               "update": {"type": "array", "description": "要修改的待办；不改的字段为 null", "items": {"type": "object", "additionalProperties": false,
                 "required": ["id", "title", "due_text", "due_at", "priority", "details", "reason"],
                 "properties": {
                   "id": {"type": "string", "description": "清单编号，如 #3"},
                   "title": {"type": ["string", "null"]},
                   "due_text": {"type": ["string", "null"]},
                   "due_at": {"type": ["string", "null"], "description": "新的截止时间，ISO 8601 带时区偏移"},
                   "priority": {"type": ["string", "null"], "enum": ["high", "medium", "low", null]},
                   "details": {"type": ["string", "null"], "description": "要补进这条的新信息（电话、地址、金额、要求…），分行短条目；没有为 null"},
                   "reason": {"type": ["string", "null"]}}}},
               "remove": {"type": "array", "description": "用户说取消、不用做了的待办", "items": {"type": "object", "additionalProperties": false,
                 "required": ["id", "reason"],
                 "properties": {"id": {"type": "string", "description": "清单编号，如 #5"}, "reason": {"type": ["string", "null"]}}}},
               "suggestions": {"type": "array", "description": "用户请你出主意时你建议的事项（用户挑选后才加入）", "items": \(noteItemSchema)}
             }}
            """
    )
}
