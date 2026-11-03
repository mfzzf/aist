import Foundation

/// A meeting as text to take elsewhere: Markdown minutes, SRT subtitles, and the body of the
/// "发送纪要" mail.
public enum MeetingExport {
    /// One of the user's to-dos from the meeting, as the export shows it.
    public struct Todo: Sendable {
        public var title: String
        public var due: String?
        public var done: Bool

        public init(title: String, due: String?, done: Bool) {
            self.title = title
            self.due = due
            self.done = done
        }
    }

    static func dateLine(_ m: Meeting) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        var s = f.string(from: m.startedAt)
        if m.duration > 0 { s += "，\(max(1, Int(m.duration / 60))) 分钟" }
        return s
    }

    /// Minutes, the user's to-dos and everyone else's, optionally the transcript.
    public static func markdown(_ m: Meeting, myTodos: [Todo], myName: String = "我", transcript: Bool = true) -> String {
        var out = "# \(m.title)\n\n"
        out += "- 时间：\(dateLine(m))\n"
        if let people = m.attendees, !people.isEmpty { out += "- 参会人：\(people.joined(separator: "、"))\n" }
        out += "\n"
        if let s = m.summary {
            if !s.overview.isEmpty { out += "## 概要\n\n\(s.overview)\n\n" }
            out += list("要点", s.keyPoints)
            out += list("决定", s.decisions)
            let mine = myTodos.map { "- [\($0.done ? "x" : " ")] \($0.title)" + ($0.due.map { "（\($0)）" } ?? "") }
            if !mine.isEmpty { out += "## \(myName)的待办\n\n" + mine.joined(separator: "\n") + "\n\n" }
            let others = s.othersActions.map { a in
                "- [ ] " + (a.who.map { "**\($0)**：" } ?? "") + a.task + (a.dueText.map { "（\($0)）" } ?? "")
            }
            if !others.isEmpty { out += "## 其他人的待办\n\n" + others.joined(separator: "\n") + "\n\n" }
            out += list("待跟进", s.openQuestions)
            if let terms = s.terms, !terms.isEmpty {
                out += "## 人名与术语\n\n" + terms.map { t in
                    "- **\(t.name)**" + (t.note.isEmpty ? "" : "：\(t.note)") + (t.heard.isEmpty ? "" : "（转写中听成：\(t.heard.joined(separator: "、"))）")
                }.joined(separator: "\n") + "\n\n"
            }
        }
        if let notes = m.notes, !notes.isEmpty { out += "## 备注\n\n\(notes)\n\n" }
        if transcript, let lines = m.transcript, !lines.isEmpty {
            out += "## 转写\n\n" + lines.map { seg in
                var line = "**[\(MeetingTime.stamp(seg.start))] \(seg.speaker == .me ? "我" : "对方")**：\(seg.text)"
                if let t = seg.translation, !t.isEmpty { line += "  \n> \(t)" }
                return line
            }.joined(separator: "\n\n") + "\n"
        }
        return out
    }

    private static func list(_ title: String, _ items: [String]) -> String {
        items.isEmpty ? "" : "## \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
    }

    /// SRT subtitles of the transcript (with the translation on a second line when there is one).
    public static func srt(_ transcript: [TranscriptSegment]) -> String {
        func t(_ s: Double) -> String {
            let ms = Int((max(0, s) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return transcript.enumerated().map { i, seg in
            var text = (seg.speaker == .me ? "我：" : "对方：") + seg.text
            if let tr = seg.translation, !tr.isEmpty { text += "\n" + tr }
            return "\(i + 1)\n\(t(seg.start)) --> \(t(max(seg.end, seg.start + 1)))\n\(text)\n"
        }.joined(separator: "\n")
    }

    /// The plain-text mail: minutes plus both sides' to-dos, no transcript.
    public static func mailBody(_ m: Meeting, myTodos: [Todo], myName: String) -> String {
        var out = "各位好，\n\n以下是「\(m.title)」的会议纪要（\(dateLine(m))）。\n\n"
        guard let s = m.summary else { return out }
        if !s.overview.isEmpty { out += "【概要】\n\(s.overview)\n\n" }
        out += section("要点", s.keyPoints)
        out += section("决定", s.decisions)
        var todos: [String] = myTodos.filter { !$0.done }.map { "\(myName)：\($0.title)" + ($0.due.map { "（\($0)）" } ?? "") }
        todos += s.othersActions.map { ($0.who ?? "待定") + "：" + $0.task + ($0.dueText.map { "（\($0)）" } ?? "") }
        out += section("待办", todos)
        out += section("待跟进", s.openQuestions)
        out += "如有遗漏或需要更正，请直接回复。\n"
        return out
    }

    private static func section(_ title: String, _ items: [String]) -> String {
        items.isEmpty ? "" : "【\(title)】\n" + items.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n") + "\n\n"
    }
}
