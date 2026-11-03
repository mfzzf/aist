@testable import AistCore
import Foundation
import Testing

// All examples here are made up: placeholder names (张三, 李四, Alice), "项目 A", generic wording.
// Never paste real transcripts, names or recordings into tests.

// MARK: HeardText

@Test func cleansRecognitionNoise() {
    #expect(HeardText.clean("。，那个，我们 ,, 开始吧") == "那个，我们, 开始吧")
    #expect(HeardText.clean("in.......... the plan") == "in… the plan")
    #expect(HeardText.clean(", , so") == "so")
    #expect(!HeardText.hasWords("。…"))
}

@Test func joinsASentenceCutAtAPause() {
    // Chinese cut by Aist at a pause: the guessed "。" goes.
    #expect(HeardText.continues("文档需要在周三之前完成。", "由张三负责", gap: 0.4, cut: true))
    #expect(HeardText.join("文档需要在周三之前完成。", "由张三负责") == "文档需要在周三之前完成由张三负责")
    // The speaker's own full stop and a question stay separate lines.
    #expect(!HeardText.continues("文档完成了。", "下一个议题", gap: 0.4, cut: false))
    #expect(!HeardText.continues("Is that okay?", "yes", gap: 0.2, cut: true))
    // English: a cut "." before a lower-case word joins with a space.
    #expect(HeardText.continues("we will ship version two.", "on the first of the month", gap: 0.3, cut: true))
    #expect(HeardText.join("we will ship version two.", "on the first of the month") == "we will ship version two on the first of the month")
    // Too far apart.
    #expect(!HeardText.continues("我们先看一下", "排期", gap: 3, cut: false))
}

@Test func dropsMicrophoneEchoOfTheOtherSide() {
    let theirs = TranscriptSegment(speaker: .others, start: 10, end: 14, text: "项目A会在下个月一号开始第二阶段")
    let echo = TranscriptSegment(speaker: .me, start: 10.3, end: 14.2, text: "项目A会在下个月1号开始第二阶")
    let mine = TranscriptSegment(speaker: .me, start: 15, end: 17, text: "好的，那我这边准备一下环境")
    let late = TranscriptSegment(speaker: .me, start: 40, end: 43, text: "项目A会在下个月一号开始第二阶段")
    let kept = HeardText.removingEchoes([theirs, echo, mine, late])
    #expect(kept.map(\.text) == [theirs.text, mine.text, late.text])
}

@Test func dropsAGarbledEchoThatStartedTogether() {
    // The microphone hears the speakers; recognition of the echo swaps some characters, which breaks
    // most character pairs but keeps most single characters.
    let theirs = TranscriptSegment(speaker: .others, start: 60, end: 68, text: "我们下周把项目A的方案再过一遍然后定下来")
    let echo = TranscriptSegment(speaker: .me, start: 60, end: 67, text: "我们下周把项目诶的方按再过一边然后订下来")
    let hello = TranscriptSegment(speaker: .me, start: 30, end: 31, text: "你好。")
    #expect(HeardText.removingEchoes([hello, theirs, echo]).map(\.text) == [hello.text, theirs.text])
    // Answering at the same moment with other words is kept.
    let reply = TranscriptSegment(speaker: .me, start: 60.5, end: 62, text: "好的没问题")
    #expect(!HeardText.isEcho(reply, of: [theirs]))
}

// MARK: Meeting end

@Test func endsAfterTheMeetingAppHangsUp() {
    let t0 = Date(timeIntervalSince1970: 0)
    var w = MeetingEndWatch(config: .init(followApps: true, silenceAfter: 600), start: t0)
    let call = ["com.example.meeting": "会议软件"]
    #expect(w.tick(at: t0.addingTimeInterval(5), calls: call, said: true) == nil)
    // Hung up: a grace period, then the end.
    #expect(w.tick(at: t0.addingTimeInterval(60), calls: [:], said: true) == nil)
    #expect(w.pending?.reason == .appLeft("会议软件"))
    // Rejoined within the grace: nothing ends.
    #expect(w.tick(at: t0.addingTimeInterval(70), calls: call, said: true) == nil)
    #expect(w.pending == nil)
    _ = w.tick(at: t0.addingTimeInterval(80), calls: [:], said: true)
    #expect(w.tick(at: t0.addingTimeInterval(111), calls: [:], said: true) == .appLeft("会议软件"))
}

@Test func silenceEndsOnlyOutsideACall() {
    let t0 = Date(timeIntervalSince1970: 0)
    var w = MeetingEndWatch(config: .init(followApps: true, silenceAfter: 600), start: t0)
    // A muted webinar: still in the call, so silence doesn't count.
    #expect(w.tick(at: t0.addingTimeInterval(700), calls: ["com.example.meeting": "会议软件"], said: true) == nil)
    #expect(w.pending == nil)
    // In the room (no meeting app): a countdown, which words stop.
    var room = MeetingEndWatch(config: .init(followApps: false, silenceAfter: 600), start: t0)
    #expect(room.tick(at: t0.addingTimeInterval(601), calls: [:], said: true) == nil)
    #expect(room.pending?.reason == .silence)
    room.heard(at: t0.addingTimeInterval(620))
    #expect(room.pending == nil)
    _ = room.tick(at: t0.addingTimeInterval(1221), calls: [:], said: true)
    #expect(room.tick(at: t0.addingTimeInterval(1282), calls: [:], said: true) == .silence)
    // Nobody ever spoke: stops without a countdown.
    var empty = MeetingEndWatch(config: .init(followApps: false, silenceAfter: 600), start: t0)
    #expect(empty.tick(at: t0.addingTimeInterval(601), calls: [:], said: false) == .nobodySpoke)
}

// MARK: Times, minutes, export

@Test func readsTimestampsAndFindsQuotes() {
    #expect(MeetingTime.seconds("01:05") == 65)
    #expect(MeetingTime.seconds("[1:02:03]") == 3723)
    #expect(MeetingTime.seconds("soon") == nil)
    #expect(MeetingTime.stamp(3723) == "1:02:03")
    let lines = [
        TranscriptSegment(speaker: .others, start: 12, end: 15, text: "文档需要在周三之前完成，由张三负责"),
        TranscriptSegment(speaker: .me, start: 20, end: 22, text: "好的我来跟进排期"),
    ]
    #expect(MeetingTime.find("我来跟进排期", in: lines)?.start == 20)
    #expect(MeetingTime.find("完全无关的一句话", in: lines) == nil)
}

@Test func decodesMinutesWithTermsAndTimes() throws {
    let json = """
    {"title": "项目 A 周会", "overview": "定了第二阶段日期", "key_points": ["文档周三完成"], "key_point_at": ["00:23"],
     "decisions": ["下月一号开始第二阶段"], "decision_at": [null], "open_questions": [], "my_todos": [],
     "others_todos": [{"who": "张三", "task": "完成文档", "due_text": "周三", "at": "00:23"}],
     "terms": [{"name": "项目A", "note": "本次讨论的项目", "heard": ["项目诶", "项目A"]}]}
    """
    let out = try MeetingSummarizer.parse(json)
    #expect(out.summary.keyPointTime(0) == 23)
    #expect(out.summary.decisionTime(0) == nil)
    #expect(out.summary.othersActions.first?.time == 23)
    // The correct spelling isn't listed as a mishearing of itself.
    #expect(out.summary.terms?.first?.heard == ["项目诶"])
    #expect(!out.isEmpty)
    #expect(try MeetingSummarizer.parse(#"{"record_minutes": {}}"#).isEmpty)
}

@Test func exportsMinutesSubtitlesAndMail() throws {
    var m = Meeting(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    m.title = "项目 A 周会"
    m.duration = 1800
    m.transcript = [
        TranscriptSegment(speaker: .others, start: 1.5, end: 4, text: "We start phase two next month.", translation: "我们下个月开始第二阶段。"),
        TranscriptSegment(speaker: .me, start: 65, end: 66, text: "好的"),
    ]
    m.summary = try MeetingSummarizer.parse("""
    {"overview": "定了第二阶段日期", "key_points": ["下月开始第二阶段"], "decisions": [], "open_questions": [], "my_todos": [],
     "others_todos": [{"who": "Alice", "task": "整理需求文档", "due_text": "周五", "at": null}]}
    """).summary
    let todos = [MeetingExport.Todo(title: "准备环境", due: "明天", done: false)]

    let md = MeetingExport.markdown(m, myTodos: todos, myName: "李四")
    #expect(md.hasPrefix("# 项目 A 周会"))
    #expect(md.contains("## 李四的待办\n\n- [ ] 准备环境（明天）"))
    #expect(md.contains("- [ ] **Alice**：整理需求文档（周五）"))
    #expect(md.contains("**[00:01] 对方**：We start phase two next month.  \n> 我们下个月开始第二阶段。"))

    let srt = MeetingExport.srt(m.transcript!)
    #expect(srt.hasPrefix("1\n00:00:01,500 --> 00:00:04,000\n对方：We start phase two next month.\n我们下个月开始第二阶段。\n"))
    #expect(srt.contains("2\n00:01:05,000 --> 00:01:06,000\n我：好的"))

    let mail = MeetingExport.mailBody(m, myTodos: todos, myName: "李四")
    #expect(mail.contains("【待办】\n1. 李四：准备环境（明天）\n2. Alice：整理需求文档（周五）"))
    #expect(!mail.contains("We start phase two"))
}

@Test func liveNotesDecodeLeniently() throws {
    let notes = try JSONDecoder().decode(LiveNotes.self, from: Data("""
    {"summary": "在谈排期", "my_todos": [{"text": "准备环境", "who": null, "at": "02:10"}]}
    """.utf8))
    #expect(notes.myTodos.first?.time == 130)
    #expect(notes.topics.isEmpty && !notes.isEmpty)
}
