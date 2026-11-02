import AistCore
import AVFoundation
import Foundation
import Speech

/// On-device transcription with Apple's SpeechAnalyzer (macOS 26+). Each track is transcribed on its
/// own, so segments know their speaker: mic.m4a → 我, system.m4a → 对方. Mandarin with English mixed in
/// is recognised by the zh_CN model; the summary step fixes mangled English terms from context.
enum MeetingTranscriber {
    enum TranscribeError: LocalizedError {
        case needsNewerMacOS
        case localeUnavailable

        var errorDescription: String? {
            switch self {
            case .needsNewerMacOS: "会议转写需要 macOS 26 或更新版本"
            case .localeUnavailable: "本机的中文语音识别模型不可用"
            }
        }
    }

    static let locale = Locale(identifier: "zh_CN")

    static func transcribe(_ recording: TodoRecording) async throws -> [TranscriptSegment] {
        guard #available(macOS 26, *) else { throw TranscribeError.needsNewerMacOS }
        let folder = TodoStore.folder(for: recording.id)
        let offset = recording.micOffset ?? 0
        var segments: [TranscriptSegment] = []
        if recording.hasMicrophone {
            segments += try await transcribe(folder.appendingPathComponent("mic.m4a"), speaker: .me, shift: max(0, offset))
        }
        if recording.hasSystemAudio {
            segments += try await transcribe(folder.appendingPathComponent("system.m4a"), speaker: .others, shift: max(0, -offset))
        }
        return segments.sorted { $0.start < $1.start }
    }

    @available(macOS 26, *)
    private static func transcribe(_ url: URL, speaker: TranscriptSegment.Speaker, shift: Double) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscribeError.localeUnavailable
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // Download the model on first use if it isn't installed yet.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collector = Task { () -> [TranscriptSegment] in
            var out: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(TranscriptSegment(speaker: speaker, start: result.range.start.seconds + shift,
                                             end: result.range.end.seconds + shift, text: text))
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
}
