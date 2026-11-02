import AistCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: TodoStore
    @EnvironmentObject private var inbox: Inbox
    @State private var selected: TodoItem.ID?
    @State private var showSettings = false

    private var open: [TodoItem] { store.openItems }
    /// Pinned, overdue, due within two days, or high priority (urgency rank ≤ 4).
    private var focus: [TodoItem] { open.filter { TodoStore.urgencyRank($0) <= 4 } }
    private var later: [TodoItem] { open.filter { TodoStore.urgencyRank($0) > 4 } }

    var body: some View {
        NavigationStack {
            List {
                if open.isEmpty {
                    EmptyState(hasDone: !store.doneItems.isEmpty)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if !focus.isEmpty {
                    Section("现在") { rows(focus) }
                }
                if !later.isEmpty {
                    Section(focus.isEmpty ? "待办" : "之后") { rows(later) }
                }
                if !store.doneItems.isEmpty {
                    Section {
                        NavigationLink {
                            DoneList()
                        } label: {
                            Label("已完成 \(store.doneItems.count)", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("待办")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    InboxCard(openSettings: { showSettings = true })
                    Composer()
                }
                .padding(.top, 8)
                .background(alignment: .bottom) {
                    // Rows scrolling under the bar fade out instead of showing through the glass.
                    LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 110)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .sheet(item: Binding(get: { selected.map(Selection.init) }, set: { selected = $0?.id })) { sel in
                TodoDetail(id: sel.id)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private struct Selection: Identifiable { let id: UUID }

    @ViewBuilder
    private func rows(_ items: [TodoItem]) -> some View {
        ForEach(items) { item in
            TodoRow(item: item)
                .contentShape(Rectangle())
                .onTapGesture { selected = item.id }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { withAnimation { store.delete(item.id) } } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { withAnimation { store.setPinned(item.id, item.pinned != true) } } label: {
                        Label(item.pinned == true ? "取消置顶" : "置顶", systemImage: item.pinned == true ? "pin.slash" : "pin")
                    }
                    .tint(.orange)
                }
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject private var store: TodoStore
    let item: TodoItem

    private var done: Bool { item.status == .done }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3)) { store.setDone(item.id, !done) }
                if !done { Haptics.success() }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(done ? AnyShapeStyle(AistBrand.blue) : AnyShapeStyle(.tertiary))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "标为未完成" : "完成")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                meta
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var meta: some View {
        let overdue = !done && (item.dueAt.map { $0 < .now } ?? false)
        let parts = HStack(spacing: 8) {
            if item.pinned == true { Image(systemName: "pin.fill").foregroundStyle(.orange) }
            if item.priority == .high, !done { Image(systemName: "flag.fill").foregroundStyle(.orange) }
            if let due = item.dueAt {
                Text(DueFormat.short(due)).foregroundStyle(overdue ? .red : .secondary)
            } else if let text = item.dueText {
                Text(text).foregroundStyle(.secondary)
            }
            if let who = item.requester { Text(who).foregroundStyle(.secondary) }
            if item.suggestion != nil, !done {
                Image(systemName: "sparkles").foregroundStyle(AistBrand.violet)
            }
        }
        .font(.caption)
        .lineLimit(1)
        if item.pinned == true || item.priority == .high || item.dueAt != nil || item.dueText != nil
            || item.requester != nil || item.suggestion != nil {
            parts
        }
    }
}

enum DueFormat {
    /// 今天 14:00 · 明天 9:00 · 周五 18:00 · 11月20日
    static func short(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let time = date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
        if cal.isDateInToday(date) { return "今天 \(time)" }
        if cal.isDateInTomorrow(date) { return "明天 \(time)" }
        if cal.isDateInYesterday(date) { return "昨天 \(time)" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 99
        if days > 0, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))) + " \(time)"
        }
        return date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }
}

private struct EmptyState: View {
    let hasDone: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image("Mascot")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .shadow(color: AistBrand.violet.opacity(0.3), radius: 12, y: 4)
            Text(hasDone ? "都做完了" : "说一句，就记下了")
                .font(.title3.weight(.semibold))
            Text("在下面打字，或按住麦克风说话：\n「明天下午三点前把报价发给 Kevin」")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct DoneList: View {
    @EnvironmentObject private var store: TodoStore

    var body: some View {
        List {
            ForEach(store.doneItems) { item in
                TodoRow(item: item)
                    .swipeActions {
                        Button(role: .destructive) { store.delete(item.id) } label: { Label("删除", systemImage: "trash") }
                    }
            }
        }
        .navigationTitle("已完成")
    }
}
