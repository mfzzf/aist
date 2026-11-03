import Foundation

// Adapted from Cicada (知了, https://github.com/wquguru/cicada, Apache-2.0): HeardText.swift.

/// Finished lines from live speech recognition, before they are kept: tidied, joined to the line
/// before when a pause cut one sentence in two, and dropped when the microphone only picked up
/// the other side through the speakers.
public enum HeardText {
    /// Speech recognition leaves stray marks where it hears breaths and hesitations: "in..........",
    /// ", , that", "。，那个". They start lines and read as noise in the minutes.
    public static func clean(_ text: String) -> String {
        var s = text
        // Two dots or more, with or without spaces or commas between: one ellipsis.
        s = s.replacingOccurrences(of: #"\s*[.。]{2,}|\s*…+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"…(?:[\s,，]*…)+"#, with: "…", options: .regularExpression)
        // ", ," and ",," are one comma; a comma against an ellipsis adds nothing.
        s = s.replacingOccurrences(of: #"([,，])(?:\s*[,，])+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,，]\s*…|…\s*[,，]"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,，.。…?？!！;；:：])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // A line starts with a word, not with what was left of the last one.
        let lead: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "、", "，", "。", "；", "：", "！", "？", "-", "–", "—"]
        s = String(s.drop(while: { lead.contains($0) || $0.isWhitespace }))
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Has words in it (a lone "。" or "…" from a breath is no line).
    public static func hasWords(_ text: String) -> Bool { text.contains(where: \.isLetter) }

    /// The longest pause, in seconds, that still joins two pieces of one sentence.
    public static let joinGap = 1.5
    /// A line this long takes nothing more: past it the line gets hard to read.
    public static let joinWords = 40

    /// Whether `next` carries on `previous` from the same voice rather than starting a sentence.
    /// `gap`: seconds between them. `cut`: Aist ended `previous` at a pause, so its closing "." is
    /// the recognizer's guess, not the speaker's.
    public static func continues(_ previous: String, _ next: String, gap: Double, cut: Bool) -> Bool {
        guard gap >= -0.5, gap <= joinGap, let last = previous.last, let first = next.first else { return false }
        let cjk = isCJK(previous)
        let size = cjk ? previous.count / 2 : previous.split(separator: " ").count
        guard size < joinWords else { return false }
        switch last {
        case "?", "!", "？", "！": return false
        case ".", "。": return cut && (first.isLowercase || cjk)
        default: return true
        }
    }

    public static func join(_ previous: String, _ next: String) -> String {
        var head = previous
        if head.hasSuffix(".") && !head.hasSuffix("…") { head.removeLast() }
        if head.hasSuffix("。") { head.removeLast() }
        return isCJK(previous) ? head + next : head + " " + next
    }

    static func isCJK(_ text: String) -> Bool { text.unicodeScalars.contains { $0.properties.isIdeographic } }

    // MARK: Echo

    /// Without headphones the microphone also hears the other side through the speakers, so the
    /// same words come back on the "me" track. A mic line is an echo when a line from the other
    /// side overlapping it in time says mostly the same thing.
    public static func isEcho(_ mine: TranscriptSegment, of theirs: [TranscriptSegment]) -> Bool {
        let a = letters(mine.text)
        guard a.count >= 2 else { return false }
        for t in theirs where t.start - 3 <= mine.end && mine.start <= t.end + 3 {
            let b = letters(t.text)
            if similarity(a, b) >= 0.6 { return true }
            // Started together: recognition of the echo garbles some characters (a word heard as a
            // near-homophone), which breaks pairs but leaves most single characters in common.
            if abs(t.start - mine.start) <= 1.5, overlap(a, b) >= 0.6 { return true }
        }
        return false
    }

    /// Share of `a`'s characters found in `b` (as a multiset).
    static func overlap(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty else { return 0 }
        var pool: [Character: Int] = [:]
        for c in b { pool[c, default: 0] += 1 }
        var hit = 0
        for c in a where (pool[c] ?? 0) > 0 {
            hit += 1
            pool[c]! -= 1
        }
        return Double(hit) / Double(a.count)
    }

    /// Drops the mic lines that only repeat the other side.
    public static func removingEchoes(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let theirs = segments.filter { $0.speaker == .others }
        return segments.filter { $0.speaker == .others || !isEcho($0, of: theirs) }
    }

    private static func letters(_ s: String) -> [Character] {
        s.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    /// Share of `a`'s character bigrams found in `b` (CJK text has no word boundaries).
    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        guard a.count >= 2, b.count >= 2 else { return 0 }
        var pool: [String: Int] = [:]
        for i in 0 ..< b.count - 1 { pool[String([b[i], b[i + 1]]), default: 0] += 1 }
        var hit = 0
        for i in 0 ..< a.count - 1 {
            let k = String([a[i], a[i + 1]])
            if let n = pool[k], n > 0 {
                hit += 1
                pool[k] = n - 1
            }
        }
        return Double(hit) / Double(a.count - 1)
    }
}
