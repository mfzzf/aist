import AistCore
import Foundation

/// What the user typed or said, waiting to be turned into to-dos. Saved to disk first, so nothing is
/// lost when the network or the AI is down; processed one at a time, oldest first.
struct PendingNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var voice: Bool
    var createdAt = Date()
    var error: String?
}

@MainActor
final class Inbox: ObservableObject {
    enum Outcome: Equatable {
        case added(text: String, added: [UUID], updated: [UUID])
        case nothing(text: String)
        case failed(id: UUID, message: String, needsSetup: Bool)
    }

    @Published private(set) var pending: [PendingNote] = []
    @Published private(set) var working: PendingNote?
    @Published var outcome: Outcome?

    private let store: TodoStore
    private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("aist/inbox.json")
    private var running = false

    init(store: TodoStore) {
        self.store = store
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([PendingNote].self, from: data) {
            pending = saved
        }
    }

    func submit(_ text: String, voice: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pending.append(PendingNote(text: text, voice: voice))
        save()
        Task { await process() }
    }

    /// Works through the queue; stops at the first failure (usually no network or no key) and leaves
    /// the rest for the next try.
    func process() async {
        guard !running else { return }
        running = true
        defer { running = false; working = nil }
        while let note = pending.first {
            working = note
            do {
                let config = try Self.config()
                let extractor = TodoExtractor(client: LLMClient(config: config), identity: Profile.names)
                let todos = try await extractor.extract(note: note.text, existing: store.openItems)
                let result = store.apply(todos, origin: .manual)
                pending.removeAll { $0.id == note.id }
                save()
                outcome = result.isEmpty ? .nothing(text: note.text)
                    : .added(text: note.text, added: result.added, updated: result.updated)
                result.isEmpty ? Haptics.warning() : Haptics.success()
            } catch {
                if let i = pending.firstIndex(where: { $0.id == note.id }) {
                    pending[i].error = error.localizedDescription
                    save()
                }
                outcome = .failed(id: note.id, message: error.localizedDescription,
                                  needsSetup: error is LLMConfig.ConfigError)
                return
            }
        }
    }

    /// Undo a result: removes the to-dos it added (merges into existing ones stay).
    func undo(_ added: [UUID]) {
        store.delete(added)
        outcome = nil
    }

    /// Keep the words as one plain to-do when the AI found nothing.
    func keepAsTodo(_ text: String) {
        store.addManual(title: String(text.prefix(60)))
        outcome = nil
    }

    func discard(_ id: UUID) {
        pending.removeAll { $0.id == id }
        save()
        if case let .failed(failed, _, _) = outcome, failed == id { outcome = nil }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
    }

    /// The provider chosen in Settings, with its key from the Keychain.
    static func config() throws -> LLMConfig {
        guard let provider = LLMProviderStore.load().current else { throw LLMConfig.ConfigError.missingKey("AI") }
        let config = provider.config
        if provider.needsKey, (config.apiKey ?? "").isEmpty { throw LLMConfig.ConfigError.missingKey(provider.name) }
        if config.model.isEmpty { throw LLMConfig.ConfigError.missingModel(provider.name) }
        return config
    }
}

/// The names the user goes by, so 「老板让 Alex…」 is understood as the user.
enum Profile {
    static let namesKey = "profile.names"

    static var names: [String] {
        (UserDefaults.standard.string(forKey: namesKey) ?? "")
            .split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
