import Accelerate
import AistCore
import AVFoundation
import Foundation

// After-the-meeting transcription of the recorded files on AstraFlow (设置 › AI › AstraFlow › 会后转写),
// used when the meeting wasn't transcribed live by Gemini. Each track is cut where people speak
// (silence isn't sent or billed), re-encoded as 16 kHz mono AAC and uploaded, a few pieces at a time.
//
// - gpt-4o-transcribe-diarize: POST {base}/audio/transcriptions, `diarized_json` → timed segments
//   with speaker labels. Pieces of up to 20 minutes.
// - gemini-3.5-transcribe: POST {host}/v1beta/models/gemini-3.5-transcribe:generateContent with
//   `inlineData` + `generationConfig.audioTranscriptionConfig`. AstraFlow returns text only (no
//   offsets, `wordTimestamp` is ignored), so pieces are a few sentences (≤ 20 s, cut at pauses) and
//   each becomes one line with the piece's times.
//   Send AAC: with WAV it stops at the first pause.

enum CloudFileTranscriber {
    enum Model: String, CaseIterable, Identifiable, Sendable {
        case diarize = "gpt-4o-transcribe-diarize"
        case gemini = "gemini-3.5-transcribe"

        var id: String { rawValue }

        /// Longest piece sent in one request, and the pause that may separate two utterances in it.
        fileprivate var maxPiece: Double { self == .diarize ? 1200 : 20 }
        fileprivate var joinGap: Double { self == .diarize ? 30 : 1.2 }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Both tracks of a recording on the meeting timeline, echoes of the other side removed.
    static func transcribe(_ recording: TodoRecording, model: Model, endpoint: CloudEndpoint,
                           language: String) async throws -> [TranscriptSegment] {
        let folder = TodoStore.folder(for: recording.id)
        let offset = recording.micOffset ?? 0
        var segments: [TranscriptSegment] = []
        if recording.hasMicrophone {
            segments += try await transcribe(file: folder.appendingPathComponent("mic.m4a"), speaker: .me,
                                             shift: max(0, offset), model: model, endpoint: endpoint, language: language)
        }
        if recording.hasSystemAudio {
            segments += try await transcribe(file: folder.appendingPathComponent("system.m4a"), speaker: .others,
                                             shift: max(0, -offset), model: model, endpoint: endpoint, language: language)
        }
        return HeardText.removingEchoes(segments.sorted { $0.start < $1.start })
    }

    static func transcribe(file: URL, speaker: TranscriptSegment.Speaker, shift: Double, model: Model,
                           endpoint: CloudEndpoint, language: String) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aist-cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let pieces = try await Task.detached(priority: .userInitiated) {
            try Audio.cut(file, model: model, into: temp)
        }.value
        guard !pieces.isEmpty else { return [] }

        // A few requests at a time, results in piece order.
        let limit = model == .diarize ? 3 : 8
        var results = [[TranscriptSegment]](repeating: [], count: pieces.count)
        try await withThrowingTaskGroup(of: (Int, [TranscriptSegment]).self) { group in
            var next = 0
            func add() {
                guard next < pieces.count else { return }
                let i = next, piece = pieces[i]
                next += 1
                group.addTask {
                    let found = try await request(piece, model: model, endpoint: endpoint, language: language)
                    return (i, found.map {
                        TranscriptSegment(speaker: speaker, start: $0.start + piece.start + shift,
                                          end: $0.end + piece.start + shift, text: $0.text)
                    })
                }
            }
            for _ in 0..<limit { add() }
            while let (i, found) = try await group.next() {
                results[i] = found
                add()
            }
        }
        return results.flatMap { $0 }
    }

    // MARK: Requests

    /// Text found in one piece, times from the piece's start.
    private struct Found { var start: Double; var end: Double; var text: String; var label: String? }

    private static func request(_ piece: Audio.Piece, model: Model, endpoint: CloudEndpoint,
                                language: String) async throws -> [Found] {
        let data = try Data(contentsOf: piece.url)
        var attempt = 0
        while true {
            do {
                switch model {
                case .diarize: return try await diarize(data, duration: piece.duration, endpoint: endpoint, language: language)
                case .gemini: return try await gemini(data, duration: piece.duration, endpoint: endpoint, language: language)
                }
            } catch is Retryable where attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt == 1 ? 1 : 4))
            } catch let error as Retryable {
                throw error.underlying
            }
        }
    }

    private struct Retryable: Error { let underlying: Error }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw Retryable(underlying: Failure(message: "连不上 AstraFlow：\(error.localizedDescription)"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            let err = json?["error"] as? [String: Any]
            var message = err?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            message = message.replacingOccurrences(of: #"^\[trace_id:[^\]]*\]\s*"#, with: "", options: .regularExpression)
            let failure = Failure(message: "AstraFlow 转写失败（\(status)）：\(message)")
            if status == 429 || status >= 500 { throw Retryable(underlying: failure) }
            throw failure
        }
        return json
    }

    private static func diarize(_ audio: Data, duration: Double, endpoint: CloudEndpoint, language: String) async throws -> [Found] {
        var request = URLRequest(url: endpoint.base.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        let boundary = "aist-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields = ["model": Model.diarize.rawValue, "response_format": "diarized_json", "chunking_strategy": "auto"]
        if language != "auto", let code = language.split(separator: "-").first { fields["language"] = String(code) }
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let json = try await send(request)
        let segments = json["segments"] as? [[String: Any]] ?? []
        var found = segments.compactMap { s -> Found? in
            let text = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard HeardText.hasWords(text) else { return nil }
            let start = (s["start"] as? NSNumber)?.doubleValue ?? 0
            let end = (s["end"] as? NSNumber)?.doubleValue ?? start
            return Found(start: start, end: max(start, end), text: text, label: s["speaker"] as? String)
        }
        if found.isEmpty, let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           HeardText.hasWords(text) {
            found = [Found(start: 0, end: duration, text: text, label: nil)]
        }
        return joined(found)
    }

    /// The diarizer returns phrases ("Hello everyone!", "大家好"); join the ones that carry on a
    /// sentence from the same voice into lines.
    private static func joined(_ found: [Found]) -> [Found] {
        var out: [Found] = []
        for f in found {
            if var last = out.last, last.label == f.label,
               HeardText.continues(last.text, f.text, gap: f.start - last.end, cut: true) {
                last.text = HeardText.join(last.text, f.text)
                last.end = f.end
                out[out.count - 1] = last
            } else {
                out.append(f)
            }
        }
        return out
    }

    private static func gemini(_ audio: Data, duration: Double, endpoint: CloudEndpoint, language: String) async throws -> [Found] {
        var c = URLComponents(url: endpoint.base, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.path = "/v1beta/models/\(Model.gemini.rawValue):generateContent"
        guard let url = c.url else { throw Failure(message: "AstraFlow 地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(endpoint.key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var config: [String: Any] = [:]
        if language != "auto" { config["languageCodes"] = [language] }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["inlineData": ["mimeType": "audio/mp4", "data": audio.base64EncodedString()]]]]],
            "generationConfig": ["audioTranscriptionConfig": config],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.map { p in
            ((p["audioTranscription"] as? [String: Any])?["text"] as? String) ?? (p["text"] as? String ?? "")
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard HeardText.hasWords(text) else { return [] }
        return [Found(start: 0, end: duration, text: text, label: nil)]
    }

    // MARK: Audio

    enum Audio {
        struct Piece: Sendable {
            var url: URL
            /// Seconds from the file's start.
            var start: Double
            var duration: Double
        }

        static let frame = 0.1

        /// Finds speech, groups it into pieces and writes each piece as 16 kHz mono AAC.
        static func cut(_ url: URL, model: Model, into folder: URL) throws -> [Piece] {
            let file = try AVAudioFile(forReading: url)
            let levels = try loudness(file)
            let spans = plan(levels, model: model)
            return try spans.enumerated().map { i, span in
                let out = folder.appendingPathComponent("\(i).m4a")
                try write(file, from: span.lowerBound, to: span.upperBound, to: out)
                return Piece(url: out, start: span.lowerBound, duration: span.upperBound - span.lowerBound)
            }
        }

        /// dBFS of every 100 ms.
        static func loudness(_ file: AVAudioFile) throws -> [Float] {
            let format = file.processingFormat
            let step = AVAudioFrameCount(format.sampleRate * frame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else { return [] }
            file.framePosition = 0
            var levels: [Float] = []
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: step)
                let n = Int(buffer.frameLength)
                guard n > 0, let data = buffer.floatChannelData else { break }
                var sum: Float = 0
                let channels = Int(format.channelCount)
                for ch in 0..<channels {
                    var squares: Float = 0
                    vDSP_svesq(data[ch], 1, &squares, vDSP_Length(n))
                    sum += squares
                }
                let rms = (sum / Float(n * channels)).squareRoot()
                levels.append(20 * log10(max(rms, 1e-7)))
            }
            return levels
        }

        /// Speech spans (seconds) grouped into pieces of at most `model.maxPiece`.
        static func plan(_ levels: [Float], model: Model) -> [ClosedRange<Double>] {
            guard !levels.isEmpty else { return [] }
            // Speech: 10 dB over the quietest tenth of the recording, and not near-silence.
            let floor = levels.sorted()[levels.count / 10]
            let threshold = max(floor + 10, -55)
            var spans: [ClosedRange<Int>] = []
            var start: Int?
            for (i, l) in levels.enumerated() {
                if l > threshold {
                    if start == nil { start = i }
                } else if let s = start {
                    spans.append(s...(i - 1))
                    start = nil
                }
            }
            if let s = start { spans.append(s...(levels.count - 1)) }
            // Join across short pauses; drop clicks.
            let gap = Int(model.joinGap / frame)
            var merged: [ClosedRange<Int>] = []
            for s in spans {
                if let last = merged.last, s.lowerBound - last.upperBound <= gap {
                    merged[merged.count - 1] = last.lowerBound...s.upperBound
                } else {
                    merged.append(s)
                }
            }
            merged.removeAll { $0.count < 3 }
            // Split what's too long at its quietest moment past two thirds of the limit.
            let limit = Int(model.maxPiece / frame)
            var pieces: [ClosedRange<Int>] = []
            for var s in merged {
                while s.count > limit {
                    let window = (s.lowerBound + limit * 2 / 3)...(s.lowerBound + limit - 1)
                    let cut = window.min { levels[$0] < levels[$1] } ?? window.upperBound
                    pieces.append(s.lowerBound...cut)
                    s = (cut + 1)...s.upperBound
                }
                pieces.append(s)
            }
            // A little room either side so first and last words aren't clipped.
            let total = Double(levels.count) * frame
            return pieces.map { p in
                max(0, Double(p.lowerBound) * frame - 0.3)...min(total, Double(p.upperBound + 1) * frame + 0.3)
            }
        }

        static func write(_ file: AVAudioFile, from start: Double, to end: Double, to url: URL) throws {
            let source = file.processingFormat
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: mono)
            else { throw Failure(message: "无法转换录音格式") }
            let out = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)

            let first = AVAudioFramePosition(start * source.sampleRate)
            var remaining = AVAudioFrameCount(max(0, min(Double(file.length - first), (end - start) * source.sampleRate)))
            file.framePosition = first
            let chunk: AVAudioFrameCount = 16384
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk),
                  let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(Double(chunk) * 16000 / source.sampleRate) + 64)
            else { return }
            var done = false
            while !done {
                output.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, outStatus in
                    guard remaining > 0 else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try file.read(into: input, frameCount: min(chunk, remaining))
                    } catch {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    if input.frameLength == 0 {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    remaining -= min(remaining, input.frameLength)
                    outStatus.pointee = .haveData
                    return input
                }
                if let error { throw error }
                if output.frameLength > 0 { try out.write(from: output) }
                done = status == .endOfStream || status == .error
            }
        }
    }

    // MARK: Self-test

    /// `-aistCloudFile <model>,<file>,...`: transcribes each file as one track, prints the lines to
    /// /tmp/aist-cloudfile.log and quits.
    @MainActor
    static func selfTest(_ spec: String) async {
        var log = ""
        var parts = spec.split(separator: ",").map(String.init)
        // "dry:<model>": only show how the files would be cut, send nothing.
        let dry = parts.first?.hasPrefix("dry:") == true
        if dry { parts[0] = String(parts[0].dropFirst(4)) }
        guard let first = parts.first, let model = Model(rawValue: first), let endpoint = CloudEndpoint.astraFlow() else {
            log = "usage: -aistCloudFile <\(Model.allCases.map(\.rawValue).joined(separator: "|"))>,file… (and an AstraFlow key)"
            try? log.write(toFile: "/tmp/aist-cloudfile.log", atomically: true, encoding: .utf8)
            exit(1)
        }
        log += "\(model.rawValue) via \(endpoint.base.absoluteString)\n"
        for path in parts.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let started = Date()
            do {
                if let file = try? AVAudioFile(forReading: url) {
                    let spans = Audio.plan(try Audio.loudness(file), model: model)
                    log += "\(url.lastPathComponent): \(spans.count) pieces, \(Int(spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound }))s of \(Int(Double(file.length) / file.processingFormat.sampleRate))s\n"
                    if dry {
                        let lengths = spans.map { $0.upperBound - $0.lowerBound }.sorted()
                        log += String(format: "  piece length min %.1f median %.1f max %.1f; cut+encode ", lengths.first ?? 0,
                                      lengths.isEmpty ? 0 : lengths[lengths.count / 2], lengths.last ?? 0)
                        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aist-dry-\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                        let pieces = try Audio.cut(url, model: model, into: temp)
                        let bytes = pieces.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.url.path)[.size] as? Int) ?? 0) }
                        log += String(format: "%.1fs, %d files, %.1f MB\n", Date().timeIntervalSince(started), pieces.count, Double(bytes) / 1e6)
                        try? FileManager.default.removeItem(at: temp)
                        continue
                    }
                }
                let lines = try await transcribe(file: url, speaker: .others, shift: 0, model: model,
                                                 endpoint: endpoint, language: MeetingSettings.language)
                for l in lines { log += String(format: "[%7.2f–%7.2f] ", l.start, l.end) + l.text + "\n" }
                log += String(format: "%d lines in %.1fs\n", lines.count, Date().timeIntervalSince(started))
            } catch {
                log += "ERROR: \(error.localizedDescription)\n"
            }
        }
        try? log.write(toFile: "/tmp/aist-cloudfile.log", atomically: true, encoding: .utf8)
        exit(0)
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
