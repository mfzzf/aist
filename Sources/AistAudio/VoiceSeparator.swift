import AistCore
import FluidAudio
import Foundation

/// Tells the voices on a recorded track apart, on this Mac. Apple has no API for it; this wraps
/// FluidAudio's offline pipeline (pyannote "community-1" segmentation and voiceprints, VBx
/// clustering), whose models (about 22 MB) are fetched on first use (see `SpeakerModels`). Nothing
/// else in the app knows FluidAudio.
public final class VoiceSeparator {
    /// What made the voiceprints. Prints from other models can't be compared with these.
    public static let model = "pyannote-community-1"

    private let manager: OfflineDiarizerManager

    /// `maxVoices`: an upper bound per track when one is known (the people invited, say).
    public init(maxVoices: Int? = nil) {
        var config = OfflineDiarizerConfig()
        config.clustering.maxSpeakers = maxVoices
        // One voice at a time: a transcript line belongs to one speaker.
        config.postProcessing.exclusiveSegments = true
        manager = OfflineDiarizerManager(config: config)
    }

    /// Loads the models, downloading them the first time: from whichever source answers fastest,
    /// each file checked against its hash. FluidAudio itself is kept off the network.
    public func prepare() async throws {
        try await SpeakerModels.fetch()
        ModelHub.offlineMode = true
        try await manager.prepareModels()
    }

    public func separate(_ url: URL) async throws -> TrackVoices {
        try await prepare()
        let result: DiarizationResult
        do {
            result = try await manager.process(url)
        } catch OfflineDiarizationError.noSpeechDetected {
            // A track nobody spoke on (the system track of a meeting held in one room).
            return TrackVoices(turns: [], prints: [:])
        }
        let turns = result.segments
            .map { VoiceTurn(voice: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
        return TrackVoices(turns: turns, prints: result.speakerDatabase ?? [:])
    }
}

/// Speaker separation for a whole recording: both tracks' voices told apart, the speakers' echo and
/// the user recognized among them, every transcript line given its voice.
public enum SpeakerPass {
    /// The two tracks as separated, kept next to the audio so that renaming, re-assigning and
    /// learning a voiceprint later don't run the models again.
    struct Separated: Codable {
        var model: String
        var system: TrackVoices?
        var mic: TrackVoices?
    }

    public struct Output: Sendable {
        public var voices: [MeetingVoice]
        public var transcript: [TranscriptSegment]
        /// Each voice's print, by `MeetingVoice.id`.
        public var prints: [String: [Float]]
        /// Each voice's turns on the meeting's clock.
        public var turns: [String: [VoiceTurn]]
    }

    static func cacheURL(_ folder: URL) -> URL { folder.appendingPathComponent("voices.json") }

    /// When getting the models last failed. Where they can't be downloaded (no network, the host
    /// blocked) every meeting would otherwise wait out the attempt before its minutes are written.
    private static let failures = Failures()

    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Date?
        var recent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return last.map { Date().timeIntervalSince($0) < 1800 } ?? false
        }

        func note() {
            lock.lock()
            last = Date()
            lock.unlock()
        }
    }

    /// The models, ready (downloaded the first time), or nil when that takes longer than `seconds`.
    private static func ready(_ separator: VoiceSeparator, within seconds: Double) async -> Bool {
        let loading = Task { () -> Bool in
            do {
                try await separator.prepare()
                return true
            } catch {
                NSLog("aist: speaker models not available: \(error)")
                return false
            }
        }
        let limit = Task {
            try? await Task.sleep(for: .seconds(seconds))
            loading.cancel()
        }
        // Whichever comes first; a load still running after the limit is left to finish on its own.
        let ok = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await loading.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        limit.cancel()
        return ok
    }

    /// How much of a microphone voice's audible turns is the user speaking, by the echo measurement.
    static func userShare(of id: String, in found: RecordingVoices, echo: EchoMeter.Profile) -> Double {
        var near = 0.0, voiced = 0.0
        for turn in found.mic where turn.voice == id {
            let share = echo.share(from: turn.start, to: turn.end)
            near += share.near * share.voiced
            voiced += share.voiced
        }
        return voiced > 0 ? near / voiced : 0
    }

    /// Keeps a voice the user said is theirs, for recognizing them in later meetings. From the copy
    /// of the separation next to the audio; false when there is none.
    @discardableResult
    public static func learnMe(voice id: String, folder: URL, micOffset: Double, bookURL: URL = VoiceBook.defaultURL) -> Bool {
        var book = VoiceBook.load(bookURL)
        guard let print = stored(folder: folder, micOffset: micOffset, book: book)?.prints[id] else { return false }
        book.learnMe(print, model: VoiceSeparator.model)
        return (try? book.save(to: bookURL)) != nil
    }

    /// Keeps a voice under the name the user confirmed for it, for recognizing that person in later
    /// meetings. Only ever from what the user said, never from a guess.
    @discardableResult
    public static func learn(voice id: String, name: String, folder: URL, micOffset: Double,
                             bookURL: URL = VoiceBook.defaultURL) -> Bool {
        var book = VoiceBook.load(bookURL)
        guard let print = stored(folder: folder, micOffset: micOffset, book: book)?.prints[id] else { return false }
        book.learn(print, name: name, model: VoiceSeparator.model)
        return (try? book.save(to: bookURL)) != nil
    }

    /// The recording's voices, from the copy next to the audio (nil when it was never separated, or
    /// by other models).
    public static func stored(folder: URL, micOffset: Double, echo: EchoMeter.Profile? = nil,
                              book: VoiceBook = VoiceBook.load()) -> RecordingVoices? {
        guard let data = try? Data(contentsOf: cacheURL(folder)),
              let separated = try? JSONDecoder().decode(Separated.self, from: data), separated.model == VoiceSeparator.model
        else { return nil }
        return voices(separated, micOffset: micOffset, echo: echo, book: book)
    }

    private static func voices(_ separated: Separated, micOffset: Double, echo: EchoMeter.Profile?, book: VoiceBook) -> RecordingVoices {
        SpeakerAssigner.voices(system: separated.system, mic: separated.mic, systemShift: max(0, -micOffset),
                               micShift: max(0, micOffset), me: book.me(model: VoiceSeparator.model), remembered: book,
                               echo: echo, model: VoiceSeparator.model)
    }

    /// Never throws: nil when the voices couldn't be told apart (no models and no network, unreadable
    /// audio, taking too long), and the transcript stays 我 / 对方.
    /// - Parameters:
    ///   - echo: the recording's echo measurement (see `RecordingEcho`), which says which microphone
    ///     voices are the speakers and not people.
    ///   - systemSilent: nothing was played on the computer; its track is skipped.
    ///   - known: the voices this meeting had before; names the user gave are kept.
    ///   - bookURL: where the user's own voiceprint is kept and learned.
    ///   - keep: read and write the copy next to the audio (off for a dry run).
    ///   - remember: use and add to the remembered voices; off, nobody is recognized by voice and
    ///     nothing is learned.
    public static func run(folder: URL, recording: TodoRecording, transcript: [TranscriptSegment],
                           echo: EchoMeter.Profile? = nil, systemSilent: Bool = false,
                           maxVoices: Int? = nil, known: [MeetingVoice]? = nil, bookURL: URL = VoiceBook.defaultURL,
                           keep: Bool = true, remember: Bool = true, timeout: Double = 900) async -> Output? {
        var book = remember ? VoiceBook.load(bookURL) : VoiceBook()
        let offset = recording.micOffset ?? 0
        var fresh = false
        var found = keep ? stored(folder: folder, micOffset: offset, echo: echo, book: book) : nil
        if found == nil {
            guard !failures.recent else { return nil }
            let separator = VoiceSeparator(maxVoices: maxVoices)
            // Two minutes for the models (22 MB the first time, a moment after that); without them the
            // minutes don't wait, and the next half hour's meetings don't try again.
            guard await ready(separator, within: 120) else {
                failures.note()
                return nil
            }
            let work = Task { () -> Separated? in
                var separated = Separated(model: VoiceSeparator.model)
                do {
                    if recording.hasSystemAudio, !systemSilent {
                        separated.system = try await separator.separate(folder.appendingPathComponent("system.m4a"))
                    }
                    if recording.hasMicrophone {
                        separated.mic = try await separator.separate(folder.appendingPathComponent("mic.m4a"))
                    }
                    return separated
                } catch {
                    NSLog("aist: telling voices apart failed: \(error)")
                    return nil
                }
            }
            let limit = Task {
                try? await Task.sleep(for: .seconds(timeout))
                work.cancel()
            }
            let separated = await work.value
            limit.cancel()
            guard let separated, !Task.isCancelled, separated.system != nil || separated.mic != nil else { return nil }
            if keep { try? JSONEncoder().encode(separated).write(to: cacheURL(folder), options: .atomic) }
            found = voices(separated, micOffset: offset, echo: echo, book: book)
            fresh = true
        }
        guard var found else { return nil }

        // On a call, the one person at the microphone is the user: that is how their voice gets known,
        // for the meetings where several people share the microphone.
        // Only from a voice that is the user and little else: one that shares its turns with the
        // speakers' echo carries their voices in its print too.
        if fresh, remember, found.voices.contains(where: { $0.track == .others }),
           let me = found.voices.first(where: { $0.isMe == true }), me.speaking >= 30,
           found.voices.filter({ $0.track == .me && $0.isPerson }).count == 1, let print = found.prints[me.id],
           let echo, !echo.hasEcho || userShare(of: me.id, in: found, echo: echo) >= 0.7 {
            book.learnMe(print, model: VoiceSeparator.model)
            try? book.save(to: bookURL)
        }

        // What the user said about a voice stands.
        for old in known ?? [] where old.nameSource == "user" {
            guard let i = found.voices.firstIndex(where: { $0.id == old.id }) else { continue }
            found.voices[i].name = old.name
            found.voices[i].nameSource = "user"
            found.voices[i].certain = true
            found.voices[i].sameAs = old.sameAs
            if old.isMe == true {
                for j in found.voices.indices { found.voices[j].isMe = j == i ? true : nil }
            } else if found.voices[i].isMe == true, !(old.name ?? "").isEmpty {
                found.voices[i].isMe = nil
            }
        }
        return Output(voices: found.voices, transcript: SpeakerAssigner.assign(transcript, voices: found), prints: found.prints,
                      turns: Dictionary(grouping: found.system + found.mic, by: \.voice))
    }
}
