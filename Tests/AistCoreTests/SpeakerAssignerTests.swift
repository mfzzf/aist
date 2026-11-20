@testable import AistCore
import Foundation
import Testing

// Invented voices and lines only.

/// A made-up voiceprint: mostly along axis `axis`, a little along `lean`.
private func voiceprint(_ axis: Int, lean: Int? = nil) -> [Float] {
    var v = [Float](repeating: 0, count: 8)
    v[axis] = 1
    if let lean { v[lean] = 0.3 }
    return v
}

private func turn(_ voice: String, _ start: Double, _ end: Double) -> VoiceTurn { VoiceTurn(voice: voice, start: start, end: end) }

@Test func voiceprintDistance() {
    #expect(VoiceMatch.distance(voiceprint(0), voiceprint(0)) < 1e-9)
    #expect(abs(VoiceMatch.distance(voiceprint(0), voiceprint(1)) - 1) < 1e-9)
    #expect(VoiceMatch.distance(voiceprint(0), voiceprint(0, lean: 1)) < 0.1)
    // Nothing to compare is as far as can be.
    #expect(VoiceMatch.distance([], []) == 2 && VoiceMatch.distance([1, 0], [1]) == 2)
}

@Test func aCallHasTheOthersTheirEchoAndTheUser() {
    // On the computer: two people. At the microphone: both of them through the speakers, the user,
    // and a cough.
    let system = TrackVoices(turns: [turn("x", 0, 60), turn("y", 60, 80), turn("x", 80, 100)],
                             prints: ["x": voiceprint(0), "y": voiceprint(1)])
    let mic = TrackVoices(turns: [turn("p", 0.1, 60), turn("q", 60.1, 80), turn("r", 100, 130), turn("z", 131, 133)],
                          prints: ["p": voiceprint(0, lean: 3), "q": voiceprint(1, lean: 3), "r": voiceprint(2), "z": voiceprint(4)])
    let found = SpeakerAssigner.voices(system: system, mic: mic, micShift: 0.5, model: "test")
    // Named by track and by how much they spoke; the cough is nobody.
    #expect(found.voices.map(\.id) == ["s1", "s2", "m1", "m2", "m3"])
    #expect(found.voices.map(\.speaking) == [80, 20, 59.9, 30, 19.9])
    // The microphone's clock starts half a second in.
    #expect(found.voices[2].firstAt == 0.6 && found.mic.first?.start == 0.6)
    // Two microphone voices are the speakers; the one left is the user.
    #expect(found.voices.map(\.echoOf) == [nil, nil, "s1", nil, "s2"])
    #expect(found.voices.map { $0.isMe == true } == [false, false, false, true, false])
    #expect(Set(found.prints.keys) == ["s1", "s2", "m1", "m2", "m3"])

    let lines = SpeakerAssigner.assign([
        TranscriptSegment(speaker: .others, start: 10, end: 20, text: "先说排期"),
        TranscriptSegment(speaker: .me, start: 10.5, end: 20.5, text: "先说排期"),
        TranscriptSegment(speaker: .others, start: 62, end: 70, text: "报价要调整"),
        TranscriptSegment(speaker: .me, start: 105, end: 112, text: "我来做报价单"),
        // Between turns, but right next to one.
        TranscriptSegment(speaker: .me, start: 130.8, end: 131.2, text: "好的"),
        // Nowhere near anyone.
        TranscriptSegment(speaker: .others, start: 300, end: 302, text: "喂"),
    ], voices: found)
    #expect(lines.map(\.voice) == ["s1", "m1", "s2", "m2", "m2", nil])
    // What the speakers said into the microphone is an echo, whatever the words.
    #expect(lines.map { $0.echo == true } == [false, true, false, false, false, false])
    #expect(SpeakerLabels.labels(lines, voices: found.voices) == ["说话人A", "我", "说话人B", "我", "我", "对方"])
    #expect(lines.spoken.count == 5)
}

@Test func aMatchingPrintIsNoEchoWhenTheAudioSaysTheUserSpoke() {
    // One person on the call. At the microphone: a voice that sounds like them, and nobody else.
    let system = TrackVoices(turns: [turn("x", 0, 50)], prints: ["x": voiceprint(0)])
    let mic = TrackVoices(turns: [turn("p", 0, 20), turn("p", 60, 100)], prints: ["p": voiceprint(0, lean: 3)])
    func heard(_ first: EchoMeter.Frame, _ second: EchoMeter.Frame, leak: Float = 0.1) -> EchoMeter.Profile {
        var frames = [EchoMeter.Frame](repeating: .silent, count: 10000)
        for i in 0 ..< 2000 { frames[i] = first }
        for i in 6000 ..< 10000 { frames[i] = second }
        return EchoMeter.Profile(hop: 0.01, frames: frames, leak: leak)
    }
    // Its turns are the speakers' echo throughout: an echo, as the print says.
    let echo = SpeakerAssigner.voices(system: system, mic: mic, echo: heard(.echo, .echo), model: "test")
    #expect(echo.voices.map(\.echoOf) == [nil, "s1"])
    // Two thirds of its turns are the user speaking with the other side quiet: whatever the print
    // says (their own voice coming back on the call), this is a person, the user, and their lines stay.
    let person = SpeakerAssigner.voices(system: system, mic: mic, echo: heard(.echo, .mine), model: "test")
    #expect(person.voices.map(\.echoOf) == [nil, nil] && person.voices[1].isMe == true)
    let lines = SpeakerAssigner.assign([TranscriptSegment(speaker: .me, start: 70, end: 75, text: "这个我来跟")], voices: person)
    #expect(lines[0].voice == "m1" && lines[0].echo == nil)
    // On headphones nothing at the microphone is an echo.
    let headphones = SpeakerAssigner.voices(system: system, mic: mic, echo: heard(.mine, .mine, leak: 0), model: "test")
    #expect(headphones.voices.map(\.echoOf) == [nil, nil])
    // A voice that is nothing but echo is one even when its print matches nobody.
    let odd = TrackVoices(turns: [turn("p", 0, 20), turn("p", 60, 100)], prints: ["p": voiceprint(5)])
    #expect(SpeakerAssigner.voices(system: system, mic: odd, echo: heard(.echo, .echo), model: "test").voices[1].echoOf == "s1")
    #expect(SpeakerAssigner.voices(system: system, mic: odd, echo: heard(.echo, .both), model: "test").voices[1].echoOf == nil)
}

@Test func aRoomHasSeveralPeopleAtOneMicrophone() {
    // Nothing on the computer; three people around the microphone.
    let mic = TrackVoices(turns: [turn("a", 0, 40), turn("b", 40, 70), turn("c", 70, 90), turn("a", 90, 100)],
                          prints: ["a": voiceprint(0), "b": voiceprint(1), "c": voiceprint(2)])
    let unknown = SpeakerAssigner.voices(system: TrackVoices(turns: [], prints: [:]), mic: mic, model: "test")
    #expect(unknown.voices.map(\.id) == ["m1", "m2", "m3"])
    // Nobody is the speakers' echo, and nothing says which one is the user.
    #expect(unknown.voices.allSatisfy { $0.isPerson && $0.isMe == nil })
    let lines = SpeakerAssigner.assign([
        TranscriptSegment(speaker: .me, start: 5, end: 12, text: "我们开始吧"),
        TranscriptSegment(speaker: .me, start: 45, end: 52, text: "我先说进度"),
        TranscriptSegment(speaker: .me, start: 200, end: 203, text: "嗯"),
    ], voices: unknown)
    #expect(SpeakerLabels.labels(lines, voices: unknown.voices) == ["说话人A", "说话人B", "说话人"])

    // With the user's voice on file, the one that matches is the user; the rest keep their letters.
    let known = SpeakerAssigner.voices(system: nil, mic: mic, me: [voiceprint(1, lean: 5)], model: "test")
    #expect(known.voices.map { $0.isMe == true } == [false, true, false])
    #expect(SpeakerLabels.labels(SpeakerAssigner.assign(lines, voices: known), voices: known.voices) == ["说话人A", "我", "我"])
    // A voice on file that fits two people about equally settles nothing.
    let torn = SpeakerAssigner.voices(system: nil, mic: mic, me: [[1, 1, 0, 0, 0, 0, 0, 0]], model: "test")
    #expect(torn.voices.allSatisfy { $0.isMe == nil })
    // A name takes the place of the letter, and the letters close up.
    var named = unknown.voices
    named[0].name = "张三"
    #expect(SpeakerLabels.labels(lines, voices: named) == ["张三", "说话人A", "说话人"])
    // Someone alone at the microphone is the user.
    let alone = SpeakerAssigner.voices(system: nil, mic: TrackVoices(turns: [turn("a", 0, 40)], prints: ["a": voiceprint(0)]), model: "test")
    #expect(alone.voices.map { $0.isMe == true } == [true])
}

@Test func aLineTwoPeopleShareIsCutWhereTheyChange() {
    let found = SpeakerAssigner.voices(system: TrackVoices(turns: [turn("x", 0, 14), turn("y", 14.4, 30), turn("x", 30, 60)],
                                                           prints: ["x": voiceprint(0), "y": voiceprint(1)]),
                                       mic: nil, model: "test")
    // s1 spoke most (44 s), s2 15.6 s.
    let cut = SpeakerAssigner.assign([TranscriptSegment(speaker: .others, start: 10, end: 20, text: "排期就按分两期走。那报价要不要调整？")],
                                     voices: found)
    #expect(cut.map(\.text) == ["排期就按分两期走。", "那报价要不要调整？"])
    #expect(cut.map(\.voice) == ["s1", "s2"])
    #expect(cut[0].end == 14.2 && cut[1].start == 14.2 && cut[0].start == 10 && cut[1].end == 20)
    // No pause in the words near the change: one line, to whoever said more of it.
    let whole = SpeakerAssigner.assign([TranscriptSegment(speaker: .others, start: 10, end: 20, text: "排期就按分两期走那报价要不要调整")],
                                       voices: found)
    #expect(whole.map(\.voice) == ["s2"] && whole[0].text == "排期就按分两期走那报价要不要调整")
    // A word or two of someone else isn't a second line.
    let brief = SpeakerAssigner.assign([TranscriptSegment(speaker: .others, start: 13.5, end: 25, text: "好。那报价要不要调整，范围变了"),],
                                       voices: found)
    #expect(brief.map(\.voice) == ["s2"])
    // Three turns in one line stay one line, with whoever held most of it (15.6 s against 4 + 10).
    let three = SpeakerAssigner.assign([TranscriptSegment(speaker: .others, start: 10, end: 40, text: "排期分两期。报价要调整。测试环境再看。")],
                                       voices: found)
    #expect(three.count == 1 && three[0].voice == "s2")
    // Assigning again changes nothing.
    #expect(SpeakerAssigner.assign(cut, voices: found) == cut)

    #expect(SpeakerAssigner.cutPoint("好的", at: 0.5) == nil)
    #expect(SpeakerAssigner.cutPoint("第一句，第二句", at: 0.9) == nil)
}

@Test func voiceBookKeepsTheUsersVoice() throws {
    var book = VoiceBook()
    #expect(book.me(model: "a").isEmpty)
    for i in 0 ..< 7 { book.learnMe(voiceprint(i), model: "a") }
    // The newest five.
    #expect(book.me(model: "a").count == 5 && book.me(model: "a").first == voiceprint(2))
    // Prints from other models don't compare: asked for another model there are none, and learning
    // with a new one starts over.
    #expect(book.me(model: "b").isEmpty)
    book.learnMe(voiceprint(0), model: "b")
    #expect(book.me(model: "b") == [voiceprint(0)] && book.me(model: "a").isEmpty && book.people.count == 1)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicebook-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try book.save(to: url)
    #expect(VoiceBook.load(url).me(model: "b") == [voiceprint(0)])
    // Readable by the user alone.
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(VoiceBook.load(url.appendingPathExtension("missing")).people.isEmpty)
}

@Test func meetingsKeepTheirVoices() throws {
    var m = Meeting(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    var line = TranscriptSegment(speaker: .others, start: 1, end: 2, text: "你好")
    line.voice = "s1"
    m.transcript = [line]
    var voice = MeetingVoice(id: "s1", track: .others, speaking: 30, firstAt: 1)
    voice.name = "张三"
    voice.nameSource = "llm"
    voice.certain = false
    m.voices = [voice]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode(Meeting.self, from: encoder.encode(m))
    #expect(back == m && back.transcript?.first?.voice == "s1" && back.voices?.first?.name == "张三")
}

@Test func theMinutesNamesGoOntoTheVoices() throws {
    var a = MeetingVoice(id: "s1", track: .others, speaking: 600, firstAt: 5)
    let b = MeetingVoice(id: "s2", track: .others, speaking: 200, firstAt: 60)
    var c = MeetingVoice(id: "m1", track: .me, speaking: 300, firstAt: 12)
    c.isMe = true
    var echo = MeetingVoice(id: "m2", track: .me, speaking: 500, firstAt: 5.2)
    echo.echoOf = "s1"
    // Letters go to people without a name, in the order heard; not to the user or the echo.
    #expect(SpeakerLabels.letters([a, b, c, echo]) == ["s1": "A", "s2": "B"])

    let lines = [TranscriptSegment(speaker: .others, start: 5, end: 9, text: "先说排期"), TranscriptSegment(speaker: .me, start: 12, end: 15, text: "好")]
    var voiced = lines
    voiced[0].voice = "s1"
    voiced[1].voice = "m1"
    #expect(MeetingSummarizer.format(voiced, voices: [a, b, c, echo]) == "[00:05] 说话人A：先说排期\n[00:12] 我：好")
    // Without voices it reads as it always did.
    #expect(MeetingSummarizer.format(lines) == "[00:05] 对方：先说排期\n[00:12] 我：好")
    let roster = try #require(SpeakerLabels.roster([a, b, c, echo]))
    #expect(roster == "- 说话人A：电脑里传出的声音，发言约 10 分钟，最早出现在 00:05\n- 我：麦克风收到的声音，发言约 5 分钟，最早出现在 00:12\n- 说话人B：电脑里传出的声音，发言约 3 分钟，最早出现在 01:00")
    #expect(SpeakerLabels.roster(nil) == nil && SpeakerLabels.roster([echo]) == nil)

    let out = try MeetingSummarizer.parse("""
    {"overview": "谈了排期", "me_voice": null, "speakers": [
      {"voice": "A", "name": "张三", "said": "主持", "certain": true, "basis": "李四两次叫他张三"},
      {"voice": "说话人B", "name": "Alice（推测）", "said": "讲了报价", "certain": true, "basis": null},
      {"voice": "Z", "name": "王五", "said": "", "certain": true, "basis": null},
      {"voice": null, "name": "对方", "said": "", "certain": false, "basis": null}]}
    """)
    let named = SpeakerLabels.apply(out.summary.speakers ?? [], meVoice: out.meVoice, to: [a, b, c, echo])
    #expect(named.ids == ["s1", "s2", nil, nil])
    #expect(named.voices.map(\.name) == ["张三", "Alice", nil, nil])
    // "（推测）" in the name is a guess whatever `certain` says.
    #expect(named.voices.map(\.certain) == [true, false, nil, nil])
    #expect(named.voices[0].nameSource == "llm")
    // With names, the transcript reads by name.
    #expect(SpeakerLabels.labels(voiced, voices: named.voices) == ["张三", "我"])
    #expect(out.summary.speakers?.first?.basis == "李四两次叫他张三")

    // A voice the user named has no letter any more: "A" is now the next person without a name, and
    // the user's name can't be written over. A label written back as the name is no name.
    a.name = "赵六"
    a.nameSource = "user"
    let kept = SpeakerLabels.apply(try MeetingSummarizer.parse("""
    {"overview": "x", "speakers": [{"voice": "A", "name": "说话人A", "said": "", "certain": false}]}
    """).summary.speakers ?? [], meVoice: nil, to: [a, b])
    #expect(kept.ids == ["s2"] && kept.voices.map(\.name) == ["赵六", nil])
    let next = SpeakerLabels.apply(try MeetingSummarizer.parse("""
    {"overview": "x", "speakers": [{"voice": "A", "name": "张三", "said": "", "certain": true}]}
    """).summary.speakers ?? [], meVoice: nil, to: [a, b])
    #expect(next.voices.map(\.name) == ["赵六", "张三"] && next.voices[0].nameSource == "user")

    // Several people at one microphone: the minutes say which is the user, as a guess.
    let x = MeetingVoice(id: "m1", track: .me, speaking: 600, firstAt: 1), y = MeetingVoice(id: "m2", track: .me, speaking: 300, firstAt: 9)
    #expect(SpeakerLabels.roster([x, y])?.hasSuffix("麦克风上有 2 个人的声音，其中一个是用户本人，还不知道是哪一个。") == true)
    let told = SpeakerLabels.apply([], meVoice: "b", to: [x, y])
    #expect(told.voices.map { $0.isMe == true } == [false, true] && told.voices[1].certain == false)
    #expect(SpeakerLabels.labels([voiced[1]], voices: told.voices) == ["说话人A"])
    // Not when the user is already known.
    var known = x
    known.isMe = true
    #expect(SpeakerLabels.apply([], meVoice: "A", to: [known, y]).voices.map { $0.isMe == true } == [true, false])

    // A voice the user merged into another reads as that one and takes no letter.
    var twin = b
    twin.sameAs = "s1"
    var second = lines[0]
    second.voice = "s2"
    #expect(SpeakerLabels.labels([second], voices: [named.voices[0], twin]) == ["张三"])
    #expect(SpeakerLabels.letters([MeetingVoice(id: "s1", track: .others, speaking: 1, firstAt: 0), twin]) == ["s1": "A"])
}

@Test func rememberedPeopleAreRecognizedByVoice() {
    var book = VoiceBook()
    book.learn(voiceprint(0), name: "张三", model: "a")
    book.learn(voiceprint(1), name: "Alice", model: "a")
    book.learnMe(voiceprint(2), model: "a")
    // The same name again adds to that person; the same print twice doesn't.
    book.learn(voiceprint(0, lean: 4), name: " 张三 ", model: "a")
    book.learn(voiceprint(0), name: "张三", model: "a")
    #expect(book.people.map(\.name) == ["张三", "Alice", "我"] && book.people[0].prints.count == 2)
    book.learn(voiceprint(3), name: "", model: "a")
    #expect(book.people.count == 3)

    // A close voice is them; one that only resembles them is a hint; a stranger is nobody. The
    // user isn't looked for here.
    let who = book.recognize(["s1": voiceprint(0, lean: 5), "s2": [1, 1.1, 0, 0, 0, 0, 0, 0], "s3": voiceprint(6), "m1": voiceprint(2)], model: "a")
    #expect(who["s1"]?.name == "张三" && who["s1"]?.sure == true)
    // Half-way between 张三 and Alice: resembles one of them (the nearer), not surely.
    #expect(who["s2"]?.name == "Alice" && who["s2"]?.sure == false)
    #expect(who["s3"] == nil && who["m1"] == nil)
    // One person is one voice: the nearer of two takes the name, the other isn't called it too.
    let two = book.recognize(["s1": voiceprint(0), "s2": voiceprint(0, lean: 5)], model: "a")
    #expect(two["s1"]?.name == "张三" && two["s2"] == nil)
    // …and with a twin that near, not surely.
    #expect(two["s1"]?.sure == false)
    // Prints from other models don't compare.
    #expect(book.recognize(["s1": voiceprint(0)], model: "b").isEmpty)

    // In a meeting: recognized people carry their names, a short voice is left alone.
    let system = TrackVoices(turns: [turn("x", 0, 60), turn("y", 60, 75), turn("z", 80, 140)],
                             prints: ["x": voiceprint(0, lean: 5), "y": voiceprint(1), "z": [1, 1.1, 0, 0, 0, 0, 0, 0]])
    let found = SpeakerAssigner.voices(system: system, mic: nil, remembered: book, model: "a")
    #expect(found.voices.map(\.id) == ["s1", "s2", "s3"])
    #expect(found.voices.map(\.name) == ["张三", nil, nil])
    #expect(found.voices[0].nameSource == "voiceprint" && found.voices[0].certain == true)
    // 60 s of someone half-way between two people: a hint for the minutes. 15 s of Alice: too short to say.
    #expect(found.voices.map(\.soundsLike) == [nil, "Alice", nil])
    #expect(SpeakerLabels.roster(found.voices)?.contains("声音有些像以前会议里的「Alice」") == true)
    #expect(SpeakerLabels.roster(found.voices)?.contains("- 张三：电脑里传出的声音，发言约 1 分钟，最早出现在 00:00（按声音认出来的）") == true)

    let id = book.people[1].id
    book.forget(id)
    #expect(book.people.map(\.name) == ["张三", "我"])
}
