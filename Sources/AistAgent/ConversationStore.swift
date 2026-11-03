import AistAI
import Foundation
import SQLite3

public struct ConversationSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var scope: String
    public var createdAt: Date
    public var updatedAt: Date
}

/// Conversations in SQLite (system libsqlite3): one row per message, so saving a finished answer is
/// one INSERT however long the chat is, and opening a chat reads only its own rows. WAL mode keeps
/// reads from blocking on writes; FTS5 (trigram, works for Chinese) backs search.
///
/// `scope` separates hosts: "chat" for the Q&A pane, e.g. "mail:<id>" for a pop-up about one mail.
public actor ConversationStore {
    private var db: OpaquePointer?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aist/agent.sqlite")
    }

    public enum StoreError: LocalizedError {
        case sqlite(String)
        public var errorDescription: String? {
            if case let .sqlite(m) = self { return "会话存储出错：\(m)" }
            return nil
        }
    }

    public init(url: URL = ConversationStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw StoreError.sqlite(msg)
        }
        db = handle
        try Self.exec(handle, """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS conversations (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            scope TEXT NOT NULL DEFAULT 'chat',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS conversations_scope_updated ON conversations(scope, updated_at DESC);
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            model TEXT,
            json BLOB NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(conversation_id, seq)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(text, conversation_id UNINDEXED, seq UNINDEXED, tokenize = 'trigram');
        """)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Conversations

    public func conversations(scope: String = "chat", limit: Int = 500) throws -> [ConversationSummary] {
        try query("SELECT id, title, scope, created_at, updated_at FROM conversations WHERE scope = ? ORDER BY updated_at DESC LIMIT ?",
                  [.text(scope), .int(limit)], row: Self.summary)
    }

    /// Title or message text containing `text`.
    public func search(_ text: String, scope: String = "chat") throws -> [ConversationSummary] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return try conversations(scope: scope) }
        let like = "%" + q.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        // Trigram FTS needs ≥3 characters; shorter queries match titles only.
        if q.count >= 3 {
            let phrase = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return try query("""
            SELECT id, title, scope, created_at, updated_at FROM conversations
            WHERE scope = ? AND (title LIKE ? ESCAPE '\\' OR id IN (SELECT conversation_id FROM messages_fts WHERE messages_fts MATCH ?))
            ORDER BY updated_at DESC LIMIT 200
            """, [.text(scope), .text(like), .text(phrase)], row: Self.summary)
        }
        return try query("""
        SELECT id, title, scope, created_at, updated_at FROM conversations
        WHERE scope = ? AND title LIKE ? ESCAPE '\\' ORDER BY updated_at DESC LIMIT 200
        """, [.text(scope), .text(like)], row: Self.summary)
    }

    public func create(id: UUID = UUID(), title: String, scope: String = "chat", at date: Date = .now) throws -> ConversationSummary {
        try run("INSERT INTO conversations (id, title, scope, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                [.text(id.uuidString), .text(title), .text(scope), .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970)])
        return ConversationSummary(id: id, title: title, scope: scope, createdAt: date, updatedAt: date)
    }

    public func rename(_ id: UUID, to title: String) throws {
        try run("UPDATE conversations SET title = ? WHERE id = ?", [.text(title), .text(id.uuidString)])
    }

    public func delete(_ id: UUID) throws {
        try transaction {
            try run("DELETE FROM messages_fts WHERE conversation_id = ?", [.text(id.uuidString)])
            try run("DELETE FROM messages WHERE conversation_id = ?", [.text(id.uuidString)])
            try run("DELETE FROM conversations WHERE id = ?", [.text(id.uuidString)])
        }
    }

    // MARK: - Messages

    public func messages(of id: UUID) throws -> [Message] {
        try query("SELECT json FROM messages WHERE conversation_id = ? ORDER BY seq", [.text(id.uuidString)]) { stmt in
            guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            return try? self.decoder.decode(Message.self, from: data)
        }
    }

    /// Appends messages after the ones already stored, in one transaction, and bumps `updated_at`.
    public func append(_ messages: [Message], to id: UUID) throws {
        guard !messages.isEmpty else { return }
        try transaction {
            let next = try query("SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE conversation_id = ?",
                                 [.text(id.uuidString)]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
            for (offset, message) in messages.enumerated() {
                let data = try encoder.encode(message)
                var model: Value = .null
                if case let .assistant(a) = message { model = .text(a.model) }
                try run("INSERT INTO messages (conversation_id, seq, role, model, json, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                        [.text(id.uuidString), .int(next + offset), .text(message.role), model, .blob(data),
                         .real(message.timestamp.timeIntervalSince1970)])
                let text = Self.searchableText(message)
                if !text.isEmpty {
                    try run("INSERT INTO messages_fts (text, conversation_id, seq) VALUES (?, ?, ?)",
                            [.text(text), .text(id.uuidString), .int(next + offset)])
                }
            }
            try run("UPDATE conversations SET updated_at = ? WHERE id = ?", [.real(Date.now.timeIntervalSince1970), .text(id.uuidString)])
        }
    }

    /// Keeps the first `count` messages and drops the rest (retrying an answer).
    public func truncate(_ id: UUID, keeping count: Int) throws {
        try transaction {
            try run("DELETE FROM messages_fts WHERE conversation_id = ? AND seq >= ?", [.text(id.uuidString), .int(count)])
            try run("DELETE FROM messages WHERE conversation_id = ? AND seq >= ?", [.text(id.uuidString), .int(count)])
        }
    }

    static func searchableText(_ m: Message) -> String {
        switch m {
        case let .user(u): u.content.compactMap { if case let .text(t) = $0 { t } else { nil } }.joined(separator: "\n")
        case let .assistant(a): a.text
        case .toolResult: ""
        }
    }

    // MARK: - SQLite plumbing

    enum Value {
        case text(String), int(Int), real(Double), blob(Data), null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw StoreError.sqlite(msg)
        }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case let .text(s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case let .int(n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case let .real(d): sqlite3_bind_double(stmt, idx, d)
            case let .blob(data): _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(data.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ params: [Value] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ params: [Value], row: (OpaquePointer?) throws -> T?) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            if let v = try row(stmt) { out.append(v) }
        }
        return out
    }

    private func transaction(_ body: () throws -> Void) throws {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            try body()
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    private static func summary(_ stmt: OpaquePointer?) -> ConversationSummary? {
        guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { return nil }
        return ConversationSummary(
            id: id, title: String(cString: sqlite3_column_text(stmt, 1)), scope: String(cString: sqlite3_column_text(stmt, 2)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        )
    }
}
