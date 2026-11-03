import AistCore
import AVFoundation
import CoreMedia
import Speech
import Translation

// The streaming approach (volatile results, cutting long lines at a pause, picking the spoken
// language by comparing on-device models) follows Cicada (知了, https://github.com/wquguru/cicada,
// Apache-2.0): ListenEngine.swift, AudioRouter.swift, LanguageDetector.swift.

/// What the meeting window shows while recording: finished lines, the line being spoken on each
/// side, and where transcription stands. Fed by `LiveEngine` (macOS 26+); on older systems it stays
/// empty and the recording is transcribed after the meeting as before.
@MainActor
final class LiveTranscript: ObservableObject {
    /// Finished lines on the meeting timeline (seconds from the start of the recording), in order.
    @Published fileprivate(set) var lines: [TranscriptSegment] = []
    /// The line in progress on each side.
    @Published fileprivate(set) var drafts: [TranscriptSegment.Speaker: String] = [:]
    /// The language each side is being recognised in (display name).
    @Published fileprivate(set) var languages: [TranscriptSegment.Speaker: String] = [:]
    /// A model download, a fallback, an error: one short grey line.
    @Published fileprivate(set) var status: String?
    /// Subtitle translation is waiting for the user to download a language pair.
    @Published fileprivate(set) var translationNeedsDownload: (source: Locale.Language, target: Locale.Language)?
    @Published fileprivate(set) var isRunning = false

    /// Words were recognised (for "nobody spoke for 10 minutes").
    var onHeard: (() -> Void)?

    fileprivate var engine: AnyObject?

    /// Lines without the microphone's echoes of the other side.
    var shownLines: [TranscriptSegment] { HeardText.removingEchoes(lines) }

    static var isSupported: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// Starts both sides. `language`: a BCP-47 locale ("zh-CN") or "auto"; `translateTo`: a target
    /// language for subtitles, or nil.
    func start(language: String, translateTo: Locale.Language?) {
        reset()
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else {
            status = "实时转写需要 macOS 26；结束后会在本机转写"
            return
        }
        let engine = LiveEngine(owner: self, language: language, translateTo: translateTo)
        self.engine = engine
        isRunning = true
        engine.start()
    }

    /// Audio from the recorder's queue. `lead`: seconds between the recording's start and this
    /// side's first sample.
    nonisolated func push(_ buffer: AVAudioPCMBuffer, speaker: TranscriptSegment.Speaker, lead: Double) {
        guard #available(macOS 26, *) else { return }
        LiveEngine.feed(buffer, speaker: speaker, lead: lead)
    }

    /// Ends recognition and returns the finished transcript, or nil if live transcription didn't
    /// work (the recording is then transcribed from the files).
    func finish() async -> [TranscriptSegment]? {
        guard #available(macOS 26, *), let engine = engine as? LiveEngine else { return nil }
        let ok = await engine.finish()
        isRunning = false
        drafts = [:]
        self.engine = nil
        guard ok else { return nil }
        return shownLines
    }

    func setTranslation(_ target: Locale.Language?) {
        guard #available(macOS 26, *), let engine = engine as? LiveEngine else { return }
        engine.setTranslation(target)
    }

    /// The user downloaded the language pair: translate what's there.
    func translationReady() {
        translationNeedsDownload = nil
        guard #available(macOS 26, *), let engine = engine as? LiveEngine else { return }
        engine.retranslate()
    }

    func reset() {
        lines = []
        drafts = [:]
        languages = [:]
        status = nil
        translationNeedsDownload = nil
        isRunning = false
    }

    // MARK: Languages

    /// Recognition languages offered in Settings: (BCP-47 id, name).
    static let languageChoices: [(id: String, name: String)] = [
        ("auto", "自动识别"), ("zh-CN", "中文（普通话）"), ("zh-TW", "中文（台湾）"), ("zh-HK", "粤语"),
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("ms-MY", "Bahasa Melayu"),
        ("ja-JP", "日本語"), ("ko-KR", "한국어"),
    ]

    static func name(of id: String) -> String {
        languageChoices.first { $0.id == id }?.name ?? Locale(identifier: "zh_CN").localizedString(forIdentifier: id) ?? id
    }

    /// Subtitle targets offered in Settings.
    static let translationChoices: [(id: String, name: String)] = [
        ("", "不翻译"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"), ("ms", "Bahasa Melayu"),
        ("ja", "日本語"), ("ko", "한국어"),
    ]
}

// MARK: - Engine

@available(macOS 26, *)
@MainActor
private final class LiveEngine {
    private weak var owner: LiveTranscript?
    private let language: String
    private var translateTo: Locale.Language?
    private var tracks: [TranscriptSegment.Speaker: Track] = [:]
    private var timer: Timer?
    private var failed = false
    private var candidates: [String] = []
    private var translating: Set<Int> = []
    private var nextID = 0
    /// Each finished line's id, parallel to `owner.lines`, so a translation finds its line after joins.
    private var lineIDs: [Int] = []


    init(owner: LiveTranscript, language: String, translateTo: Locale.Language?) {
        self.owner = owner
        self.language = language
        self.translateTo = translateTo
    }

    nonisolated static func feed(_ buffer: AVAudioPCMBuffer, speaker: TranscriptSegment.Speaker, lead: Double) {
        FeedRegistry.shared.get(speaker)?.push(buffer, lead: lead)
    }

    func start() {
        var feeds: [TranscriptSegment.Speaker: AudioFeed] = [:]
        for speaker in [TranscriptSegment.Speaker.me, .others] {
            let feed = AudioFeed()
            feeds[speaker] = feed
            tracks[speaker] = Track(speaker: speaker, feed: feed)
        }
        FeedRegistry.shared.set(feeds)
        Task {
            candidates = await Self.candidateLocales()
            for track in tracks.values {
                let initial = language == "auto"
                    ? (UserDefaults.standard.string(forKey: "live.lastLanguage.\(track.speaker.rawValue)").flatMap { candidates.contains($0) ? $0 : nil }
                        ?? candidates.first ?? "zh-CN")
                    : language
                await switchTrack(track, to: initial)
            }
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Installed models for the languages people here speak: the ones auto detection picks from.
    static func candidateLocales() async -> [String] {
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        var out: [String] = []
        for id in ["zh-CN", "en-US", "ms-MY", "en-GB", "zh-TW", "zh-HK", "ja-JP", "ko-KR"] where installed.contains(id) {
            // One model per language is enough to tell languages apart.
            let lang = String(id.prefix(2))
            if !out.contains(where: { $0.hasPrefix(lang) }) || id == "zh-HK" { out.append(id) }
        }
        return out
    }

    func finish() async -> Bool {
        timer?.invalidate()
        timer = nil
        FeedRegistry.shared.set([:])
        for track in tracks.values { await track.finish() }
        // Results already delivered land on the main actor in order; let the last ones in.
        await Task.yield()
        return !failed
    }

    // MARK: Transcriber per side

    private func switchTrack(_ track: Track, to locale: String, replay: Double = 0) async {
        track.generation += 1
        let gen = track.generation
        await track.stopAnalyzer()
        guard gen == track.generation, timer != nil else { return }
        track.locale = locale
        owner?.languages[track.speaker] = LiveTranscript.name(of: locale)
        owner?.drafts[track.speaker] = nil

        let transcriber = SpeechTranscriber(locale: Locale(identifier: locale), transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        do {
            let status = await AssetInventory.status(forModules: [transcriber])
            if status == .unsupported { throw LiveError.unsupported(LiveTranscript.name(of: locale)) }
            if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                owner?.status = "正在下载\(LiveTranscript.name(of: locale))语音模型…"
                try await request.downloadAndInstall()
                owner?.status = nil
                if language == "auto" { candidates = await Self.candidateLocales() }
            }
            guard gen == track.generation, timer != nil else { return }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            guard gen == track.generation, timer != nil else {
                await analyzer.cancelAndFinishNow()
                return
            }
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            track.feed.attach(format: format, continuation: continuation, replaySeconds: replay)
            track.analyzer = analyzer
            track.input = continuation
            track.results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(result, track: track, generation: gen)
                    }
                } catch {
                    self?.trackFailed(track, error: error, generation: gen)
                }
            }
            try await analyzer.start(inputSequence: stream)
            NSLog("aist: live transcription \(track.speaker.rawValue) in \(locale)")
        } catch {
            trackFailed(track, error: error, generation: gen)
        }
    }

    private func trackFailed(_ track: Track, error: Error, generation gen: Int) {
        guard gen == track.generation, timer != nil else { return }
        NSLog("aist: live transcription \(track.speaker.rawValue) failed: \(error)")
        track.failures += 1
        if track.failures >= 4 {
            failed = true
            owner?.status = "实时转写出错，结束后会改用录音重新转写"
            return
        }
        owner?.status = "实时转写出错，正在重试…"
        let locale = track.locale ?? "zh-CN"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == track.generation, self.timer != nil else { return }
                Task { await self.switchTrack(track, to: locale) }
            }
        }
    }

    private func handle(_ result: SpeechTranscriber.Result, track: Track, generation gen: Int) {
        guard gen == track.generation, let owner else { return }
        track.failures = 0
        if owner.status?.hasPrefix("实时转写出错") == true { owner.status = nil }
        let raw = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isFinal else {
            if (owner.drafts[track.speaker] ?? "").isEmpty {
                track.draftStartedAt = .now
                track.draftStartClock = track.feed.clock().fed
            }
            if raw != owner.drafts[track.speaker] { track.draftChangedAt = .now }
            owner.drafts[track.speaker] = raw.isEmpty ? nil : raw
            if HeardText.hasWords(raw) { owner.onHeard?() }
            return
        }
        owner.drafts[track.speaker] = nil
        let cut = track.cutAsked
        track.cutAsked = false
        let text = HeardText.clean(raw)
        guard HeardText.hasWords(text) else { return }
        owner.onHeard?()

        var weighted = 0.0, chars = 0
        for run in result.text.runs {
            guard let c = run.transcriptionConfidence else { continue }
            let n = result.text[run.range].characters.count
            weighted += c * Double(n)
            chars += n
        }
        let confidence = chars > 0 ? weighted / Double(chars) : 1
        if language == "auto", confidence < 0.6, text.count >= 4 { track.needsDetection = true }

        let base = track.feed.base(lead: true)
        let start = base + CMTimeGetSeconds(result.range.start)
        let end = base + CMTimeGetSeconds(result.range.end)
        // One sentence cut in two by a pause (ours or the speaker's) becomes one line again.
        if let i = owner.lines.lastIndex(where: { $0.speaker == track.speaker }),
           i == owner.lines.count - 1 || owner.lines[(i + 1)...].allSatisfy({ $0.start > owner.lines[i].end }),
           HeardText.continues(owner.lines[i].text, text, gap: start - owner.lines[i].end, cut: track.lastWasCut) {
            owner.lines[i].text = HeardText.join(owner.lines[i].text, text)
            owner.lines[i].end = max(owner.lines[i].end, end)
            owner.lines[i].translation = nil
            track.lastWasCut = cut
            translate(lineID: lineIDs[i])
            return
        }
        track.lastWasCut = cut
        let line = TranscriptSegment(speaker: track.speaker, start: start, end: end, text: text)
        let at = owner.lines.lastIndex { $0.start <= start }.map { $0 + 1 } ?? 0
        owner.lines.insert(line, at: at)
        let id = nextID
        nextID += 1
        lineIDs.insert(id, at: at)
        translate(lineID: id)
    }

    // MARK: Ticks: cut long lines, detect the language

    private func tick() {
        for track in tracks.values {
            maybeCut(track)
            track.ticks += 1
            if track.ticks % 4 == 0, language == "auto" { maybeDetect(track) }
        }
    }

    /// SpeechTranscriber ends a sentence only at a clear pause; in quick Chinese talk that can take
    /// 15–20 s and the line stays a draft that long. A long line is ended at the next small pause.
    private func maybeCut(_ track: Track) {
        guard !track.cutting, let analyzer = track.analyzer, let draft = owner?.drafts[track.speaker],
              !draft.isEmpty, draft != track.lastCut else { return }
        let cjk = draft.unicodeScalars.contains { $0.properties.isIdeographic }
        // Chinese has no spaces to cut between: wait for a longer line, and cut only at a pause
        // (cutting on "no new words" can split a word and lose it).
        guard cjk ? draft.count >= 36 : draft.split(separator: " ").count >= 10 else { return }
        let held = Date().timeIntervalSince(track.draftStartedAt)
        let needed = held >= 8 ? 0.15 : 0.3
        let c = track.feed.clock()
        let mid = c.pause.end - c.pause.length / 2
        let through: Double
        if c.silence >= needed {
            through = c.fed
        } else if c.pause.length >= needed, mid > track.draftStartClock + 1.5, mid > track.lastCutThrough, c.pause.end <= c.fed {
            through = mid
        } else if !cjk, Date().timeIntervalSince(track.draftChangedAt) >= (held >= 8 ? 0.6 : 1.2) {
            through = c.fed
        } else {
            return
        }
        track.cutting = true
        track.cutAsked = true
        track.lastCut = draft
        track.lastCutThrough = through
        Task {
            do { try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 1000)) } catch { track.cutAsked = false }
            track.cutting = false
        }
    }

    private func maybeDetect(_ track: Track) {
        guard !track.detecting, candidates.count >= 2, track.analyzer != nil else { return }
        let stats = track.feed.stats()
        if stats.voicedTotal >= track.nextPeriodic { track.needsDetection = true }
        // Each new turn after a pause may be in another language (a model hearing a language it
        // doesn't know mostly writes nothing, so low confidence alone won't notice).
        if track.feed.clock().silence >= AudioFeed.gapSeconds { track.needsDetection = true }
        guard track.needsDetection, Date().timeIntervalSince(track.lastDetection) >= 4 else { return }
        let seconds = min(6, stats.sinceGap)
        guard seconds >= 3, track.feed.stats(window: seconds).recentVoiced >= 2.5 else { return }
        track.needsDetection = false
        track.detecting = true
        track.lastDetection = .now
        // Early on check often; once settled, now and then.
        track.nextPeriodic = stats.voicedTotal + (track.confirmed ? 60 : 20)
        let clip = track.feed.snapshot(seconds: seconds)
        let candidates = self.candidates
        Task {
            let ranked = await LanguageDetector.rank(clip, candidates: candidates)
            track.detecting = false
            guard timer != nil else { return }
            apply(ranked, to: track)
        }
    }

    private func apply(_ ranked: [LanguageDetector.Candidate], to track: Track) {
        guard let best = ranked.first else { return }
        let runnerUp = ranked.dropFirst().first?.score ?? 0
        guard best.confidence >= 0.6, best.score - runnerUp >= 0.08 else { return }
        if best.locale == track.locale {
            track.confirmed = true
            track.pendingSwitch = nil
            UserDefaults.standard.set(best.locale, forKey: "live.lastLanguage.\(track.speaker.rawValue)")
            return
        }
        let current = ranked.first { $0.locale == track.locale }?.score ?? 0
        if !track.confirmed || best.score - current >= 0.3 || track.pendingSwitch == best.locale {
            track.confirmed = true
            track.pendingSwitch = nil
            UserDefaults.standard.set(best.locale, forKey: "live.lastLanguage.\(track.speaker.rawValue)")
            // The old model's results stop counting now (its last lines would be the new language
            // garbled); the words heard during detection are recognised again by the new model.
            track.generation += 1
            owner?.drafts[track.speaker] = nil
            let replay = 8.0
            let from = track.feed.base(lead: true) + track.feed.clock().fed - replay
            if let owner {
                for i in owner.lines.indices.reversed() where owner.lines[i].speaker == track.speaker && owner.lines[i].start >= from {
                    owner.lines.remove(at: i)
                    lineIDs.remove(at: i)
                }
            }
            Task { await switchTrack(track, to: best.locale, replay: replay) }
        } else {
            track.pendingSwitch = best.locale
            track.needsDetection = true
        }
    }

    // MARK: Translation

    func setTranslation(_ target: Locale.Language?) {
        translateTo = target
        retranslate()
    }

    func retranslate() {
        guard let owner else { return }
        for i in owner.lines.indices { owner.lines[i].translation = nil }
        for id in lineIDs { translate(lineID: id) }
    }

    private func translate(lineID: Int) {
        guard let target = translateTo, let owner, !translating.contains(lineID),
              let i = lineIDs.firstIndex(of: lineID) else { return }
        let line = owner.lines[i]
        guard let locale = tracks[line.speaker]?.locale else { return }
        let source = Locale(identifier: locale).language
        if source.languageCode == target.languageCode, source.script == target.script || target.script == nil { return }
        translating.insert(lineID)
        Task {
            defer { translating.remove(lineID) }
            let availability = LanguageAvailability()
            let status = await availability.status(from: source, to: target)
            guard status == .installed else {
                if status == .supported { owner.translationNeedsDownload = (source, target) }
                return
            }
            guard let out = try? await TranslationSession(installedSource: source, target: target).translate(line.text).targetText,
                  let j = lineIDs.firstIndex(of: lineID), owner.lines[j].text == line.text else { return }
            owner.lines[j].translation = out
        }
    }

    enum LiveError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self { case let .unsupported(name): "本机不支持\(name)语音识别" }
        }
    }
}

/// One side's recognizer and the state for cutting lines and detecting its language.
@available(macOS 26, *)
@MainActor
private final class Track {
    let speaker: TranscriptSegment.Speaker
    let feed: AudioFeed
    var locale: String?
    var analyzer: SpeechAnalyzer?
    var input: AsyncStream<AnalyzerInput>.Continuation?
    var results: Task<Void, Never>?
    var generation = 0
    var failures = 0

    var draftStartedAt = Date()
    var draftStartClock = 0.0
    var draftChangedAt = Date()
    var cutting = false
    var cutAsked = false
    var lastWasCut = false
    var lastCut = ""
    var lastCutThrough = 0.0

    var ticks = 0
    var detecting = false
    var needsDetection = true
    var confirmed = false
    var pendingSwitch: String?
    var lastDetection = Date.distantPast
    var nextPeriodic = 20.0

    init(speaker: TranscriptSegment.Speaker, feed: AudioFeed) {
        self.speaker = speaker
        self.feed = feed
    }

    func stopAnalyzer() async {
        feed.detach()
        input?.finish()
        input = nil
        results?.cancel()
        results = nil
        if let analyzer {
            self.analyzer = nil
            await analyzer.cancelAndFinishNow()
        }
    }

    /// Lets the recognizer finish what it heard, then stops.
    func finish() async {
        feed.detach()
        input?.finish()
        input = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            self.analyzer = nil
        }
        await results?.value
        results = nil
    }
}

// MARK: - Audio

/// The live feeds, reachable from the recorder's queue without hopping to the main actor.
@available(macOS 26, *)
private final class FeedRegistry: @unchecked Sendable {
    static let shared = FeedRegistry()
    private let lock = NSLock()
    private var feeds: [TranscriptSegment.Speaker: AudioFeed] = [:]

    func set(_ new: [TranscriptSegment.Speaker: AudioFeed]) { lock.withLock { feeds = new } }
    func get(_ speaker: TranscriptSegment.Speaker) -> AudioFeed? { lock.withLock { feeds[speaker] } }
}

/// Moves one side's audio off the capture queue, converts it for the analyzer and keeps the clock:
/// how much audio the analyzer has heard, pauses for cutting lines, and a short ring for language
/// detection and for replaying into a new model.
@available(macOS 26, *)
private final class AudioFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "aist.live.feed", qos: .userInitiated)
    private let converter = PCMConverter()
    private var format: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var ring: [(buffer: AVAudioPCMBuffer, seconds: Double, voiced: Bool)] = []
    private var ringSeconds = 0.0
    private let ringLimit = 10.0

    /// Seconds of this side's audio so far, and where the current analyzer's 0 sits in it.
    private var total = 0.0
    private var base = 0.0
    private var lead = 0.0
    /// Seconds given to the current analyzer (its clock).
    private var fed = 0.0
    private var voicedTotal = 0.0
    private var silenceRun = 0.0
    private var sinceGap = 0.0
    private var pause: (end: Double, length: Double) = (0, 0)
    private let voiceThreshold: Float = 0.01
    static let gapSeconds = 1.5

    func push(_ buffer: AVAudioPCMBuffer, lead: Double) {
        queue.async { [self] in
            self.lead = lead
            process(buffer)
        }
    }

    private func process(_ input: AVAudioPCMBuffer) {
        let target = format ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard input.frameLength > 0, let converted = converter.convert(input, to: target) else { return }
        let seconds = Double(converted.frameLength) / converted.format.sampleRate
        let voiced = Self.rms(converted) >= voiceThreshold
        if voiced {
            if silenceRun >= 0.12, continuation != nil { pause = (fed, silenceRun) }
            if silenceRun >= Self.gapSeconds { sinceGap = 0 }
            voicedTotal += seconds
            silenceRun = 0
        } else {
            silenceRun += seconds
        }
        sinceGap += seconds
        total += seconds
        if let continuation {
            continuation.yield(AnalyzerInput(buffer: converted))
            fed += seconds
        }
        ring.append((converted, seconds, voiced))
        ringSeconds += seconds
        while ringSeconds > ringLimit, !ring.isEmpty { ringSeconds -= ring.removeFirst().seconds }
    }

    private static func rms(_ b: AVAudioPCMBuffer) -> Float {
        let n = Int(b.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let d = b.int16ChannelData {
            for i in 0 ..< n { let v = Float(d[0][i]) / 32768; sum += v * v }
        } else if let d = b.floatChannelData {
            for i in 0 ..< n { sum += d[0][i] * d[0][i] }
        }
        return (sum / Float(n)).squareRoot()
    }

    func attach(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, replaySeconds: Double) {
        queue.sync {
            fed = 0
            pause = (0, 0)
            var replayed = 0.0
            if self.format != nil, self.format != format {
                ring.removeAll()
                ringSeconds = 0
            } else if replaySeconds > 0 {
                var replay: [AVAudioPCMBuffer] = []
                for item in ring.reversed() {
                    if replayed >= replaySeconds { break }
                    replayed += item.seconds
                    replay.append(item.buffer)
                }
                for buffer in replay.reversed() { continuation.yield(AnalyzerInput(buffer: buffer)) }
                fed = replayed
            }
            base = total - replayed
            self.format = format
            self.continuation = continuation
        }
    }

    func detach() {
        queue.sync { continuation = nil }
    }

    /// Where the current analyzer's 0 is on the meeting timeline (`lead` adds this side's offset).
    func base(lead withLead: Bool) -> Double { queue.sync { () -> Double in base + (withLead ? lead : 0) } }

    struct Clock {
        var fed: Double
        var silence: Double
        var pause: (end: Double, length: Double)
    }

    func clock() -> Clock {
        queue.sync { () -> Clock in Clock(fed: fed, silence: silenceRun, pause: pause) }
    }

    struct Stats {
        var voicedTotal: Double
        var sinceGap: Double
        var recentVoiced: Double
    }

    func stats(window: Double = 6) -> Stats {
        queue.sync { () -> Stats in
            var acc = 0.0, voiced = 0.0
            for item in ring.reversed() {
                if acc >= window { break }
                acc += item.seconds
                if item.voiced { voiced += item.seconds }
            }
            return Stats(voicedTotal: voicedTotal, sinceGap: sinceGap, recentVoiced: voiced)
        }
    }

    func snapshot(seconds: Double) -> [AVAudioPCMBuffer] {
        queue.sync { () -> [AVAudioPCMBuffer] in
            var acc = 0.0
            var out: [AVAudioPCMBuffer] = []
            for item in ring.reversed() {
                if acc >= seconds { break }
                acc += item.seconds
                out.append(item.buffer)
            }
            return out.reversed()
        }
    }
}

/// Stateful sample-rate / sample-format converter.
final class PCMConverter {
    private var converter: AVAudioConverter?

    func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converter == nil || converter!.inputFormat != input.format || converter!.outputFormat != format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }
}

// MARK: - Language detection

/// Picks the spoken language by transcribing the same short clip with each installed model and
/// comparing how confident each is: the right one is typically ≥ 0.85, wrong ones far below.
@available(macOS 26, *)
private enum LanguageDetector {
    struct Candidate {
        let locale: String
        let confidence: Double
        let score: Double
    }

    static func rank(_ clip: [AVAudioPCMBuffer], candidates: [String]) async -> [Candidate] {
        await withTaskGroup(of: Candidate?.self) { group in
            for locale in candidates { group.addTask { await evaluate(clip, locale: locale) } }
            var out: [Candidate] = []
            for await c in group { if let c { out.append(c) } }
            return out.sorted { $0.score > $1.score }
        }
    }

    private static func evaluate(_ clip: [AVAudioPCMBuffer], locale: String) async -> Candidate? {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: locale), transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.transcriptionConfidence])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        let converter = PCMConverter()
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        for buffer in clip {
            if let b = converter.convert(buffer, to: format) { continuation.yield(AnalyzerInput(buffer: b)) }
        }
        continuation.finish()
        let collector = Task { () -> (String, Double, Int) in
            var text = "", weighted = 0.0, chars = 0
            for try await result in transcriber.results {
                text += String(result.text.characters)
                for run in result.text.runs {
                    guard let c = run.transcriptionConfidence else { continue }
                    let n = result.text[run.range].characters.filter { !$0.isWhitespace && !$0.isPunctuation }.count
                    weighted += c * Double(n)
                    chars += n
                }
            }
            return (text, chars > 0 ? weighted / Double(chars) : 0, chars)
        }
        do {
            let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let (text, conf, chars) = try await collector.value
            return Candidate(locale: locale, confidence: conf, score: score(conf: conf, chars: chars, text: text, locale: locale))
        } catch {
            collector.cancel()
            return nil
        }
    }

    static func score(conf: Double, chars: Int, text: String, locale: String) -> Double {
        guard chars > 0 else { return 0 }
        // Very short output means the model mostly heard noise.
        let lengthFactor = min(1.0, Double(chars) / 6.0)
        // A CJK model that mostly writes Latin letters is transcribing a foreign language.
        var scriptFactor = 1.0
        if ["zh", "ja", "ko"].contains(String(locale.prefix(2))) {
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let latin = letters.filter(\.isASCII).count
            if !letters.isEmpty, Double(latin) / Double(letters.count) > 0.5 { scriptFactor = 0.75 }
        }
        return conf * lengthFactor * scriptFactor
    }
}
