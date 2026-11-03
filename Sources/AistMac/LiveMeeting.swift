import AistCore
import Foundation

/// The meeting while it is being recorded, beyond the transcript: notes refreshed every ~45 s and
/// the watch that ends a meeting nobody stopped (hung up in the meeting app, or nobody spoke for a
/// while). UI-free; the live window and the meeting page observe it.
@MainActor
final class LiveMeeting: ObservableObject {
    enum NotesState: Equatable {
        case off
        case waiting
        case updating
        case failed(String)
    }

    @Published private(set) var notes = LiveNotes()
    @Published private(set) var notesState: NotesState = .off
    @Published private(set) var notesUpdatedAt: Date?
    /// The meeting will end at `deadline` unless the user keeps it going.
    @Published private(set) var ending: MeetingEndWatch.Pending?

    let live: LiveTranscript
    /// Set by the app.
    var makeWriter: () -> LiveNotesWriter? = { nil }
    var calendarContext: () -> String? = { nil }
    var onEnd: ((MeetingEndWatch.Reason) -> Void)?

    private var watch: MeetingEndWatch?
    private var timer: Timer?
    private var inFlight = false
    private var lastAttempt = Date.distantPast
    static let interval: TimeInterval = 45

    init(live: LiveTranscript) {
        self.live = live
    }

    func begin() {
        notes = LiveNotes()
        notesUpdatedAt = nil
        ending = nil
        inFlight = false
        lastAttempt = .now
        notesState = MeetingSettings.liveNotes && LiveTranscript.isSupported ? .waiting : .off
        watch = MeetingEndWatch(config: .init(followApps: MeetingSettings.endOnHangUp,
                                              silenceAfter: Double(MeetingSettings.silenceMinutes) * 60), start: .now)
        live.onHeard = { [weak self] in
            guard let self, var w = self.watch else { return }
            w.heard(at: .now)
            self.watch = w
            if self.ending?.reason == .silence { self.ending = w.pending }
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickNotes() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func end() {
        timer?.invalidate()
        timer = nil
        watch = nil
        ending = nil
        live.onHeard = nil
        if notesState != .off { notesState = .waiting }
    }

    /// "继续录音".
    func keepGoing() {
        guard var w = watch else { return }
        w.keepGoing(at: .now)
        watch = w
        ending = nil
    }

    /// Fed by the call watcher every few seconds while recording.
    func tick(calls: [String: String]) {
        guard var w = watch else { return }
        let reason = w.tick(at: .now, calls: calls, said: !live.lines.isEmpty)
        watch = w
        if ending != w.pending { ending = w.pending }
        if let reason {
            watch = nil
            ending = nil
            onEnd?(reason)
        }
    }

    // MARK: Notes

    /// Every ~45 s with new lines, one call updates the notes. A failure waits a full interval.
    private func tickNotes() {
        guard notesState != .off, !inFlight, Date().timeIntervalSince(lastAttempt) >= Self.interval else { return }
        let lines = live.shownLines
        guard lines.count > notes.covered else { return }
        guard let writer = makeWriter() else {
            notesState = .failed("还没有配置 AI 服务")
            return
        }
        inFlight = true
        lastAttempt = .now
        notesState = .updating
        let current = notes
        let context = calendarContext()
        Task {
            defer { inFlight = false }
            do {
                let updated = try await writer.update(current, transcript: lines, calendar: context)
                notes = updated
                notesUpdatedAt = .now
                notesState = .waiting
            } catch {
                notesState = .failed(error.localizedDescription)
            }
        }
    }

    /// "立即更新".
    func refreshNow() {
        lastAttempt = .distantPast
        if case .failed = notesState { notesState = .waiting }
        tickNotes()
    }

    func endingTitle(_ p: MeetingEndWatch.Pending) -> String {
        switch p.reason {
        case let .appLeft(name): "\(name.isEmpty ? "会议软件" : name)已挂断"
        case .silence: "已经 \(MeetingSettings.silenceMinutes) 分钟没人说话"
        case .nobodySpoke: "没有人说话"
        }
    }
}
