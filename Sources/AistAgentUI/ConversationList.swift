import AistAgent
import SwiftUI

/// The saved conversations of one scope, for a list column.
@MainActor
public final class AgentLibrary: ObservableObject {
    @Published public private(set) var conversations: [ConversationSummary] = []
    @Published public var query = "" {
        didSet { if query != oldValue { Task { await reload() } } }
    }
    public let store: ConversationStore?
    public let scope: String
    /// The conversation on screen (drives the rows' highlight).
    public let selection = ConversationSelection()

    public init(store: ConversationStore?, scope: String = "chat") {
        self.store = store
        self.scope = scope
        Task { await reload() }
    }

    public func reload() async {
        guard let store else { return }
        let q = query
        let found = (try? await (q.isEmpty ? store.conversations(scope: scope) : store.search(q, scope: scope))) ?? []
        if q == query { conversations = found }
    }

    public func delete(_ id: UUID) async {
        try? await store?.delete(id)
        conversations.removeAll { $0.id == id }
    }

    public func rename(_ id: UUID, to title: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try? await store?.rename(id, to: t)
        await reload()
    }

    /// Today / yesterday / last 7 days / this year by month / older by year.
    public var grouped: [(title: String, items: [ConversationSummary])] {
        let cal = Calendar.current
        let now = Date.now
        var order: [String] = []
        var groups: [String: [ConversationSummary]] = [:]
        for c in conversations {
            let d = c.updatedAt
            let key: String
            if cal.isDateInToday(d) { key = "今天" }
            else if cal.isDateInYesterday(d) { key = "昨天" }
            else if let days = cal.dateComponents([.day], from: d, to: now).day, days < 7 { key = "过去 7 天" }
            else if cal.isDate(d, equalTo: now, toGranularity: .year) { key = "\(cal.component(.month, from: d)) 月" }
            else { key = "\(cal.component(.year, from: d)) 年" }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(c)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

/// A sidebar-style list of conversations with rename/delete in the context menu.
public struct ConversationList: View {
    @ObservedObject var library: AgentLibrary
    @Binding var selection: UUID?
    @State private var renaming: ConversationSummary?
    @State private var newTitle = ""

    public init(library: AgentLibrary, selection: Binding<UUID?>) {
        self.library = library
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(library.grouped, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { c in
                        Text(c.title)
                            .lineLimit(1)
                            .tag(c.id)
                            .contextMenu {
                                Button("重命名…") {
                                    newTitle = c.title
                                    renaming = c
                                }
                                Divider()
                                Button("删除", role: .destructive) { delete(c.id) }
                            }
                    }
                }
            }
        }
        .overlay {
            if library.conversations.isEmpty {
                if library.query.isEmpty {
                    ContentUnavailableView("还没有对话", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("在右边问第一个问题"))
                } else {
                    ContentUnavailableView.search(text: library.query)
                }
            }
        }
        #if os(macOS)
        .onDeleteCommand { if let id = selection { delete(id) } }
        #endif
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $newTitle)
            Button("好") {
                if let c = renaming { Task { await library.rename(c.id, to: newTitle) } }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        Task { await library.delete(id) }
    }
}

/// Conversation rows for a host's own sidebar `List`. They draw their own selection (a soft accent
/// tint) instead of using the list's, which turns heavy grey whenever focus is in the chat.
public struct ConversationRows: View {
    @ObservedObject var library: AgentLibrary
    var limit: Int
    var onSelect: (UUID) -> Void
    var onDelete: (UUID) -> Void
    @State private var renaming: ConversationSummary?
    @State private var newTitle = ""

    /// Selection is `library.selected`; set it from the host. A click sets it at once (each row
    /// observes it directly, so the highlight moves in the same frame), then calls `onSelect`.
    public init(library: AgentLibrary, limit: Int = 100,
                onSelect: @escaping (UUID) -> Void, onDelete: @escaping (UUID) -> Void) {
        self.library = library
        self.limit = limit
        self.onSelect = onSelect
        self.onDelete = onDelete
    }

    public var body: some View {
        ForEach(library.conversations.prefix(limit)) { c in
            ConversationRow(id: c.id, title: c.title, selection: library.selection) {
                library.selection.selected = c.id
                onSelect(c.id)
            }
                .contextMenu {
                    Button("重命名…") {
                        newTitle = c.title
                        renaming = c
                    }
                    Divider()
                    Button("删除", role: .destructive) { delete(c.id) }
                }
        }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标题", text: $newTitle)
            Button("好") {
                if let c = renaming { Task { await library.rename(c.id, to: newTitle) } }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private func delete(_ id: UUID) {
        onDelete(id)
        Task { await library.delete(id) }
    }
}


/// Which conversation the host shows. Its own object so a selection change redraws just the rows.
@MainActor
public final class ConversationSelection: ObservableObject {
    @Published public var selected: UUID?
    public init() {}
}

private struct ConversationRow: View {
    let id: UUID
    let title: String
    @ObservedObject var selection: ConversationSelection
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let selected = selection.selected == id
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fontWeight(selected ? .medium : .regular)
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.13))
                              : hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2))
        .help(title)
    }
}
