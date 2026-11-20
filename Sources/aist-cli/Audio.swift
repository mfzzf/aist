import AistAudio
import AistCore
import Foundation

/// aist-cli audio echo <recording folder> [--lines] [--windows] [--meetings <meetings.json>]
/// aist-cli audio echo --all [--meetings <meetings.json>]
/// For tuning: --min-lag <s> --max-lag <s> (the delays tried, in seconds), --windows (every delay estimate).
///
/// Measures, from a recording's two tracks, how much of the microphone is the other side coming out
/// of the speakers, and what that says about the transcript's "我" lines next to the text filter in
/// use today. Prints numbers only, never what was said. `--all`: one line per recorded meeting.
func runAudio(_ args: [String]) throws {
    func opt(_ name: String) -> String? {
        args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    guard args.count >= 4, args[2] == "echo" else {
        FileHandle.standardError.write(Data("usage: aist-cli audio echo <recording folder>|--all [--lines] [--meetings <meetings.json>]\n".utf8))
        exit(2)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let meetingsURL = opt("--meetings").map { URL(fileURLWithPath: $0) } ?? MeetingStore.defaultURL
    let meetings = ((try? Data(contentsOf: meetingsURL)).flatMap { try? decoder.decode([Meeting].self, from: $0) } ?? [])
        .sorted { $0.startedAt < $1.startedAt }

    var settings = EchoMeter.Settings()
    if let v = opt("--min-lag").flatMap(Double.init) { settings.minLag = v }
    if let v = opt("--max-lag").flatMap(Double.init) { settings.maxLag = v }

    if args[3] == "--all" {
        for meeting in meetings {
            guard let recording = meeting.recording, recording.hasMicrophone, recording.hasSystemAudio else { continue }
            let head = "\(recording.id.uuidString.prefix(8))  \(stamp(meeting.startedAt))  \(clock(meeting.duration))"
            do {
                let report = try EchoReport(folder: TodoStore.folder(for: recording.id), recording: recording,
                                            transcript: meeting.transcript, settings: settings)
                print(head + "  " + report.oneLine)
            } catch {
                print(head + "  (\(error.localizedDescription))")
            }
        }
        return
    }

    let folder = URL(fileURLWithPath: args[3])
    let meeting = UUID(uuidString: folder.lastPathComponent).flatMap { id in meetings.first { $0.recording?.id == id } }
    let report = try EchoReport(folder: folder, recording: meeting?.recording, transcript: meeting?.transcript, settings: settings)
    if let meeting { print("recording \(folder.lastPathComponent)  \(stamp(meeting.startedAt))  \(clock(meeting.duration))") }
    print(report.full)
    if args.contains("--windows") { print(report.windows) }
    if args.contains("--lines") { print(report.lines) }
}

private func stamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

private func clock(_ seconds: Double) -> String { MeetingTime.stamp(seconds) }

private func dB(_ ratio: Float) -> String { ratio > 0 ? String(format: "%.1f", 10 * log10(ratio)) : "-inf" }

private func percent(_ share: Double) -> String { String(format: "%.0f%%", share * 100) }

/// One recording measured, and its "我" lines judged both ways.
struct EchoReport {
    let system: BandFrames
    let mic: BandFrames
    let offset: Double
    let profile: EchoMeter.Profile
    /// The transcript's microphone lines with what the audio and the text filter make of each.
    let mine: [(line: TranscriptSegment, share: EchoMeter.Share, verdict: EchoFilter.Verdict)]
    /// How many of them the words alone call an echo: what was dropped before the audio had a say.
    let textFilter: Int

    init(folder: URL, recording: TodoRecording?, transcript: [TranscriptSegment]?,
         settings: EchoMeter.Settings = EchoMeter.Settings()) throws {
        offset = recording?.micOffset ?? 0
        let measured = try RecordingEcho.measure(folder: folder, micOffset: offset, settings: settings)
        system = measured.system
        mic = measured.mic
        let profile = measured.profile
        self.profile = profile
        let others = (transcript ?? []).filter { $0.speaker == .others }
        textFilter = (transcript ?? []).filter { $0.speaker == .me && HeardText.isEcho($0, of: others) }.count
        mine = (transcript ?? []).filter { $0.speaker == .me }.map {
            ($0, profile.share(from: $0.start, to: $0.end), EchoFilter.verdict($0, others: others, profile: profile))
        }
    }

    private var measured: [Double] { profile.windows.filter(\.measured).map(\.delay).sorted() }

    private func count(_ verdict: EchoFilter.Verdict) -> Int { mine.filter { $0.verdict == verdict }.count }

    private var lineCounts: String {
        "me-lines \(mine.count): echo \(mine.count - count(.kept)) (audio+words \(count(.both)), audio only \(count(.acoustic)), words only \(count(.text))), kept \(count(.kept)); words alone would say \(textFilter)"
    }

    private var whole: EchoMeter.Share { profile.share(from: 0, to: mic.duration) }

    var oneLine: String {
        guard profile.hasEcho, !measured.isEmpty else { return "no echo found  " + lineCounts }
        let s = whole
        return String(format: "delay %.2fs  leak %@dB  mic: echo %@ unsure %@ both %@ mine %@  ",
                      measured[measured.count / 2], dB(profile.leak), percent(s.echo), percent(s.unsure), percent(s.both), percent(s.mine))
            + lineCounts
    }

    var full: String {
        var out = String(format: "tracks: system %.1f s, mic %.1f s, mic starts %+.3f s after system\n", system.duration, mic.duration, offset)
        if profile.hasEcho, !measured.isEmpty {
            out += String(format: "delay: measured in %d of %d windows; min %.2f, median %.2f, max %.2f s\n",
                          measured.count, profile.windows.count, measured[0], measured[measured.count / 2], measured[measured.count - 1])
            out += "echo path: \(dB(profile.leak)) dB overall; by band \(profile.gain.map(dB).joined(separator: " "))\n"
        } else {
            out += "no echo found: the microphone doesn't hear the system track (headphones, or nothing played)\n"
        }
        let s = whole
        out += String(format: "mic audible %.0f s: echo alone %@, unsure %@, user over the other side %@, user alone %@\n",
                      s.voiced, percent(s.echo), percent(s.unsure), percent(s.both), percent(s.mine))
        out += lineCounts
        return out
    }

    /// Every delay estimate: where in the recording, the delay, how well the tracks agreed there.
    var windows: String {
        profile.windows.map {
            String(format: "%@  %+.2fs  %.2f%@", clock($0.start), $0.delay, $0.correlation, $0.measured ? "" : "  (borrowed)")
        }.joined(separator: "\n")
    }

    /// Every "我" line: when, how long, how its audio divides, the verdict. No text.
    var lines: String {
        mine.map { item in
            String(format: "%@  %5.1fs  echo %4@ unsure %4@ both %4@ mine %4@  %@", clock(item.line.start),
                   item.line.end - item.line.start, percent(item.share.echo), percent(item.share.unsure),
                   percent(item.share.both), percent(item.share.mine), item.verdict.rawValue)
        }.joined(separator: "\n")
    }
}

/// aist-cli audio voices <recording folder> [--max <n>] [--book <voicebook.json>] [--learn s1=甲,s2=乙]
///
/// Tells the voices in a recording apart, as the app does after a meeting, and prints who was found
/// (which are the speakers' echo, which is the user), how far apart the voiceprints are, and how the
/// transcript's lines divide among them. Numbers only. Nothing of the user's is written: the
/// separation isn't kept next to the audio, and the user's voice is learned into `--book` (a
/// scratch file by default; pass the same one again to try a later meeting against it). `--learn`
/// then remembers voices of this meeting under the names given, as confirming them in the app would.
func runVoices(_ args: [String]) async throws {
    func opt(_ name: String) -> String? {
        args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("usage: aist-cli audio voices <recording folder> [--max <n>] [--book <file>]\n".utf8))
        exit(2)
    }
    let folder = URL(fileURLWithPath: args[3])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let meetingsURL = opt("--meetings").map { URL(fileURLWithPath: $0) } ?? MeetingStore.defaultURL
    let meetings = (try? Data(contentsOf: meetingsURL)).flatMap { try? decoder.decode([Meeting].self, from: $0) } ?? []
    guard let meeting = UUID(uuidString: folder.lastPathComponent).flatMap({ id in meetings.first { $0.recording?.id == id } }),
          let recording = meeting.recording else {
        FileHandle.standardError.write(Data("no meeting has this recording\n".utf8))
        exit(1)
    }
    print("recording \(folder.lastPathComponent)  \(stamp(meeting.startedAt))  \(clock(meeting.duration))  invited \(meeting.attendees?.count ?? 0)")
    let book = opt("--book").map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("aist-voicebook-\(UUID().uuidString).json")
    let knewMe = !VoiceBook.load(book).me(model: VoiceSeparator.model).isEmpty

    // As the app does it: echoes by the audio first, then the voices.
    let measured = try? RecordingEcho.measure(folder: folder, micOffset: recording.micOffset ?? 0)
    let lines = EchoFilter.marked(meeting.transcript ?? [], profile: measured?.profile)
    let started = Date()
    guard let out = await SpeakerPass.run(folder: folder, recording: recording, transcript: lines, echo: measured?.profile,
                                          systemSilent: measured?.system.isSilent ?? false,
                                          maxVoices: opt("--max").flatMap { Int($0) }, bookURL: book, keep: false) else {
        print("the voices couldn't be told apart")
        return
    }
    print(String(format: "%.1f s to process (%.0fx real time); the user's voice was %@, is %@ now", Date().timeIntervalSince(started),
                 meeting.duration / max(Date().timeIntervalSince(started), 0.001), knewMe ? "on file" : "not on file",
                 VoiceBook.load(book).me(model: VoiceSeparator.model).isEmpty ? "not on file" : "on file"))

    let letters = SpeakerLabels.letters(out.voices)
    for voice in out.voices {
        let mine = out.transcript.filter { $0.voice == voice.id }
        var what = voice.echoOf.map { "echo of \($0)" } ?? SpeakerLabels.label(voice, letters: letters)
        if voice.nameSource == "voiceprint" { what += " (by voice)" }
        if let like = voice.soundsLike { what += " (sounds like \(like))" }
        // The nearest remembered person, however far.
        if voice.isPerson, let print = out.prints[voice.id] {
            let near = VoiceBook.load(book).people.filter { !$0.isMe }
                .map { ($0.name, $0.prints.map { VoiceMatch.distance(print, $0) }.min() ?? 2) }.min { $0.1 < $1.1 }
            if let near { what += String(format: "  nearest %@ %.2f", near.0, near.1) }
        }
        // For a microphone voice: what the audio says its turns held.
        var heard = ""
        if voice.track == .me, let profile = measured?.profile, profile.hasEcho, let turns = out.turns[voice.id] {
            var echo = 0.0, near = 0.0, voiced = 0.0
            for turn in turns {
                let share = profile.share(from: turn.start, to: turn.end)
                echo += share.echo * share.voiced
                near += share.near * share.voiced
                voiced += share.voiced
            }
            if voiced > 0 { heard = "  turns: echo \(percent(echo / voiced)), user \(percent(near / voiced))" }
        }
        print(String(format: "  %@  %@  %6.0f s  first at %@  lines %d  %@%@", voice.id, voice.track == .me ? "mic   " : "system",
                     voice.speaking, clock(voice.firstAt), mine.count, what, heard))
    }
    let before = lines.count, after = out.transcript.count
    let spoken = out.transcript.spoken
    var byLabel: [String: Int] = [:]
    for label in SpeakerLabels.labels(spoken, voices: out.voices) { byLabel[label, default: 0] += 1 }
    print("lines \(before) → \(after) (\(after - before) cut in two); echoes \(lines.count - lines.spoken.count) by audio → \(after - spoken.count) with echo voices; no voice \(out.transcript.filter { $0.voice == nil }.count)")
    print("spoken lines by speaker: " + byLabel.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

    if let learn = opt("--learn") {
        var remembered = VoiceBook.load(book)
        for pair in learn.split(separator: ",") {
            let parts = pair.split(separator: "=").map(String.init)
            guard parts.count == 2, let print = out.prints[parts[0]] else { continue }
            remembered.learn(print, name: parts[1], model: VoiceSeparator.model)
        }
        try remembered.save(to: book)
        print("remembered: " + remembered.people.map { $0.isMe ? "我" : $0.name }.joined(separator: ", "))
    }
    let prints = out.voices.compactMap { voice in out.prints[voice.id].map { (voice.id, $0) } }
    guard prints.count > 1, !args.contains("--no-matrix") else { return }
    print("voiceprint distance (0 same, 1 unrelated):")
    print("      " + prints.map { $0.0.padding(toLength: 5, withPad: " ", startingAt: 0) }.joined(separator: " "))
    for a in prints {
        print(a.0.padding(toLength: 5, withPad: " ", startingAt: 0) + " "
            + prints.map { String(format: "%5.2f", VoiceMatch.distance(a.1, $0.1)) }.joined(separator: " "))
    }
}

/// aist-cli audio models [--fetch [--into <folder>]]
///
/// Times every source of the speaker-separation models, as the app does before downloading them,
/// and says whether they are on this Mac. `--fetch` downloads what is missing from the fastest.
func runModels(_ args: [String]) async throws {
    print("models \(SpeakerModels.isReady() ? "are" : "are not") in \(SpeakerModels.directory.path)")
    let ranked = await SpeakerModels.reachable()
    for source in SpeakerModels.sources {
        let name = source.name.padding(toLength: 14, withPad: " ", startingAt: 0)
        if let hit = ranked.first(where: { $0.source == source }) {
            print(String(format: "  %@  %.2f s%@", name, hit.seconds, hit.source == ranked.first?.source ? "  <- fastest" : ""))
        } else {
            print("  \(name)  no answer")
        }
    }
    guard args.contains("--fetch") else { return }
    // --into <folder>: somewhere else than where the app keeps them, to try a download from scratch.
    let into = args.firstIndex(of: "--into").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    let started = Date()
    let used = try await SpeakerModels.fetch(into: into ?? SpeakerModels.directory)
    print(used.isEmpty ? "nothing to fetch" : String(format: "fetched in %.1f s; complete: %@", Date().timeIntervalSince(started),
                                                     SpeakerModels.isReady(in: into ?? SpeakerModels.directory) ? "yes" : "no"))
}
