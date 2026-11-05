import AistCore
import AppKit
import AVFoundation
import Speech

/// 语音记待办: the voice hotkey starts listening (microphone → SFSpeechRecognizer, on-device when the
/// language supports it); what was said goes to `NoteAssistant`, which can add, tick off, reschedule
/// or cancel to-dos, the same as typing a note on the phone.
///
/// Hold the hotkey to talk and let go to finish; or tap it to start and tap again to finish. Esc cancels.
@MainActor
final class VoiceNote: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    /// Recent input levels, 0…1, newest last.
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: VoiceNote.bars)
    @Published private(set) var startedAt: Date?

    static let bars = 24
    /// Held at least this long, letting go of the hotkey finishes; a shorter press is a tap (toggle).
    private static let holdThreshold: TimeInterval = 0.45
    /// Server-side recognition stops at about a minute; stop a little before.
    private static let maxDuration: TimeInterval = 55

    enum VoiceError: LocalizedError {
        case denied
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .denied: "需要麦克风和语音识别权限：系统设置 › 隐私与安全性"
            case let .unavailable(language): "\(language) 的语音识别现在用不了"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var gotFinal = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var pressedAt: Date?
    private var limitWork: DispatchWorkItem?
    /// The last few exchanges, for 「刚才那个改成周三」.
    private var turns: [NoteAssistant.Turn] = []

    private let store: TodoStore
    /// Shows a message in the panel: text, is error, seconds.
    var onMessage: ((String, Bool, Double) -> Void)?
    /// To-dos added or changed by a note, to highlight.
    var onResults: ((Set<UUID>) -> Void)?
    /// The panel should be open (listening started).
    var onBegin: (() -> Void)?

    init(store: TodoStore) {
        self.store = store
    }

    var isActive: Bool { phase != .idle }

    // MARK: Hotkey

    func hotkeyPressed() {
        switch phase {
        case .idle:
            pressedAt = .now
            Task { await begin() }
        case .listening:
            pressedAt = nil
            Task { await finish() }
        case .thinking:
            break
        }
    }

    func hotkeyReleased() {
        guard phase == .listening, let pressedAt, Date.now.timeIntervalSince(pressedAt) >= Self.holdThreshold else { return }
        self.pressedAt = nil
        Task { await finish() }
    }

    /// Esc, or the panel's 取消.
    func cancel() {
        guard phase == .listening else { return }
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        transcript = ""
        phase = .idle
    }

    // MARK: Listening

    private func begin() async {
        // No AI set up: say so before the user talks, not after.
        do { _ = try LLMConfig.load() } catch {
            onMessage?(error.localizedDescription, true, 6)
            return
        }
        guard await Self.requestPermission() else {
            Self.openPrivacySettings()
            onMessage?(VoiceError.denied.localizedDescription, true, 8)
            return
        }
        do {
            try start()
            NSSound(named: "Tink")?.play()
            onBegin?()
        } catch {
            stopAudio()
            onMessage?(error.localizedDescription, true, 6)
        }
    }

    private func start() throws {
        let id = Self.locale
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)), recognizer.isAvailable else {
            throw VoiceError.unavailable(Locale.current.localizedString(forIdentifier: id) ?? id)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Names the user goes by and words from their work spell right more often when hinted.
        request.contextualStrings = Array(UserIdentity.names.prefix(20))
        // On-device keeps speech private and has no one-minute limit.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.push(level) }
        }
        engine.prepare()
        try engine.start()

        transcript = ""
        gotFinal = false
        levels = Array(repeating: 0, count: Self.bars)
        startedAt = .now
        phase = .listening
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text, !text.isEmpty { self.transcript = text }
                if done { self.gotFinal = true; self.resumeWaiter() }
            }
        }
        if !recognizer.supportsOnDeviceRecognition {
            let limit = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .listening else { return }
                    Task { await self.finish() }
                }
            }
            limitWork = limit
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration, execute: limit)
        }
    }

    /// Stops listening, waits briefly for the final text, and hands it to the AI.
    private func finish() async {
        guard phase == .listening else { return }
        stopAudio()
        request?.endAudio()
        phase = .thinking
        if !gotFinal {
            await withCheckedContinuation { c in
                waiter = c
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.8))
                    self.resumeWaiter()
                }
            }
        }
        task = nil
        request = nil
        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else {
            phase = .idle
            onMessage?("没有听到说话", true, 4)
            return
        }
        await handle(said)
        phase = .idle
        transcript = ""
    }

    // MARK: AI

    private func handle(_ said: String) async {
        do {
            let assistant = NoteAssistant(client: LLMClient(config: try LLMConfig.load()), identity: UserIdentity.names,
                                          background: UserIdentity.background)
            let result = try await assistant.handle(said, todos: store.items, recent: turns)
            var report = store.apply(result, said: said)
            // No list to pick from here: ideas the user asked for are added, the same as when they say 「记一下」.
            if !report.suggestions.isEmpty {
                let picked = store.apply(report.suggestions, origin: .manual)
                report.added += picked.added
                report.merged += picked.updated
                report.suggestions = []
            }
            turns.append(NoteAssistant.Turn(said: said, did: store.describe(report)))
            turns = Array(turns.suffix(5))

            let touched = Set(report.added + report.merged + report.changed + report.reopened)
            if !touched.isEmpty { onResults?(touched) }
            let summary = Self.summary(report)
            let reply = report.reply.flatMap { $0.isEmpty ? nil : $0 }
            if let message = reply ?? summary {
                onMessage?(message, false, reply == nil ? 4 : 7)
            } else {
                onMessage?("「\(said.prefix(40))」里没有要记的事", false, 5)
            }
        } catch {
            onMessage?(error.localizedDescription, true, 6)
        }
    }

    /// 「新增 2 条 · 勾掉 1 条」, or nil when nothing changed.
    static func summary(_ r: NoteReport) -> String? {
        var parts: [String] = []
        if !r.added.isEmpty { parts.append("新增 \(r.added.count) 条") }
        if !r.merged.isEmpty { parts.append("并入已有 \(r.merged.count) 条") }
        if !r.completed.isEmpty { parts.append("勾掉 \(r.completed.count) 条") }
        if !r.reopened.isEmpty { parts.append("恢复 \(r.reopened.count) 条") }
        if !r.changed.isEmpty { parts.append("修改 \(r.changed.count) 条") }
        if !r.removed.isEmpty { parts.append("取消 \(r.removed.count) 条") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Audio

    private func stopAudio() {
        limitWork?.cancel()
        limitWork = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        startedAt = nil
    }

    private func resumeWaiter() {
        waiter?.resume()
        waiter = nil
    }

    private func push(_ level: CGFloat) {
        guard phase == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    /// RMS of the buffer mapped from -50…0 dB onto 0…1.
    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0 ..< n { sum += data[i] * data[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return CGFloat(min(max((db + 50) / 50, 0), 1))
    }

    // MARK: Language & permission

    /// The meeting language (设置 › 会议) when one is chosen, else from the system's preferred languages.
    static var locale: String {
        let chosen = MeetingSettings.language
        if chosen != "auto", !chosen.isEmpty { return chosen }
        let lang = Locale.preferredLanguages.first ?? "zh-CN"
        if lang.hasPrefix("zh-Hant-HK") || lang.hasPrefix("yue") { return "zh-HK" }
        if lang.hasPrefix("zh-Hant") { return "zh-TW" }
        if lang.hasPrefix("zh") { return "zh-CN" }
        if lang.hasPrefix("ms") { return "ms-MY" }
        return lang.hasPrefix("en") ? "en-US" : "zh-CN"
    }

    /// Asks for whatever hasn't been asked yet. True when both are granted.
    static func requestPermission() async -> Bool {
        let speech: Bool = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: true
        case .notDetermined: await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        default: false
        }
        guard speech else { return false }
        return switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    static func openPrivacySettings() {
        let pane = SFSpeechRecognizer.authorizationStatus() == .authorized ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
