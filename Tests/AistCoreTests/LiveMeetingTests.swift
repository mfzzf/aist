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
    // Everyone's to-dos in one list, the user's first; minutes from before topics keep their key points.
    #expect(md.contains("## 待办\n\n- [ ] **李四**：准备环境（明天）\n- [ ] **Alice**：整理需求文档（周五）\n\n## 要点\n\n- 下月开始第二阶段"))
    #expect(md.contains("**[00:01] 对方**：We start phase two next month.  \n> 我们下个月开始第二阶段。"))

    let srt = MeetingExport.srt(m.transcript!)
    #expect(srt.hasPrefix("1\n00:00:01,500 --> 00:00:04,000\n对方：We start phase two next month.\n我们下个月开始第二阶段。\n"))
    #expect(srt.contains("2\n00:01:05,000 --> 00:01:06,000\n我：好的"))

    let mail = MeetingExport.mailBody(m, myTodos: todos, myName: "李四")
    #expect(mail.contains("【待办】\n1. 李四：准备环境（明天）\n2. Alice：整理需求文档（周五）"))
    #expect(!mail.contains("We start phase two"))
}

@Test func minutesGoTopicByTopic() throws {
    let out = try MeetingSummarizer.parse("""
    {"title": "项目 A 周会", "overview": "定了分两期交付。",
     "topics": [{"title": "交付排期", "at": "02:10",
                 "points": [{"text": "张三认为月底上线有风险，测试只剩三天", "at": "02:31"}, "李四建议先交付核心模块"],
                 "conclusion": "分两期交付"},
                {"title": "报价", "at": null, "points": [{"text": "按新范围重算", "at": null}], "conclusion": " "},
                {"title": "空议题", "at": "20:00", "points": [], "conclusion": null}],
     "decisions": ["分两期交付"], "decision_at": ["09:45"], "open_questions": ["第二期验收标准谁来定"],
     "my_todos": [], "others_todos": []}
    """)
    let topics = try #require(out.summary.topics)
    // A topic with nothing under it is dropped; a blank conclusion is no conclusion.
    #expect(topics.map(\.title) == ["交付排期", "报价"])
    #expect(topics[0].time == 130)
    #expect(topics[0].points.map(\.time) == [151, nil])
    #expect(topics[0].points[1].text == "李四建议先交付核心模块")
    #expect(topics[1].conclusion == nil)
    #expect(out.summary.discussionText.contains("张三认为月底上线有风险，测试只剩三天"))
    #expect(!out.isEmpty)
    // Topics alone are minutes.
    #expect(try !MeetingSummarizer.parse(#"{"topics": [{"title": "排期", "points": ["先做核心模块"]}]}"#).isEmpty)
    // Broken topics don't cost the rest.
    let broken = try MeetingSummarizer.parse(#"{"overview": "概要", "topics": "没有", "decisions": ["定了"]}"#)
    #expect(broken.summary.topics == nil && broken.summary.decisions == ["定了"])

    var m = Meeting(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    m.title = out.title
    m.summary = out.summary
    let md = MeetingExport.markdown(m, myTodos: [], myName: "李四")
    #expect(md.contains("## 议题\n\n### 1. 交付排期（02:10）\n\n- 张三认为月底上线有风险，测试只剩三天\n- 李四建议先交付核心模块\n- **结论**：分两期交付\n\n### 2. 报价\n\n- 按新范围重算\n\n## 决定"))
    #expect(!md.contains("## 要点"))
    let mail = MeetingExport.mailBody(m, myTodos: [], myName: "李四")
    #expect(mail.contains("【议题】\n1. 交付排期\n   · 张三认为月底上线有风险，测试只剩三天\n   · 李四建议先交付核心模块\n   结论：分两期交付\n2. 报价\n   · 按新范围重算\n\n【决定】\n1. 分两期交付"))

    // Survives the store's JSON round trip.
    let back = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(out.summary))
    #expect(back == out.summary)
}

@Test func minutesPromptNamesTheUserAndAsksForTopics() {
    let zone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
    let named = MeetingSummarizer.systemPrompt(identity: [" ", "李四"], now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: zone)
    #expect(named.contains("提到用户本人时写「李四」"))
    #expect(named.contains("- topics：") && !named.contains("key_points"))
    let unnamed = MeetingSummarizer.systemPrompt(identity: [], now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: zone)
    #expect(unnamed.contains("提到用户本人时写「我」"))
    // The tool asks for what the prompt describes.
    #expect(TodoPrompt.recordMinutes.schema.contains("\"topics\"") && !TodoPrompt.recordMinutes.schema.contains("key_points"))
    #expect((try? JSONSerialization.jsonObject(with: Data(TodoPrompt.recordMinutes.schema.utf8))) != nil)
}

@Test func regeneratingKeepsEarlierMinutes() throws {
    func minutes(_ overview: String) throws -> MeetingSummary {
        try MeetingSummarizer.parse(#"{"overview": "\#(overview)", "decisions": ["定了"]}"#).summary
    }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var m = Meeting(startedAt: start)
    // The first minutes replace nothing.
    m.replaceSummary(try minutes("第一版"), title: "周会", at: start.addingTimeInterval(1800))
    #expect(m.summaryHistory == nil && m.summaryCreatedAt == start.addingTimeInterval(1800))
    m.replaceSummary(try minutes("第二版"), title: "项目周会", at: start.addingTimeInterval(86400))
    let first = try #require(m.summaryHistory?.first)
    #expect(m.summaryHistory?.count == 1)
    #expect(first.summary.overview == "第一版" && first.title == "周会" && first.createdAt == start.addingTimeInterval(1800))
    #expect(m.summary?.overview == "第二版" && m.title == "项目周会")

    // Reading the earlier version doesn't change the meeting.
    let old = m.showing(version: first.id)
    #expect(old.summary?.overview == "第一版" && old.title == "周会")
    #expect(m.showing(version: nil) == m && m.showing(version: UUID()) == m)

    // Restoring swaps the two.
    m.restoreSummary(first.id)
    #expect(m.summary?.overview == "第一版" && m.title == "周会")
    #expect(m.summaryHistory?.map(\.summary.overview) == ["第二版"])
    let second = try #require(m.summaryHistory?.first)
    m.deleteSummaryVersion(second.id)
    #expect(m.summaryHistory == nil && m.summary?.overview == "第一版")

    // A title the user typed stays through regenerating and restoring.
    m.title = "我起的名字"
    m.titleEdited = true
    m.replaceSummary(try minutes("第三版"), title: m.title)
    m.restoreSummary(try #require(m.summaryHistory?.first?.id))
    #expect(m.title == "我起的名字" && m.summary?.overview == "第一版")
}

@Test func meetingsFromBeforeVersionsStillLoad() throws {
    // As an older build saved it: no topics, no history, no date on the minutes.
    let json = """
    [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "title": "项目 A 周会", "startedAt": "2027-01-15T08:00:00Z",
      "duration": 1800, "status": "ready",
      "summary": {"overview": "定了第二阶段日期", "key_points": ["文档周三完成"], "key_point_at": ["00:23"],
                  "decisions": [], "others_todos": [], "open_questions": []}}]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var m = try #require(try decoder.decode([Meeting].self, from: Data(json.utf8)).first)
    #expect(m.summary?.topics == nil && m.summary?.keyPoints == ["文档周三完成"])
    #expect(m.summaryHistory == nil && m.summaryCreatedAt == nil)
    // Regenerating files the old minutes under the meeting's own start.
    m.replaceSummary(try MeetingSummarizer.parse(#"{"topics": [{"title": "排期", "points": ["先做核心模块"]}]}"#).summary, title: m.title)
    #expect(m.summaryHistory?.first?.createdAt == m.startedAt)
    #expect(m.summaryHistory?.first?.summary.keyPoints == ["文档周三完成"])
}

@Test func liveNotesDecodeLeniently() throws {
    let notes = try JSONDecoder().decode(LiveNotes.self, from: Data("""
    {"summary": "在谈排期", "my_todos": [{"text": "准备环境", "who": null, "at": "02:10"}]}
    """.utf8))
    #expect(notes.myTodos.first?.time == 130)
    #expect(notes.topics.isEmpty && !notes.isEmpty)
}
