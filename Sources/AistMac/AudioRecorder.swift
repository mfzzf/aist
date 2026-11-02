import AistCore
import AVFoundation
import ScreenCaptureKit

/// Records a meeting with ScreenCaptureKit, the system's native capture API:
/// since macOS 15 one SCStream delivers both what the Mac plays (`.audio`) and the microphone
/// (`.microphone`), no virtual audio driver needed. Each source goes to its own AAC file
/// (system.m4a / mic.m4a) so later analysis knows who said what.
@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var meetingID: UUID?
    @Published private(set) var startedAt: Date?

    private var stream: SCStream?
    private var sink: CaptureSink?
    private var recordingID: UUID?

    var isRecording: Bool { meetingID != nil }

    enum RecorderError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "找不到可录制的显示器" }
    }

    func start(for meeting: UUID) async throws {
        guard meetingID == nil else { return }
        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true // don't record our own playback
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = micAllowed
        // Audio only: the stream always has video, so keep it a 2×2 frame once a second.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let id = UUID()
        let folder = TodoStore.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sink = CaptureSink(folder: folder)
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
        if micAllowed {
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.sink = sink
        recordingID = id
        startedAt = .now
        meetingID = meeting
    }

    /// Stops and returns the finished recording (files already closed), or nil if nothing was recording.
    func stop() async -> (meeting: UUID, recording: TodoRecording)? {
        guard let stream, let sink, let meetingID, let startedAt, let recordingID else { return nil }
        try? await stream.stopCapture()
        let result = await sink.finish()
        self.stream = nil
        self.sink = nil
        self.meetingID = nil
        self.startedAt = nil
        self.recordingID = nil

        var offset: Double?
        if let s = result.system.start, let m = result.mic.start { offset = m - s }
        let recording = TodoRecording(
            id: recordingID, startedAt: startedAt, duration: Date.now.timeIntervalSince(startedAt),
            hasSystemAudio: result.system.ok, hasMicrophone: result.mic.ok, micOffset: offset
        )
        return (meetingID, recording)
    }
}

/// Receives ScreenCaptureKit buffers on its own serial queue and feeds the two file writers.
final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "aist.recorder")
    private let system: AudioFileWriter
    private let mic: AudioFileWriter

    init(folder: URL) {
        system = AudioFileWriter(url: folder.appendingPathComponent("system.m4a"))
        mic = AudioFileWriter(url: folder.appendingPathComponent("mic.m4a"))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .audio: system.append(buffer)
        case .microphone: mic.append(buffer)
        default: break // the token video frames
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("aist: recording stopped with error: \(error)")
    }

    func finish() async -> (system: AudioFileWriter.Result, mic: AudioFileWriter.Result) {
        // Let any buffers already queued land before closing the files.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
        async let s = system.finish()
        async let m = mic.finish()
        return await (s, m)
    }
}

/// One AAC .m4a file fed with PCM sample buffers; set up from the first buffer's format.
/// `append` is only called on the sink's queue; `finish` only after the queue has drained.
final class AudioFileWriter: @unchecked Sendable {
    struct Result {
        var ok: Bool
        /// Presentation time of the first sample, seconds on the capture clock.
        var start: Double?
    }

    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstTime: CMTime?

    init(url: URL) { self.url = url }

    func append(_ buffer: CMSampleBuffer) {
        if writer == nil { setUp(with: buffer) }
        guard let writer, let input, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    private func setUp(with buffer: CMSampleBuffer) {
        guard let format = buffer.formatDescription,
              let asbd = format.audioStreamBasicDescription,
              let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a)
        else { return }
        let channels = max(1, min(Int(asbd.mChannelsPerFrame), 2))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 2 ? 128_000 : 64_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: buffer.presentationTimeStamp)
        firstTime = buffer.presentationTimeStamp
        self.writer = writer
        self.input = input
    }

    func finish() async -> Result {
        guard let writer, let input, writer.status == .writing else {
            try? FileManager.default.removeItem(at: url)
            return Result(ok: false, start: nil)
        }
        input.markAsFinished()
        await writer.finishWriting()
        return Result(ok: writer.status == .completed, start: firstTime.map(CMTimeGetSeconds))
    }
}

/// Plays a recording's two files together on one timeline, the same one the transcript uses
/// (0 = whichever track started first), so a transcript line can be checked against the audio.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// The loaded recording (playing or paused).
    @Published private(set) var loadedID: UUID?
    @Published private(set) var isPlaying = false
    /// Position on the timeline, in seconds.
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    var playingID: UUID? { isPlaying ? loadedID : nil }

    private var tracks: [(player: AVAudioPlayer, shift: TimeInterval)] = []
    private var anchor: (clock: TimeInterval, position: TimeInterval)?
    private var ticker: Timer?

    /// Play / pause; a different recording starts from its beginning.
    func toggle(_ recording: TodoRecording) {
        if loadedID == recording.id, isPlaying { pause() } else { play(recording, from: loadedID == recording.id ? position : 0) }
    }

    func play(_ recording: TodoRecording, from time: TimeInterval) {
        if loadedID != recording.id { load(recording) }
        guard let clock = tracks.first?.player.deviceCurrentTime else { return }
        pauseTracks()
        let t = min(max(0, time), max(0, duration - 0.05))
        let start = clock + 0.05
        for (player, shift) in tracks {
            let local = t - shift
            guard local < player.duration else { continue }
            player.currentTime = max(0, local)
            player.play(atTime: start + max(0, -local))
        }
        anchor = (start, t)
        position = t
        isPlaying = true
        startTicker()
    }

    /// Moves the playhead; keeps playing if it was.
    func seek(_ recording: TodoRecording, to time: TimeInterval) {
        if isPlaying, loadedID == recording.id {
            play(recording, from: time)
        } else {
            if loadedID != recording.id { load(recording) }
            position = min(max(0, time), duration)
        }
    }

    func pause() {
        updatePosition()
        pauseTracks()
        isPlaying = false
        anchor = nil
        ticker?.invalidate()
    }

    func stop() {
        pause()
        tracks = []
        loadedID = nil
        position = 0
        duration = 0
    }

    private func load(_ recording: TodoRecording) {
        stop()
        let folder = TodoStore.folder(for: recording.id)
        let offset = recording.micOffset ?? 0
        // Same shifts as MeetingTranscriber, so transcript timestamps line up.
        let files = [("system.m4a", max(0, -offset)), ("mic.m4a", max(0, offset))]
        tracks = files.compactMap { name, shift in
            guard let player = try? AVAudioPlayer(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            player.delegate = self
            player.prepareToPlay()
            return (player, shift)
        }
        duration = tracks.map { $0.player.duration + $0.shift }.max() ?? 0
        loadedID = recording.id
    }

    private func pauseTracks() { tracks.forEach { $0.player.pause() } }

    private func updatePosition() {
        guard let anchor, let clock = tracks.first?.player.deviceCurrentTime else { return }
        position = min(duration, anchor.position + max(0, clock - anchor.clock))
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.updatePosition()
                if self.position >= self.duration - 0.05 { self.finished() }
            }
        }
    }

    private func finished() {
        pause()
        position = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // The shorter track may end first; stop when the timeline does.
            self.updatePosition()
            if self.isPlaying, self.position >= self.duration - 0.3 { self.finished() }
        }
    }
}
