import Foundation

/// What the model returns for one to-do (snake_case to match the prompt).
public struct ExtractedTodo: Codable, Sendable, Equatable {
    public var title: String
    public var requester: String?
    public var source: String?
    public var dueText: String?
    public var dueAt: String?
    public var priority: TodoPriority?
    public var evidence: String?
    /// Id of an existing open to-do this is the same matter as.
    public var duplicateOf: String?
    /// The AI's suggested next step.
    public var suggestion: String?
    /// Specifics from the source the title can't hold: contacts, place, amounts, numbers, links (one per line).
    public var details: String?

    enum CodingKeys: String, CodingKey {
        case title, requester, source, priority, evidence, suggestion, details
        case dueText = "due_text"
        case dueAt = "due_at"
        case duplicateOf = "duplicate_of"
    }

    public init(title: String, requester: String? = nil, source: String? = nil, dueText: String? = nil,
                dueAt: String? = nil, priority: TodoPriority? = nil, evidence: String? = nil,
                duplicateOf: String? = nil, suggestion: String? = nil, details: String? = nil) {
        self.suggestion = suggestion
        self.details = details
        self.title = title
        self.requester = requester
        self.source = source
        self.dueText = dueText
        self.dueAt = dueAt
        self.priority = priority
        self.evidence = evidence
        self.duplicateOf = duplicateOf
    }

    public var resolvedDueAt: Date? { dueAt.flatMap(TodoExtractor.parseDate) }
}

public struct CaptureContext: Sendable {
    public var frontApp: String?
    public var windowTitle: String?

    public init(frontApp: String? = nil, windowTitle: String? = nil) {
        self.frontApp = frontApp
        self.windowTitle = windowTitle
    }
}

/// What one extraction returned: the to-dos, plus the model's one-line reason when there are none
/// ("是别人之间的讨论，没有交代给你"), so an empty result can say why instead of just "没有发现".
public struct Extraction: Sendable, Equatable {
    public var analysis: String?
    public var noTodoReason: String?
    public var todos: [ExtractedTodo]

    public init(analysis: String? = nil, noTodoReason: String? = nil, todos: [ExtractedTodo]) {
        self.analysis = analysis
        self.noTodoReason = noTodoReason
        self.todos = todos
    }
}

public struct TodoExtractor: Sendable {
    public let client: LLMClient
    /// The user's names and handles (display name, email, GitHub login…), so "@张三" is recognised as the user.
    public var identity: [String]
    /// The user's own description of their work (see `TodoPrompt.background`).
    public var background: String

    public init(client: LLMClient, identity: [String] = [], background: String = "") {
        self.client = client
        self.identity = identity
        self.background = background
    }

    public enum ExtractError: LocalizedError {
        case unparsable(String)
        public var errorDescription: String? {
            if case let .unparsable(raw) = self { return "无法解析 AI 返回的结果：\(raw.prefix(120))" }
            return nil
        }
    }

    /// Extracts the user's to-dos from a screenshot. `existing` lets the model mark repeats instead of duplicating them.
    public func extract(imageJPEG: Data, context: CaptureContext, existing: [TodoItem],
                        now: Date = .now, timeZone: TimeZone = .current) async throws -> [ExtractedTodo] {
        try await analyze(imageJPEG: imageJPEG, context: context, existing: existing, now: now, timeZone: timeZone).todos
    }

    /// Same as `extract(imageJPEG:)`, keeping the model's reason when it found nothing.
    public func analyze(imageJPEG: Data, context: CaptureContext, existing: [TodoItem],
                        now: Date = .now, timeZone: TimeZone = .current) async throws -> Extraction {
        var info = "前台应用：\(context.frontApp ?? "未知")"
        if let title = context.windowTitle, !title.isEmpty { info += "\n窗口标题：\(title)" }
        info += "\n已有待办：\(Self.existingJSON(existing))"
        return try Self.parseExtraction(await client.callTool(
            system: TodoPrompt.extraction(.screenshot, identity: identity, background: background, now: now, timeZone: timeZone),
            parts: [.image(imageJPEG, mediaType: "image/jpeg"), .text(info)],
            tool: TodoPrompt.recordTodos
        ))
    }

    /// A chat transcript as text, judged with the screenshot rules (for testing prompts without images).
    public func extract(chatText: String, app: String, existing: [TodoItem] = [],
                        now: Date = .now, timeZone: TimeZone = .current) async throws -> [ExtractedTodo] {
        try Self.parse(await client.callTool(
            system: TodoPrompt.extraction(.screenshot, identity: identity, background: background, now: now, timeZone: timeZone),
            parts: [.text("（截图内容的文字版，「我：」开头的是右侧气泡，即用户本人）\n\(chatText)\n\n前台应用：\(app)\n已有待办：\(Self.existingJSON(existing))")],
            tool: TodoPrompt.recordTodos
        ))
    }

    /// Extracts the user's to-dos from one email (plain text with sender, recipients, subject, body).
    public func extract(email: String, existing: [TodoItem],
                        now: Date = .now, timeZone: TimeZone = .current) async throws -> [ExtractedTodo] {
        let text = "已有待办：\(Self.existingJSON(existing))\n\n邮件：\n\(email.prefix(24_000))"
        return try Self.parse(await client.callTool(
            system: TodoPrompt.extraction(.email, identity: identity, background: background, now: now, timeZone: timeZone),
            parts: [.text(text)],
            tool: TodoPrompt.recordTodos
        ))
    }

    /// Extracts to-dos from something the user typed or dictated into the phone.
    public func extract(note: String, existing: [TodoItem],
                        now: Date = .now, timeZone: TimeZone = .current) async throws -> [ExtractedTodo] {
        let text = "已有待办：\(Self.existingJSON(existing))\n\n用户记下的话：\n\(note.prefix(12_000))"
        return try Self.parse(await client.callTool(
            system: TodoPrompt.extraction(.note, identity: identity, background: background, now: now, timeZone: timeZone),
            parts: [.text(text)],
            tool: TodoPrompt.recordTodos
        ))
    }

    // MARK: - Prompt

    static func calendarTable(now: Date, timeZone: TimeZone) -> String {
        TodoPrompt.calendarTable(now: now, timeZone: timeZone)
    }

    static func existingJSON(_ items: [TodoItem]) -> String {
        let compact = items.filter { $0.status == .open }.map { ["id": $0.id.uuidString, "title": $0.title] }
        guard let data = try? JSONSerialization.data(withJSONObject: compact, options: [.withoutEscapingSlashes]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    /// Tool arguments are the envelope itself; text falls back to the tolerant parser.
    public static func parse(_ result: LLMClient.ToolResult) throws -> [ExtractedTodo] {
        try parseExtraction(result).todos
    }

    public static func parseExtraction(_ result: LLMClient.ToolResult) throws -> Extraction {
        if ProcessInfo.processInfo.environment["AIST_DEBUG"] != nil {
            let (kind, body): (String, String) = switch result {
            case let .arguments(d): ("tool", String(decoding: d, as: UTF8.self))
            case let .text(t): ("text", t)
            }
            FileHandle.standardError.write(Data("[\(kind)] \(body.prefix(600))\n".utf8))
        }
        switch result {
        case let .arguments(data):
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                throw ExtractError.unparsable(String(decoding: data, as: UTF8.self))
            }
            return envelope.extraction
        case let .text(raw):
            return try parseExtraction(raw)
        }
    }

    private struct Envelope: Decodable {
        var analysis: String?
        var noTodoReason: String?
        var todos: [ExtractedTodo]

        enum CodingKeys: String, CodingKey {
            case analysis, todos
            case noTodoReason = "no_todo_reason"
        }

        var extraction: Extraction {
            Extraction(analysis: analysis?.nilIfBlank, noTodoReason: noTodoReason?.nilIfBlank,
                       todos: todos.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }

    public static func parse(_ raw: String) throws -> [ExtractedTodo] {
        try parseExtraction(raw).todos
    }

    /// Accepts `{"analysis": …, "todos": [...]}` (the current prompt) or a bare array (older prompts, other models),
    /// tolerating code fences and surrounding prose.
    public static func parseExtraction(_ raw: String) throws -> Extraction {
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
           raw.firstIndex(of: "[").map({ start < $0 }) ?? true,
           let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(raw[start ... end].utf8)) {
            return envelope.extraction
        }
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end else {
            throw ExtractError.unparsable(raw)
        }
        let json = Data(raw[start ... end].utf8)
        do {
            return Extraction(todos: try JSONDecoder().decode([ExtractedTodo].self, from: json)
                .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        } catch {
            throw ExtractError.unparsable(raw)
        }
    }

    public static func parseDate(_ string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate],
        ] {
            fmt.formatOptions = options
            if let date = fmt.date(from: string) { return date }
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
