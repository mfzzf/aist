import Foundation

/// One voice heard in a meeting. `id` says which track it was on and how much it spoke there:
/// "s1" spoke most on the system track, "m2" second most on the microphone.
public struct MeetingVoice: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var track: TranscriptSegment.Speaker
    /// Seconds spoken, and when first heard (seconds into the meeting).
    public var speaking: Double
    public var firstAt: Double
    public var name: String?
    /// Where the name came from: "user" (typed or confirmed), "voiceprint" (recognized from an
    /// earlier meeting) or "llm" (worked out from the conversation). A string, so that a kind added
    /// later doesn't stop older builds reading the file.
    public var nameSource: String?
    /// false: the name is a guess.
    public var certain: Bool?
    /// The user's own voice.
    public var isMe: Bool?
    /// A microphone voice that is a system-track voice heard through the speakers: that voice's id.
    public var echoOf: String?
    /// The user said this is the same person as another voice (one person's voice told apart as
    /// two): that voice's id. Its lines read as the other's.
    public var sameAs: String?
    /// Someone remembered from earlier meetings whose voice this one resembles, not closely enough to
    /// say it is them: a hint for whoever works out the names.
    public var soundsLike: String?

    public init(id: String, track: TranscriptSegment.Speaker, speaking: Double, firstAt: Double) {
        self.id = id
        self.track = track
        self.speaking = speaking
        self.firstAt = firstAt
    }

    /// A person in the room or on the call: not the speakers' echo of one, nor a second copy of one.
    public var isPerson: Bool { echoOf == nil && sameAs == nil }
}

/// What speaker separation found in a recording, kept next to the audio (`voices.json`) so names can
/// be changed, lines re-assigned and voiceprints learned without running the models again.
public struct RecordingVoices: Codable, Sendable {
    /// The models that made the voiceprints; prints from different models can't be compared.
    public var model: String
    public var voices: [MeetingVoice]
    /// Each track's turns on the meeting's clock, by `MeetingVoice.id`.
    public var system: [VoiceTurn]
    public var mic: [VoiceTurn]
    public var prints: [String: [Float]]

    public init(model: String, voices: [MeetingVoice], system: [VoiceTurn], mic: [VoiceTurn], prints: [String: [Float]]) {
        self.model = model
        self.voices = voices
        self.system = system
        self.mic = mic
        self.prints = prints
    }

    public func turns(_ track: TranscriptSegment.Speaker) -> [VoiceTurn] { track == .me ? mic : system }
}

/// From each track's separated voices to a meeting's voices and who said each transcript line.
public enum SpeakerAssigner {
    public struct Settings: Sendable {
        /// Seconds a voice must speak in all to count as someone: less is a cough, a fragment of
        /// another voice, noise.
        public var minSpeaking = 10.0
        /// A microphone voice this close to a system voice (see `VoiceMatch.distance`) is that voice
        /// through the speakers. The same person measures about 0.1–0.2 across the two tracks,
        /// different people 0.6 and up.
        public var echoDistance = 0.3
        /// …provided the audio agrees: at least this much of the voice's turns is echo, at most this
        /// much the user speaking. A print can match for other reasons (the user's own voice coming
        /// back on the call from a second device in the room), and calling that an echo would throw
        /// away what the user said.
        public var echoShare = 0.5
        public var echoNear = 0.3
        /// A voice whose turns are this purely echo is one even when its print matches nobody
        /// (bits of several people through the speakers, told apart as one voice).
        public var pureEchoShare = 0.7
        public var pureEchoNear = 0.15
        /// The user's saved voiceprint within this distance is the user…
        public var meDistance = 0.45
        /// …when no other voice comes this close to it.
        public var meMargin = 0.1
        /// Seconds a voice must speak to be recognized as someone remembered: a short one's print is
        /// too rough.
        public var minRecognized = 20.0
        /// A line with no turn under it takes one this near (seconds).
        public var nearby = 1.0
        /// A second voice must hold this long, and this much of a line, for the line to be split.
        public var splitSeconds = 1.5
        public var splitShare = 0.3

        public init() {}
    }

    /// The meeting's voices from the two tracks' separation. `systemShift` / `micShift`: seconds
    /// each track starts into the meeting. `me`: the user's saved voiceprints, if any. `echo`: the
    /// recording's echo measurement, when there is one: what the microphone held, moment by moment.
    /// `remembered`: the people whose voices the user confirmed in earlier meetings.
    public static func voices(system: TrackVoices?, mic: TrackVoices?, systemShift: Double = 0, micShift: Double = 0,
                              me: [[Float]] = [], remembered: VoiceBook? = nil, echo: EchoMeter.Profile? = nil, model: String,
                              settings: Settings = Settings()) -> RecordingVoices {
        var voices: [MeetingVoice] = []
        var prints: [String: [Float]] = [:]
        var turns: [TranscriptSegment.Speaker: [VoiceTurn]] = [:]
        for (track, prefix, found, shift) in [(TranscriptSegment.Speaker.others, "s", system, systemShift), (.me, "m", mic, micShift)] {
            guard let found else { continue }
            var names: [String: String] = [:]
            var number = 0
            for voice in found.voices where found.speaking(voice) >= settings.minSpeaking {
                number += 1
                let id = "\(prefix)\(number)"
                names[voice] = id
                let first = found.turns.first { $0.voice == voice }?.start ?? 0
                voices.append(MeetingVoice(id: id, track: track, speaking: found.speaking(voice), firstAt: first + shift))
                if let print = found.prints[voice] { prints[id] = print }
            }
            turns[track] = found.turns.compactMap { turn in
                names[turn.voice].map { VoiceTurn(voice: $0, start: turn.start + shift, end: turn.end + shift) }
            }
        }
        // A microphone voice that is one of the system voices is the speakers, not a person in the
        // room: by its print, and by what the audio says its turns held.
        for i in voices.indices where voices[i].track == .me {
            let nearest = prints[voices[i].id].flatMap { print in
                voices.filter { $0.track == .others }
                    .compactMap { other in prints[other.id].map { (other.id, VoiceMatch.distance(print, $0)) } }
                    .min { $0.1 < $1.1 }
            }
            let matches = (nearest?.1 ?? 2) <= settings.echoDistance
            guard let echo else {
                // Nothing measured: the print is all there is.
                if matches { voices[i].echoOf = nearest?.0 }
                continue
            }
            // The microphone doesn't hear the speakers at all: nobody at it is their echo.
            guard echo.hasEcho else { continue }
            var echoed = 0.0, near = 0.0, voiced = 0.0
            for turn in turns[.me] ?? [] where turn.voice == voices[i].id {
                let share = echo.share(from: turn.start, to: turn.end)
                echoed += share.echo * share.voiced
                near += share.near * share.voiced
                voiced += share.voiced
            }
            guard voiced > 0 else { continue }
            if matches, echoed / voiced >= settings.echoShare, near / voiced <= settings.echoNear {
                voices[i].echoOf = nearest?.0
            } else if echoed / voiced >= settings.pureEchoShare, near / voiced <= settings.pureEchoNear {
                voices[i].echoOf = nearest?.0 ?? "speakers"
            }
        }
        // Which of the people at the microphone is the user: the saved voice if one matches, or the
        // only person there.
        let people = voices.indices.filter { voices[$0].track == .me && voices[$0].isPerson }
        if !me.isEmpty {
            let ranked = people.compactMap { i -> (Int, Double)? in
                guard let print = prints[voices[i].id] else { return nil }
                return (i, me.map { VoiceMatch.distance(print, $0) }.min() ?? 2)
            }.sorted { $0.1 < $1.1 }
            if let best = ranked.first, best.1 <= settings.meDistance,
               ranked.count == 1 || ranked[1].1 - best.1 >= settings.meMargin {
                voices[best.0].isMe = true
            }
        }
        if !voices.contains(where: { $0.isMe == true }), people.count == 1 { voices[people[0]].isMe = true }
        // People remembered from earlier meetings, by voice.
        if let remembered {
            var candidates: [String: [Float]] = [:]
            for voice in voices where voice.isPerson && voice.isMe != true && voice.speaking >= settings.minRecognized {
                candidates[voice.id] = prints[voice.id]
            }
            for (id, match) in remembered.recognize(candidates, model: model) {
                guard let i = voices.firstIndex(where: { $0.id == id }) else { continue }
                if match.sure {
                    voices[i].name = match.name
                    voices[i].nameSource = "voiceprint"
                    voices[i].certain = true
                } else {
                    voices[i].soundsLike = match.name
                }
            }
        }
        return RecordingVoices(model: model, voices: voices, system: turns[.others] ?? [], mic: turns[.me] ?? [], prints: prints)
    }

    /// The transcript with each line given its voice. A line two people share is cut in two where one
    /// stops and the other starts; a microphone line spoken by the speakers' echo is marked as one.
    public static func assign(_ segments: [TranscriptSegment], voices found: RecordingVoices,
                              settings: Settings = Settings()) -> [TranscriptSegment] {
        let echoes = Set(found.voices.filter { $0.echoOf != nil }.map(\.id))
        var out: [TranscriptSegment] = []
        for line in segments {
            let turns = found.turns(line.speaker)
            // What each voice holds of the line, in the order they come.
            var spans: [(voice: String, start: Double, end: Double)] = []
            for turn in turns where turn.end > line.start && turn.start < line.end {
                let start = max(turn.start, line.start), end = min(turn.end, line.end)
                if let last = spans.last, last.voice == turn.voice {
                    spans[spans.count - 1].end = end
                } else {
                    spans.append((turn.voice, start, end))
                }
            }
            func labelled(_ line: TranscriptSegment, _ voice: String?) -> TranscriptSegment {
                var line = line
                line.voice = voice
                if let voice, echoes.contains(voice) { line.echo = true }
                return line
            }
            guard !spans.isEmpty else {
                // Nothing under the line itself: the turn nearest to it, if it is near.
                let middle = (line.start + line.end) / 2
                let near = turns.map { ($0.voice, max(0, max($0.start - middle, middle - $0.end))) }.min { $0.1 < $1.1 }
                out.append(labelled(line, near.flatMap { $0.1 <= settings.nearby + (line.end - line.start) / 2 ? $0.0 : nil }))
                continue
            }
            var time: [String: Double] = [:]
            for span in spans { time[span.voice, default: 0] += span.end - span.start }
            let main = time.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
            // Two people, one after the other, each with a real share of it: two lines.
            let length = line.end - line.start
            if spans.count == 2, line.translation == nil, length > 0,
               spans.allSatisfy({ $0.end - $0.start >= settings.splitSeconds && $0.end - $0.start >= settings.splitShare * length }),
               let cut = cutPoint(line.text, at: ((spans[0].end + spans[1].start) / 2 - line.start) / length) {
                let at = (spans[0].end + spans[1].start) / 2
                var first = line, second = line
                first.text = String(line.text[..<cut]).trimmingCharacters(in: .whitespaces)
                first.end = at
                second.text = String(line.text[cut...]).trimmingCharacters(in: .whitespaces)
                second.start = at
                out.append(labelled(first, spans[0].voice))
                out.append(labelled(second, spans[1].voice))
                continue
            }
            out.append(labelled(line, main))
        }
        return out
    }

    /// Where to cut `text` for a change of speaker `share` of the way through it: just after the
    /// punctuation nearest that point, if there is any within a quarter of the text; else nil.
    static func cutPoint(_ text: String, at share: Double) -> String.Index? {
        let chars = Array(text)
        guard chars.count >= 4 else { return nil }
        let target = Double(chars.count) * min(1, max(0, share))
        let marks: Set<Character> = ["，", "。", "？", "！", "；", "、", ",", ".", "?", "!", ";", " "]
        var best: (index: Int, off: Double)?
        // Not the last character: both halves keep some words.
        for i in 0 ..< chars.count - 1 where marks.contains(chars[i]) {
            let off = abs(Double(i + 1) - target)
            if off < (best?.off ?? .infinity) { best = (i + 1, off) }
        }
        guard let best, best.off <= Double(chars.count) / 4,
              chars[..<best.index].contains(where: \.isLetter), chars[best.index...].contains(where: \.isLetter) else { return nil }
        return text.index(text.startIndex, offsetBy: best.index)
    }
}

/// How a line's speaker reads: 我, a name, or 说话人A.
public enum SpeakerLabels {
    /// A letter for every person without a name (and who isn't the user), in the order first heard.
    public static func letters(_ voices: [MeetingVoice]) -> [String: String] {
        var out: [String: String] = [:]
        let unnamed = voices.filter { $0.isPerson && $0.isMe != true && ($0.name ?? "").isEmpty }
            .sorted { ($0.firstAt, $0.id) < ($1.firstAt, $1.id) }
        for (i, voice) in unnamed.enumerated() {
            // A…Z, then A2…
            let letter = String(UnicodeScalar(UInt8(65 + i % 26)))
            out[voice.id] = i < 26 ? letter : "\(letter)\(i / 26 + 1)"
        }
        return out
    }

    public static func label(_ voice: MeetingVoice, letters: [String: String]) -> String {
        if voice.isMe == true { return "我" }
        if let name = voice.name, !name.isEmpty { return name }
        return "说话人" + (letters[voice.id] ?? "")
    }

    /// The label of every line's voice, for showing a whole transcript. Lines without a known voice
    /// read as before: 我 on the microphone, 对方 from the computer.
    public static func labels(_ segments: [TranscriptSegment], voices: [MeetingVoice]?) -> [String] {
        let voices = voices ?? []
        let letters = letters(voices)
        var byID = Dictionary(voices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A voice the user merged into another reads as that one.
        for voice in voices {
            if let target = voice.sameAs, let other = byID[target], other.isPerson { byID[voice.id] = other }
        }
        // With several people at the microphone and no telling which is the user, an unplaced
        // microphone line isn't known to be the user's either.
        let unknownMe = voices.contains { $0.track == .me && $0.isPerson } && !voices.contains { $0.isMe == true }
        return segments.map { line in
            if let id = line.voice, let voice = byID[id], voice.isPerson { return label(voice, letters: letters) }
            if line.speaker == .me { return unknownMe ? "说话人" : "我" }
            return "对方"
        }
    }
}

public extension SpeakerLabels {
    /// What the minutes' model worked out about the voices, written onto them: a name for a lettered
    /// voice (`speakers[].voice` is the letter it was shown as), and which one is the user when that
    /// wasn't known. Names the user gave are left alone. Returns the voices and, for each speaker,
    /// the id of the voice it was about.
    static func apply(_ speakers: [MeetingSpeaker], meVoice: String?, to voices: [MeetingVoice]) -> (voices: [MeetingVoice], ids: [String?]) {
        var out = voices
        let letters = letters(voices)
        func id(_ letter: String?) -> String? {
            guard let letter = letter?.replacingOccurrences(of: "说话人", with: "").trimmingCharacters(in: .whitespaces).uppercased(),
                  !letter.isEmpty else { return nil }
            return letters.first { $0.value == letter }?.key
        }
        let ids = speakers.map { id($0.voice) }
        for (speaker, id) in zip(speakers, ids) {
            guard let id, let i = out.firstIndex(where: { $0.id == id }), out[i].nameSource != "user" else { continue }
            // "张三（推测）" is 张三, guessed; "对方" and "说话人A" are no name.
            var name = speaker.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var certain = speaker.certain
            for mark in ["（推测）", "(推测)"] where name.hasSuffix(mark) {
                name = String(name.dropLast(mark.count))
                certain = false
            }
            guard !name.isEmpty, name != "对方", name != "我", !name.hasPrefix("说话人"), !name.hasPrefix("对方") else { continue }
            out[i].name = name
            out[i].nameSource = "llm"
            out[i].certain = certain
        }
        if !out.contains(where: { $0.isMe == true }), let me = id(meVoice), let i = out.firstIndex(where: { $0.id == me }),
           out[i].track == .me, out[i].nameSource != "user" {
            out[i].isMe = true
            out[i].name = nil
            out[i].nameSource = "llm"
            out[i].certain = false
        }
        return (out, ids)
    }

    /// The voices as a list for the minutes' model: who each label is, where the voice came from and
    /// how much it spoke. nil when the recording's voices weren't told apart.
    static func roster(_ voices: [MeetingVoice]?) -> String? {
        guard let people = voices?.filter(\.isPerson).sorted(by: { ($0.firstAt, $0.id) < ($1.firstAt, $1.id) }), !people.isEmpty else { return nil }
        let letters = letters(voices ?? [])
        var lines = people.map { voice -> String in
            var line = "- " + label(voice, letters: letters) + "：" + (voice.track == .me ? "麦克风收到的声音" : "电脑里传出的声音")
            line += "，发言约 \(max(1, Int((voice.speaking / 60).rounded()))) 分钟，最早出现在 \(MeetingTime.stamp(voice.firstAt))"
            if voice.isMe != true, let name = voice.name, !name.isEmpty {
                line += voice.nameSource == "user" ? "（名字是用户确认的）" : voice.nameSource == "voiceprint" ? "（按声音认出来的）" : ""
            } else if voice.isMe != true, let like = voice.soundsLike {
                line += "；声音有些像以前会议里的「\(like)」，只作参考，要有对话里的依据才能确定"
            }
            return line
        }
        let atMic = people.filter { $0.track == .me }
        if atMic.count > 1, !atMic.contains(where: { $0.isMe == true }) {
            lines.append("麦克风上有 \(atMic.count) 个人的声音，其中一个是用户本人，还不知道是哪一个。")
        }
        return lines.joined(separator: "\n")
    }
}

/// The user's own voiceprints (and, later, those of people whose names the user confirmed), kept on
/// this Mac only: `voicebook.json`, readable by the user alone, never synced or exported.
public struct VoiceBook: Codable, Sendable {
    public struct Person: Codable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var isMe: Bool
        /// A few voiceprints from different meetings.
        public var prints: [[Float]]
        /// The models that made them.
        public var model: String
        public var updatedAt: Date
    }

    public var people: [Person] = []

    public init() {}

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aist/voicebook.json")
    }

    public static func load(_ url: URL = defaultURL) -> VoiceBook {
        guard let data = try? Data(contentsOf: url) else { return VoiceBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(VoiceBook.self, from: data)) ?? VoiceBook()
    }

    public func save(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The user's voiceprints made by `model`.
    public func me(model: String) -> [[Float]] {
        people.first { $0.isMe && $0.model == model }?.prints ?? []
    }

    /// Someone remembered whose voice a print is, or resembles.
    public struct Match: Sendable, Equatable {
        public var name: String
        /// 0 the same voice … 1 unrelated.
        public var distance: Double
        /// Close enough, and closer than to anyone else by enough, to say it is them.
        public var sure: Bool
    }

    /// Who the voices are, among the people remembered (not the user: see `me(model:)`). Each person
    /// is at most one voice and each voice at most one person. Within `sure` and clear of the next
    /// person by `margin` it is them; within `maybe` it only resembles them. (On real meetings the
    /// same person measured 0.12–0.35 from one meeting to another, different people 0.54 and up.)
    public func recognize(_ prints: [String: [Float]], model: String, sure: Double = 0.45, maybe: Double = 0.5,
                          margin: Double = 0.1) -> [String: Match] {
        let known = people.filter { !$0.isMe && $0.model == model && !$0.prints.isEmpty }
        // Every voice against every person, nearest pairs first.
        var pairs: [(voice: String, person: Int, distance: Double)] = []
        for (voice, print) in prints {
            for (p, person) in known.enumerated() {
                pairs.append((voice, p, person.prints.map { VoiceMatch.distance(print, $0) }.min() ?? 2))
            }
        }
        pairs.sort { ($0.distance, $0.voice) < ($1.distance, $1.voice) }
        var out: [String: Match] = [:]
        var taken: Set<Int> = []
        for pair in pairs where pair.distance <= maybe && out[pair.voice] == nil && !taken.contains(pair.person) {
            // The next nearest person to this voice, and the next nearest voice to this person.
            let rivals = pairs.filter { ($0.voice == pair.voice) != ($0.person == pair.person) }.map(\.distance).min() ?? 2
            out[pair.voice] = Match(name: known[pair.person].name, distance: pair.distance,
                                    sure: pair.distance <= sure && rivals - pair.distance >= margin)
            taken.insert(pair.person)
        }
        return out
    }

    /// Keeps a voiceprint under a name the user confirmed: the newest five per person, from one model.
    public mutating func learn(_ print: [Float], name: String, model: String, at date: Date = .now) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !print.isEmpty else { return }
        if let i = people.firstIndex(where: { !$0.isMe && $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            if people[i].model != model {
                people[i].prints = []
                people[i].model = model
            }
            // The same print again (the name confirmed twice in one meeting) adds nothing.
            if !people[i].prints.contains(print) { people[i].prints = Array((people[i].prints + [print]).suffix(5)) }
            people[i].updatedAt = date
        } else {
            people.append(Person(id: UUID(), name: name, isMe: false, prints: [print], model: model, updatedAt: date))
        }
    }

    public mutating func forget(_ id: UUID) { people.removeAll { $0.id == id } }

    /// Keeps a voiceprint known to be the user's: the newest five, from one model.
    public mutating func learnMe(_ print: [Float], model: String, at date: Date = .now) {
        if let i = people.firstIndex(where: { $0.isMe }) {
            if people[i].model != model {
                people[i].prints = []
                people[i].model = model
            }
            people[i].prints = Array((people[i].prints + [print]).suffix(5))
            people[i].updatedAt = date
        } else {
            people.append(Person(id: UUID(), name: "我", isMe: true, prints: [print], model: model, updatedAt: date))
        }
    }
}
