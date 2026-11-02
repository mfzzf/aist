import Combine
import Foundation

/// Remembers which emails the AI has read and what came of it, so the list and the reader can say so.
/// Both the automatic scan and the 「分析待办」 button go through `MailAutoTodo.analyze`, which records here.
@MainActor
final class MailAnalysisLog: ObservableObject {
    static let shared = MailAnalysisLog()

    enum Status: Codable, Equatable {
        case analyzing
        /// To-dos added or updated from this email.
        case todos([UUID], at: Date)
        case nothing(at: Date)
        case failed(String, at: Date)

        var isFinished: Bool { if case .analyzing = self { false } else { true } }
    }

    @Published private(set) var entries: [String: Status]

    private static let key = "mail.analysisLog"

    private init() {
        entries = (UserDefaults.standard.data(forKey: Self.key))
            .flatMap { try? JSONDecoder().decode([String: Status].self, from: $0) } ?? [:]
        // An analysis can't survive a quit.
        entries = entries.filter(\.value.isFinished)
    }

    static func key(_ account: UUID, _ header: MailHeader) -> String {
        "\(account.uuidString)/\(header.mailbox)/\(header.uid)"
    }

    func status(_ account: UUID, _ header: MailHeader) -> Status? { entries[Self.key(account, header)] }

    func set(_ status: Status, _ account: UUID, _ header: MailHeader) {
        entries[Self.key(account, header)] = status
        guard status.isFinished else { return }
        var saved = entries.filter(\.value.isFinished)
        if saved.count > 5000 {
            // Drop the oldest; old messages are rarely reopened.
            let sorted = saved.sorted { ($0.value.date ?? .distantPast) > ($1.value.date ?? .distantPast) }
            saved = Dictionary(uniqueKeysWithValues: sorted.prefix(4000).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension MailAnalysisLog.Status {
    var date: Date? {
        switch self {
        case .analyzing: nil
        case let .todos(_, at), let .nothing(at), let .failed(_, at): at
        }
    }
}
