import AVFoundation
import Speech

/// Hold-to-talk dictation: microphone → SFSpeechRecognizer (on-device when the language supports it),
/// with a live transcript and input levels for the waveform.
@MainActor
final class SpeechRecorder: ObservableObject {
    @Published private(set) var transcript = ""
    /// Recent input levels, 0…1, newest last.
    @Published private(set) var levels: [CGFloat] = Array(repeating: 0, count: SpeechRecorder.bars)
    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?

    static let bars = 28
    static let localeKey = "voice.locale"

    /// Languages offered in Settings; the first matching the phone's language is the default.
    static let languages: [(id: String, name: String)] = [
        ("zh-CN", "中文（普通话）"), ("en-US", "English"), ("ms-MY", "Bahasa Melayu"), ("zh-HK", "粵語"),
    ]

    static var defaultLocale: String {
        let lang = Locale.preferredLanguages.first ?? "zh-CN"
        if lang.hasPrefix("zh-Hant-HK") || lang.hasPrefix("yue") { return "zh-HK" }
        if lang.hasPrefix("zh") { return "zh-CN" }
        if lang.hasPrefix("ms") { return "ms-MY" }
        return "en-US"
    }

    enum RecorderError: LocalizedError {
        case denied
        case unavailable
        var errorDescription: String? {
            switch self {
            case .denied: "需要麦克风和语音识别权限：设置 › Aist"
            case .unavailable: "这个语言的语音识别现在用不了"
            }
        }
    }

    enum Permission { case granted, undetermined, denied }

    static var permission: Permission {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVAudioSession.sharedInstance().recordPermission
        if speech == .authorized, mic == .granted { return .granted }
        if speech == .denied || speech == .restricted || mic == .denied { return .denied }
        return .undetermined
    }

    /// Asks for whatever hasn't been asked yet. True when both are granted.
    static func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        return speech && mic
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var gotFinal = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Screenshot mode: looks like listening, no audio.
    func startDemo() {
        isRecording = true
        startedAt = Date(timeIntervalSinceNow: -7)
        transcript = "明天下午三点之前要把报价发给 Kevin，然后老板让我周五前把 Q4 slides 改一下"
        levels = (0 ..< Self.bars).map { i in CGFloat(0.25 + 0.6 * abs(sin(Double(i) * 0.7))) }
    }

    func start() throws {
        guard !isRecording else { return }
        let id = UserDefaults.standard.string(forKey: Self.localeKey) ?? Self.defaultLocale
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)), recognizer.isAvailable else {
            throw RecorderError.unavailable
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
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
        isRecording = true
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
    }

    /// Stops listening and waits briefly for the recognizer's final text.
    func stop() async -> String {
        guard isRecording else { return transcript }
        stopAudio()
        request?.endAudio()
        if !gotFinal {
            await withCheckedContinuation { c in
                waiter = c
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    self.resumeWaiter()
                }
            }
        }
        task = nil
        request = nil
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        guard isRecording else { return }
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        transcript = ""
    }

    private func stopAudio() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resumeWaiter() {
        waiter?.resume()
        waiter = nil
    }

    private func push(_ level: CGFloat) {
        guard isRecording else { return }
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
}
