import Combine
import Foundation

/// Meetings persisted as JSON next to the to-dos; audio lives in `TodoStore.folder(for: recording.id)`.
@MainActor
public final class MeetingStore: ObservableObject {
    @Published public private(set) var meetings: [Meeting] = []
    private let fileURL: URL

    public init(fileURL: URL = MeetingStore.defaultURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           var decoded = try? Self.decoder.decode([Meeting].self, from: data) {
            // A crash mid-recording/processing leaves a stale status; surface it instead of spinning forever.
            for i in decoded.indices where decoded[i].status != .ready && decoded[i].status != .failed {
                decoded[i].status = .failed
                decoded[i].error = decoded[i].recording == nil ? "录音中断了" : "处理被中断，可以重试"
            }
            meetings = decoded
        }
    }

    public nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aist/meetings.json")
    }

    /// Newest first.
    public var sorted: [Meeting] { meetings.sorted { $0.startedAt > $1.startedAt } }

    public func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    @discardableResult
    public func create(startedAt: Date = .now) -> Meeting {
        let meeting = Meeting(startedAt: startedAt)
        meetings.append(meeting)
        save()
        return meeting
    }

    public func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        save()
    }

    public func delete(_ id: UUID) {
        if let m = meeting(id), let rec = m.recording {
            Self.trashRecording(TodoStore.folder(for: rec.id), title: m.title, date: m.startedAt)
        }
        meetings.removeAll { $0.id == id }
        save()
    }

    /// The original audio goes to the Trash under a readable name rather than being destroyed,
    /// in case the minutes were wrong and the user wants to listen again.
    static func trashRecording(_ folder: URL, title: String, date: Date) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let named = folder.deletingLastPathComponent().appendingPathComponent("Aist 录音 \(stamp) \(safe.prefix(60))")
        let target = (try? fm.moveItem(at: folder, to: named)) != nil ? named : folder
        if (try? fm.trashItem(at: target, resultingItemURL: nil)) == nil {
            try? fm.removeItem(at: target)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(meetings).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("aist: failed to save meetings: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
