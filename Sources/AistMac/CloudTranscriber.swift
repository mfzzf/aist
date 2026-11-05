import AistCore
import AVFoundation
import Foundation

// Live meeting transcription by Gemini on AstraFlow (设置 › 会议 › 识别引擎), the alternative to
// Apple's on-device SpeechAnalyzer. Each side (me / others) gets its own WebSocket session to
// gemini-3.5-transcribe-live-preview; with subtitles on, a second one per side to
// gemini-3.5-live-translate-preview supplies the translations. Protocol:
// https://astraflow.ucloud.cn/reference/modelverse-api-protocol/audio/google/gemini-3-5-transcribe-live-preview

/// Where and with which key: the AstraFlow provider from 设置 › AI (its region picks the node).
struct CloudEndpoint: Sendable {
    var host: String
    var key: String

    static let transcribeModel = "gemini-3.5-transcribe-live-preview"
    static let translateModel = "gemini-3.5-live-translate-preview"

    /// nil when AstraFlow has no key yet.
    @MainActor
    static func astraFlow() -> CloudEndpoint? {
        guard let provider = LLMProviderStore.load().providers.first(where: { $0.id == "umodelverse" }) else { return nil }
        // $AIST_ASTRAFLOW_KEY: for test runs from a shell.
        let env = ProcessInfo.processInfo.environment["AIST_ASTRAFLOW_KEY"]
        guard let key = env ?? provider.apiKey, !key.isEmpty else { return nil }
        return CloudEndpoint(host: wsHost(forBaseURL: provider.baseURL), key: key)
    }

    /// The realtime nodes: Mainland China, Singapore, Los Angeles, Frankfurt. The chat regions
    /// inside China (乌兰察布, 上海二) all go to the Mainland node.
    static func wsHost(forBaseURL base: String) -> String {
        let host = URL(string: base)?.host ?? ""
        if host.hasSuffix("umodelverse.ai") { return host }
        return "api.modelverse.cn"
    }

    func url(model: String) -> URL? {
        var c = URLComponents()
        c.scheme = "wss"
        c.host = host
        c.path = "/v1beta/ws/LlmBidiService/BidiGenerateContent"
        c.queryItems = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "token", value: key)]
        return c.url
    }
}

// MARK: - Engine

@MainActor
final class CloudEngine {
    private weak var owner: LiveTranscript?
    private let endpoint: CloudEndpoint
    private let language: String
    private var translateTo: Locale.Language?
    private var sides: [TranscriptSegment.Speaker: Side] = [:]
    private var timer: Timer?
    private var running = false
    private var failed = false

    /// One side's feed, sessions and the line in progress.
    private final class Side {
        let speaker: TranscriptSegment.Speaker
        let feed: CloudFeed
        var transcribe: LiveSession?
        var translate: LiveSession?
        /// Meeting-timeline start of the utterance being spoken.
        var utteranceStart: Double?
        var failures = 0
        var lastWasCut = false
        /// Audio heard while the transcription session was being replaced (≤ 10 s), sent to the new one.
        var backlog: [CloudFeed.Chunk] = []
        /// The last ~15 s sent, to replay the sentence in progress into a replacement session.
        var recent: [CloudFeed.Chunk] = []
        /// Translated pieces not yet placed on a line: (meeting time, text).
        var pieces: [(time: Double, text: String)] = []
        init(speaker: TranscriptSegment.Speaker, feed: CloudFeed) {
            self.speaker = speaker
            self.feed = feed
        }
    }

    init(owner: LiveTranscript, endpoint: CloudEndpoint, language: String, translateTo: Locale.Language?) {
        self.owner = owner
        self.endpoint = endpoint
        self.language = language
        self.translateTo = translateTo
    }

    nonisolated static func feed(_ buffer: AVAudioPCMBuffer, speaker: TranscriptSegment.Speaker, lead: Double) {
        CloudFeeds.shared.get(speaker)?.push(buffer, lead: lead)
    }

    func start() {
        running = true
        var feeds: [TranscriptSegment.Speaker: CloudFeed] = [:]
        for speaker in [TranscriptSegment.Speaker.me, .others] {
            let feed = CloudFeed()
            let side = Side(speaker: speaker, feed: feed)
            feed.onChunk = { [weak self] chunk in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.send(chunk, side: side) } }
            }
            feeds[speaker] = feed
            sides[speaker] = side
            openTranscribe(side)
            if translateTo != nil { openTranslate(side) }
        }
        CloudFeeds.shared.set(feeds)
        owner?.languages = [.me: "云端识别", .others: "云端识别"]
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func finish() async -> Bool {
        CloudFeeds.shared.set([:])
        for side in sides.values {
            side.feed.flush()
            side.transcribe?.endAudio()
            side.translate?.endAudio()
        }
        // Let the last utterances come back (the model answers ~1–2 s after a pause).
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, !(owner?.drafts.isEmpty ?? true) || sides.values.contains(where: { $0.utteranceStart != nil }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        running = false
        timer?.invalidate()
        timer = nil
        for side in sides.values {
            commitDraft(side)
            placePieces(side, all: true)
            side.transcribe?.close()
            side.translate?.close()
        }
        sides = [:]
        return !failed
    }

    func setTranslation(_ target: Locale.Language?) {
        translateTo = target
        for side in sides.values {
            side.translate?.close()
            side.translate = nil
            side.pieces = []
            if target != nil { openTranslate(side) }
        }
    }

    // MARK: Sessions

    private func openTranscribe(_ side: Side) {
        var transcription: [String: Any] = [:]
        if language != "auto" { transcription["languageCodes"] = [language] }
        let setup: [String: Any] = ["inputAudioTranscription": transcription]
        guard let url = endpoint.url(model: CloudEndpoint.transcribeModel) else { return }
        let session = LiveSession(url: url, setup: setup)
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.handleTranscribe(event, session: session, side: side)
        }
        side.transcribe = session
        session.connect()
        // Queued in the session until it is ready.
        for chunk in side.backlog { session.send(chunk) }
        side.backlog = []
    }

    /// Test hook (-aistCloudDrop): cut every connection as if the network dropped.
    func simulateDrop() {
        for side in sides.values {
            side.transcribe?.simulateDrop()
            side.translate?.simulateDrop()
        }
    }

    private func openTranslate(_ side: Side) {
        guard let target = translateTo, let url = endpoint.url(model: CloudEndpoint.translateModel) else { return }
        let setup: [String: Any] = [
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "translationConfig": ["targetLanguageCode": Self.code(target), "echoTargetLanguage": false],
            ],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
        ]
        let session = LiveSession(url: url, setup: setup)
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.handleTranslate(event, session: session, side: side)
        }
        side.translate = session
        session.connect()
    }

    /// "zh-Hans" → "zh", "zh-Hant" → "zh-TW", others by language code.
    static func code(_ l: Locale.Language) -> String {
        let lang = l.languageCode?.identifier ?? "en"
        if lang == "zh", l.script?.identifier == "Hant" { return "zh-TW" }
        return lang
    }

    private func send(_ chunk: CloudFeed.Chunk, side: Side) {
        guard running else { return }
        side.recent.append(chunk)
        if side.recent.count > 150 { side.recent.removeFirst() }
        if let session = side.transcribe {
            session.send(chunk)
        } else {
            side.backlog.append(chunk)
            if side.backlog.count > 100 { side.backlog.removeFirst() }
        }
        side.translate?.send(chunk)
    }

    private func handleTranscribe(_ event: LiveSession.Event, session: LiveSession, side: Side) {
        guard let owner else { return }
        let lead = side.feed.lead
        switch event {
        case .ready:
            side.failures = 0
            if owner.status?.hasPrefix("云端转写") == true { owner.status = nil }
        case let .activityStart(offset):
            if side.utteranceStart == nil { side.utteranceStart = lead + session.clock(at: offset) }
        case let .interim(text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if side.utteranceStart == nil { side.utteranceStart = lead + session.clock(at: max(0, session.sentSeconds - 1)) }
            owner.drafts[side.speaker] = t.isEmpty ? nil : t
            if HeardText.hasWords(t) { owner.onHeard?() }
        case let .final(text):
            owner.drafts[side.speaker] = nil
            let end = lead + session.clock(at: session.sentSeconds)
            let start = side.utteranceStart ?? max(0, end - 2)
            side.utteranceStart = nil
            commit(text, start: start, end: end, side: side)
        case let .activityEnd(offset):
            // The final usually comes just before this; tighten the line's end to the pause.
            let end = lead + session.clock(at: offset)
            if let i = owner.lines.lastIndex(where: { $0.speaker == side.speaker }),
               owner.lines[i].end > end, end > owner.lines[i].start {
                owner.lines[i].end = end
            }
        case .translated:
            break
        case let .error(message):
            NSLog("aist: cloud transcription \(side.speaker.rawValue): \(message)")
            owner.status = "云端转写：\(message)"
        case let .closed(reason, beforeReady):
            guard side.transcribe === session else { return }
            side.transcribe = nil
            guard running else {
                commitDraft(side)
                return
            }
            // The sentence in progress is heard again by the next session (its draft stays on
            // screen until then); if no session comes back, finish() keeps the draft.
            if let start = side.utteranceStart {
                let from = start - side.feed.lead - 0.3
                let queued = Set(side.backlog.map(\.clock))
                let replay = side.recent.filter { $0.clock >= from && !queued.contains($0.clock) }
                side.backlog = (replay + side.backlog).sorted { $0.clock < $1.clock }
                side.utteranceStart = nil
            }
            if beforeReady {
                side.failures += 1
                if side.failures >= 5 {
                    failed = true
                    owner.status = "云端转写连不上（\(reason ?? "未知原因")），结束后会改用录音在本机转写"
                    return
                }
                owner.status = "云端转写连接中断，正在重连…"
            }
            // Sessions end by design every few minutes (goAway); a new one picks up at once.
            let delay = beforeReady ? min(8, pow(2, Double(side.failures))) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running, side.transcribe == nil else { return }
                    self.openTranscribe(side)
                }
            }
        }
    }

    private func handleTranslate(_ event: LiveSession.Event, session: LiveSession, side: Side) {
        switch event {
        case let .translated(text):
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            // The interpreter runs ~1.5 s behind the audio it translates.
            let time = side.feed.lead + session.clock(at: max(0, session.sentSeconds - 1.5))
            side.pieces.append((time, text))
        case let .closed(_, beforeReady):
            guard side.translate === session else { return }
            side.translate = nil
            guard running, translateTo != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (beforeReady ? 5 : 0)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running, side.translate == nil, self.translateTo != nil else { return }
                    self.openTranslate(side)
                }
            }
        default:
            break
        }
    }

    // MARK: Lines

    private func commit(_ raw: String, start: Double, end: Double, side: Side) {
        guard let owner else { return }
        let text = HeardText.clean(raw)
        guard HeardText.hasWords(text) else { return }
        owner.onHeard?()
        if let i = owner.lines.lastIndex(where: { $0.speaker == side.speaker }),
           i == owner.lines.count - 1 || owner.lines[(i + 1)...].allSatisfy({ $0.start > owner.lines[i].end }),
           HeardText.continues(owner.lines[i].text, text, gap: start - owner.lines[i].end, cut: side.lastWasCut) {
            owner.lines[i].text = HeardText.join(owner.lines[i].text, text)
            owner.lines[i].end = max(owner.lines[i].end, end)
            return
        }
        side.lastWasCut = false
        let line = TranscriptSegment(speaker: side.speaker, start: start, end: max(end, start + 0.5), text: text)
        let at = owner.lines.lastIndex { $0.start <= start }.map { $0 + 1 } ?? 0
        owner.lines.insert(line, at: at)
    }

    /// A session that closed mid-utterance: keep what was heard.
    private func commitDraft(_ side: Side) {
        guard let owner, let draft = owner.drafts[side.speaker], !draft.isEmpty else {
            side.utteranceStart = nil
            return
        }
        owner.drafts[side.speaker] = nil
        let end = side.feed.lead + side.feed.clock
        commit(draft, start: side.utteranceStart ?? max(0, end - 2), end: end, side: side)
        side.utteranceStart = nil
    }

    private func tick() {
        for side in sides.values { placePieces(side, all: false) }
    }

    /// Puts translated pieces on the line they were spoken in. A piece waits while its line is
    /// still being spoken (it belongs to the draft).
    private func placePieces(_ side: Side, all: Bool) {
        guard let owner, !side.pieces.isEmpty else { return }
        let mine = owner.lines.indices.filter { owner.lines[$0].speaker == side.speaker }
        guard let last = mine.last else { return }
        let settledUntil = all ? Double.infinity : (side.utteranceStart ?? owner.lines[last].end + 1.5)
        var keep: [(time: Double, text: String)] = []
        for piece in side.pieces {
            guard piece.time <= settledUntil else { keep.append(piece); continue }
            let i = mine.last { owner.lines[$0].start <= piece.time + 0.5 } ?? mine.first!
            owner.lines[i].translation = HeardText.join(owner.lines[i].translation ?? "", piece.text.trimmingCharacters(in: .whitespaces))
        }
        side.pieces = keep
    }
}

// MARK: - One WebSocket session

/// A BidiGenerateContent session: setup, then base64 PCM in, transcription events out.
/// Keeps the mapping from the server's audio offsets (seconds of audio it received) back to
/// the side's own clock, since silence between utterances isn't sent.
@MainActor
final class LiveSession {
    enum Event {
        case ready
        case activityStart(Double)
        case activityEnd(Double)
        case interim(String)
        case final(String)
        case translated(String)
        case error(String)
        /// `beforeReady`: it never got as far as setupComplete (bad key, network).
        case closed(String?, beforeReady: Bool)
    }

    var onEvent: ((Event) -> Void)?
    private let url: URL
    private let setup: [String: Any]
    private var task: URLSessionWebSocketTask?
    private var ready = false
    private var closed = false
    private var pending: [CloudFeed.Chunk] = []
    private var pinger: Timer?
    /// Seconds of audio sent, and where each continuous run of it starts on the side's clock.
    private(set) var sentSeconds = 0.0
    private var anchors: [(sent: Double, clock: Double)] = []
    private var lastClockEnd = -1.0

    init(url: URL, setup: [String: Any]) {
        self.url = url
        self.setup = setup
    }

    func connect() {
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
        self.task = task
        task.resume()
        write(["setup": setup])
        receive()
        let pinger = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.task?.sendPing { _ in } }
        }
        RunLoop.main.add(pinger, forMode: .common)
        self.pinger = pinger
    }

    func send(_ chunk: CloudFeed.Chunk) {
        guard !closed else { return }
        guard ready else {
            pending.append(chunk)
            // Hold at most ~10 s while connecting.
            if pending.count > 100 { pending.removeFirst() }
            return
        }
        if abs(chunk.clock - lastClockEnd) > 0.02 { anchors.append((sentSeconds, chunk.clock)) }
        lastClockEnd = chunk.clock + chunk.seconds
        sentSeconds += chunk.seconds
        write(["realtimeInput": ["mediaChunks": [["mimeType": "audio/pcm;rate=16000", "data": chunk.data.base64EncodedString()]]]])
    }

    /// Tells the server the audio is over, so it finishes the utterance in progress.
    func endAudio() {
        guard ready, !closed else { return }
        write(["realtimeInput": ["audioStreamEnd": true]])
    }

    func close() {
        guard !closed else { return }
        closed = true
        pinger?.invalidate()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    func simulateDrop() { finish(reason: "simulated drop") }

    /// The side's clock for a server audio offset.
    func clock(at offset: Double) -> Double {
        guard let a = anchors.last(where: { $0.sent <= offset + 0.001 }) ?? anchors.first else { return lastClockEnd < 0 ? 0 : lastClockEnd }
        return a.clock + (offset - a.sent)
    }

    private func write(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { NSLog("aist: live session send failed: \(error.localizedDescription)") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    switch result {
                    case let .success(message):
                        switch message {
                        case let .string(s): self.handle(Data(s.utf8))
                        case let .data(d): self.handle(d)
                        @unknown default: break
                        }
                        self.receive()
                    case let .failure(error):
                        self.finish(reason: self.closeReason() ?? error.localizedDescription)
                    }
                }
            }
        }
    }

    private func closeReason() -> String? {
        guard let task, let data = task.closeReason, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func finish(reason: String?) {
        guard !closed else { return }
        let wasReady = ready
        close()
        onEvent?(.closed(reason, beforeReady: !wasReady))
    }

    private func handle(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if json["setupComplete"] != nil {
            ready = true
            onEvent?(.ready)
            let queued = pending
            pending = []
            for chunk in queued { send(chunk) }
            return
        }
        if let error = json["error"] as? [String: Any] {
            onEvent?(.error(error["message"] as? String ?? "未知错误"))
            return
        }
        if json["goAway"] != nil {
            // The server is about to end this session; a fresh one takes over.
            finish(reason: nil)
            return
        }
        if let activity = json["voiceActivity"] as? [String: Any] {
            let offset = Self.seconds(activity["audioOffset"])
            switch activity["type"] as? String {
            case "ACTIVITY_START": onEvent?(.activityStart(offset))
            case "ACTIVITY_END": onEvent?(.activityEnd(offset))
            default: break
            }
        }
        guard let content = json["serverContent"] as? [String: Any] else { return }
        if let t = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String {
            onEvent?(.interim(t))
        }
        if let t = (content["inputTranscription"] as? [String: Any])?["text"] as? String {
            onEvent?(.final(t))
        }
        if let t = (content["outputTranscription"] as? [String: Any])?["text"] as? String {
            onEvent?(.translated(t))
        }
    }

    /// "8.280s" → 8.28
    static func seconds(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        guard let s = value as? String else { return 0 }
        return Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) ?? 0
    }
}

// MARK: - Audio

/// The live cloud feeds, reachable from the recorder's queue.
private final class CloudFeeds: @unchecked Sendable {
    static let shared = CloudFeeds()
    private let lock = NSLock()
    private var feeds: [TranscriptSegment.Speaker: CloudFeed] = [:]

    func set(_ new: [TranscriptSegment.Speaker: CloudFeed]) { lock.withLock { feeds = new } }
    func get(_ speaker: TranscriptSegment.Speaker) -> CloudFeed? { lock.withLock { feeds[speaker] } }
}

/// One side's audio as 100 ms chunks of 16 kHz mono PCM16. Only speech (plus a short lead-in and
/// tail) is passed on: the service bills every second it hears, and a meeting is mostly one side
/// listening.
final class CloudFeed: @unchecked Sendable {
    struct Chunk {
        var data: Data
        /// Where it starts on this side's clock (seconds of its audio so far).
        var clock: Double
        var seconds: Double
    }

    /// Called on the feed's queue.
    var onChunk: ((Chunk) -> Void)?
    private let queue = DispatchQueue(label: "aist.cloud.feed", qos: .userInitiated)
    private let converter = PCMConverter()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var buffer = Data()
    private var bufferClock = 0.0
    private var total = 0.0
    private var _lead = 0.0
    private var sending = false
    private var silence = 0.0
    private var preroll: [Chunk] = []
    private static let chunkBytes = 3200
    private static let threshold: Float = 0.01
    /// Silence still sent after speech, so the server sees the pause and ends the utterance.
    private static let tail = 2.0

    var lead: Double { queue.sync { _lead } }
    var clock: Double { queue.sync { total } }

    func push(_ input: AVAudioPCMBuffer, lead: Double) {
        queue.async { [self] in
            _lead = lead
            guard input.frameLength > 0, let pcm = converter.convert(input, to: format),
                  let samples = pcm.int16ChannelData else { return }
            let n = Int(pcm.frameLength)
            if buffer.isEmpty { bufferClock = total }
            buffer.append(Data(bytes: samples[0], count: n * 2))
            total += Double(n) / 16_000
            while buffer.count >= Self.chunkBytes {
                let data = buffer.prefix(Self.chunkBytes)
                buffer.removeFirst(Self.chunkBytes)
                let chunk = Chunk(data: Data(data), clock: bufferClock, seconds: 0.1)
                bufferClock += 0.1
                gate(chunk)
            }
        }
    }

    /// Sends what's buffered (end of the meeting).
    func flush() {
        queue.sync {
            guard sending, !buffer.isEmpty else { return }
            onChunk?(Chunk(data: buffer, clock: bufferClock, seconds: Double(buffer.count) / 32_000))
            buffer.removeAll()
        }
    }

    private func gate(_ chunk: Chunk) {
        let voiced = Self.rms(chunk.data) >= Self.threshold
        if voiced {
            if !sending {
                sending = true
                for c in preroll { onChunk?(c) }
                preroll = []
            }
            silence = 0
            onChunk?(chunk)
        } else if sending {
            onChunk?(chunk)
            silence += chunk.seconds
            if silence >= Self.tail { sending = false }
        } else {
            preroll.append(chunk)
            if preroll.count > 3 { preroll.removeFirst() }
        }
    }

    private static func rms(_ data: Data) -> Float {
        data.withUnsafeBytes { raw -> Float in
            let s = raw.bindMemory(to: Int16.self)
            guard !s.isEmpty else { return 0 }
            var sum: Float = 0
            for v in s { let f = Float(v) / 32768; sum += f * f }
            return (sum / Float(s.count)).squareRoot()
        }
    }
}

// MARK: - Self test

/// `-aistCloudTest`: feeds WAV files through the cloud engine in real time and logs what comes back.
@MainActor
enum CloudSelfTest {
    static func run(_ paths: [String]) async {
        let log = "/tmp/aist-cloud.log"
        FileManager.default.createFile(atPath: log, contents: nil)
        let handle = FileHandle(forWritingAtPath: log)
        func write(_ s: String) {
            handle?.write(Data((s + "\n").utf8))
            NSLog("aist cloud test: \(s)")
        }
        let live = LiveTranscript()
        let saved = UserDefaults.standard.string(forKey: MeetingSettings.engineKey)
        UserDefaults.standard.set(MeetingSettings.Engine.astraFlow.rawValue, forKey: MeetingSettings.engineKey)
        defer { UserDefaults.standard.set(saved, forKey: MeetingSettings.engineKey) }
        let target = UserDefaults.standard.string(forKey: "aistCloudTranslate").map { Locale.Language(identifier: $0) }
        live.start(language: "auto", translateTo: target)
        write("status: \(live.status ?? "-") running: \(live.isRunning)")
        if let after = UserDefaults.standard.object(forKey: "aistCloudDrop") as? String, let secs = Double(after) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(secs))
                write("dropping connections at \(secs)s; drafts: \(live.drafts)")
                live.simulateDrop()
            }
        }
        let speakers: [TranscriptSegment.Speaker] = [.others, .me]
        await withTaskGroup(of: Void.self) { group in
            for (i, path) in paths.enumerated() {
                let speaker = speakers[i % 2]
                group.addTask {
                    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
                    let frames: AVAudioFrameCount = 4800
                    // A second of silence before and two after, like a pause in a meeting.
                    let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate / 10))!
                    silence.frameLength = silence.frameCapacity
                    for _ in 0 ..< 10 { live.push(silence, speaker: speaker, lead: 0); try? await Task.sleep(for: .milliseconds(100)) }
                    while true {
                        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                              (try? file.read(into: buf, frameCount: frames)) != nil, buf.frameLength > 0 else { break }
                        live.push(buf, speaker: speaker, lead: 0)
                        try? await Task.sleep(for: .milliseconds(Int(Double(buf.frameLength) / file.processingFormat.sampleRate * 1000)))
                    }
                    for _ in 0 ..< 30 { live.push(silence, speaker: speaker, lead: 0); try? await Task.sleep(for: .milliseconds(100)) }
                }
            }
        }
        write("drafts: \(live.drafts)")
        let lines = await live.finish()
        write("status: \(live.status ?? "-")")
        for l in lines ?? [] {
            write(String(format: "[%@ %.1f–%.1f] %@ | %@", l.speaker.rawValue, l.start, l.end, l.text, l.translation ?? ""))
        }
        write(lines == nil ? "FAILED" : "DONE \(lines!.count) lines")
        UserDefaults.standard.set(saved, forKey: MeetingSettings.engineKey)
        exit(0)
    }
}
