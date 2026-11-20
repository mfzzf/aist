import AistCore
import Foundation

// Usage: aist-cli ask "<question>" [--search …] [--then "<follow-up>"]   (see Ask.swift)
//        aist-cli extract <image> [--app <front app name>] [--me "名字,别名"] [--background "<工作背景>"|@file]
//        aist-cli email <file.txt> [--me ...]
//        aist-cli meeting <transcript.txt> [--context <meeting-info.txt>] [--room]
//            lines "我：…" / "对方：…", or "说话人A：…" for voices told apart (--room: at the microphone,
//            the user among them, as in a meeting held in one room)
//        aist-cli audio echo <recording folder>|--all [--lines]   (see Audio.swift)
//        aist-cli audio voices <recording folder> [--max <n>]
//        aist-cli audio models [--fetch]   (times the sources of the speaker models; --fetch downloads them)
// Runs the same extraction the Mac app uses, without needing screen-recording permission.
// For trying other providers: AIST_BASE_URL, AIST_MODEL, AIST_FORMAT (anthropic|openai), AIST_API_KEY.

let args = CommandLine.arguments
guard args.count >= 3, ["extract", "email", "chat", "meeting", "note", "assist", "ask", "audio"].contains(args[1]) else {
    FileHandle.standardError.write(Data("usage: aist-cli extract <image> [--app <name>] | email|note <file>  [--me <names>]\n".utf8))
    exit(2)
}
var me: [String] = []
if let i = args.firstIndex(of: "--me"), i + 1 < args.count { me = args[i + 1].split(separator: ",").map(String.init) }
// The user's work background (Settings → 通用 → 工作背景), inline or @path to a text file.
var background = ""
if let i = args.firstIndex(of: "--background"), i + 1 < args.count {
    let v = args[i + 1]
    background = v.hasPrefix("@") ? (try? String(contentsOfFile: String(v.dropFirst()), encoding: .utf8)) ?? "" : v
}

var frontApp: String?
if let i = args.firstIndex(of: "--app"), i + 1 < args.count { frontApp = args[i + 1] }

do {
    if args[1] == "audio" {
        if args[2] == "models" {
            try await runModels(args)
        } else if args[2] == "voices" {
            try await runVoices(args)
        } else {
            try runAudio(args)
        }
        exit(0)
    }
    let env = ProcessInfo.processInfo.environment
    var config: LLMConfig
    if let base = env["AIST_BASE_URL"], let url = URL(string: base) {
        config = LLMConfig(provider: "env", baseURL: url, model: env["AIST_MODEL"] ?? "", apiKey: env["AIST_API_KEY"],
                           format: LLMFormat(rawValue: env["AIST_FORMAT"] ?? "anthropic"))
    } else {
        config = try LLMConfig.load()
    }
    if args[1] == "ask" {
        try await runAsk(args, config: config)
        exit(0)
    }
    if args[1] == "meeting" {
        let lines = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map(String.init)
        var t = 0.0
        let room = args.contains("--room")
        var voices: [MeetingVoice] = []
        var ids: [String: String] = [:]
        let segments = lines.compactMap { line -> TranscriptSegment? in
            guard let colon = line.firstIndex(of: "：") else { return nil }
            let who = String(line[..<colon])
            guard who == "我" || who == "对方" || who.hasPrefix("说话人") else { return nil }
            t += 8
            var seg = TranscriptSegment(speaker: who == "我" || (room && who != "对方") ? .me : .others, start: t, end: t + 7,
                                        text: String(line[line.index(after: colon)...]))
            if who.hasPrefix("说话人") {
                if ids[who] == nil {
                    ids[who] = "\(room ? "m" : "s")\(ids.count + 1)"
                    voices.append(MeetingVoice(id: ids[who]!, track: seg.speaker, speaking: 0, firstAt: t))
                }
                seg.voice = ids[who]
                if let i = voices.firstIndex(where: { $0.id == ids[who] }) { voices[i].speaking += 60 }
            }
            return seg
        }
        var context: String?
        if let i = args.firstIndex(of: "--context"), i + 1 < args.count {
            context = try String(contentsOfFile: args[i + 1], encoding: .utf8)
        }
        let out = try await MeetingSummarizer(client: LLMClient(config: config), identity: me, background: background)
            .summarize(transcript: segments, voices: voices.isEmpty ? nil : voices, startedAt: .now, existing: [], notes: nil, calendar: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(out.summary), as: UTF8.self))
        print("title:", out.title)
        if !voices.isEmpty {
            let named = SpeakerLabels.apply(out.summary.speakers ?? [], meVoice: out.meVoice, to: voices)
            let letters = SpeakerLabels.letters(voices)
            for (before, after) in zip(voices, named.voices) {
                print("voice \(SpeakerLabels.label(before, letters: letters)) → \(SpeakerLabels.label(after, letters: SpeakerLabels.letters(named.voices)))"
                    + (after.nameSource == "llm" ? (after.certain == true ? " (sure)" : " (guess)") : ""))
            }
            for s in out.summary.speakers ?? [] { print("speaker \(s.voice ?? "-") \(s.name): \(s.basis ?? "-")") }
            print("me_voice:", out.meVoice ?? "null")
        }
        print(String(decoding: try encoder.encode(out.myTodos), as: UTF8.self))
        exit(0)
    }
    let extractor = TodoExtractor(client: LLMClient(config: config), identity: me, background: background)
    let started = Date()
    var size = 0
    let todos: [ExtractedTodo]
    if args[1] == "chat" {
        let text = try String(contentsOfFile: args[2], encoding: .utf8)
        todos = try await extractor.extract(chatText: text, app: frontApp ?? "企业微信")
    } else if args[1] == "assist" {
        // The phone's input bar: intents against an optional todos.json (--todos).
        let text = try String(contentsOfFile: args[2], encoding: .utf8)
        var existing: [TodoItem] = []
        if let i = args.firstIndex(of: "--todos"), i + 1 < args.count {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            existing = try d.decode([TodoItem].self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
        }
        // --recent <file>: earlier exchanges as alternating lines "用户说：…" / "你做了：…".
        var recent: [NoteAssistant.Turn] = []
        if let i = args.firstIndex(of: "--recent"), i + 1 < args.count {
            var said: String?
            for line in try String(contentsOfFile: args[i + 1], encoding: .utf8).split(separator: "\n") {
                if line.hasPrefix("用户说：") {
                    said = String(line.dropFirst(4))
                } else if line.hasPrefix("你做了："), let s = said {
                    recent.append(NoteAssistant.Turn(said: s, did: String(line.dropFirst(4)), at: Date().addingTimeInterval(-120)))
                    said = nil
                }
            }
        }
        // --image <file> (repeatable): attached photos / screenshots.
        let images = try args.indices.filter { args[$0] == "--image" && $0 + 1 < args.count }
            .map { try ImageCodec.jpeg(fromImageData: Data(contentsOf: URL(fileURLWithPath: args[$0 + 1]))) }
        let result = try await NoteAssistant(client: LLMClient(config: config), identity: me, background: background)
            .handle(text, images: images, todos: existing, recent: recent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        FileHandle.standardError.write(Data(String(format: "%@ · %.1fs\n", config.model, Date().timeIntervalSince(started)).utf8))
        exit(0)
    } else if args[1] == "note" {
        let text = try String(contentsOfFile: args[2], encoding: .utf8)
        todos = try await extractor.extract(note: text, existing: [])
    } else if args[1] == "email" {
        let text = try String(contentsOfFile: args[2], encoding: .utf8)
        todos = try await extractor.extract(email: text, existing: [])
    } else {
        let jpeg = try ImageCodec.jpeg(ImageCodec.load(URL(fileURLWithPath: args[2])))
        size = jpeg.count
        todos = try await extractor.extract(imageJPEG: jpeg, context: CaptureContext(frontApp: frontApp), existing: [])
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(todos), as: UTF8.self))
    FileHandle.standardError.write(Data(String(format: "%@ · %d KB · %.1fs\n",
        config.model, size / 1024, Date().timeIntervalSince(started)).utf8))
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
