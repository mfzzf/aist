import AistCore
import SwiftUI

/// Above the input bar: 「正在整理…」, then what the note did — with undo — or the AI's suggestions to
/// pick from, its answer to a question, or why it didn't work.
struct InboxCard: View {
    @EnvironmentObject private var inbox: Inbox
    var openSettings: () -> Void

    var body: some View {
        Group {
            if let note = inbox.working {
                card {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("正在整理…").font(.subheadline.weight(.semibold))
                            Text(Self.describe(note)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else if case let .report(report) = inbox.outcome {
                card { ReportView(report: report) }
            } else if case let .failed(id, message, needsSetup) = inbox.outcome {
                card {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("没能整理").font(.subheadline.weight(.semibold))
                            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if needsSetup {
                            Button("去设置", action: openSettings).font(.subheadline.weight(.semibold))
                        } else {
                            Button("重试") { Task { await inbox.process() } }.font(.subheadline.weight(.semibold))
                        }
                        Menu {
                            Button("放弃这条", role: .destructive) { inbox.discard(id) }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 28, height: 28)
                        }
                    }
                }
            } else if !inbox.pending.isEmpty {
                card {
                    HStack(spacing: 12) {
                        Image(systemName: "tray.full").foregroundStyle(.secondary)
                        Text("\(inbox.pending.count) 条等待整理").font(.subheadline)
                        Spacer(minLength: 0)
                        Button("重试") { Task { await inbox.process() } }.font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: inbox.outcome)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: inbox.working)
    }

    static func describe(_ note: PendingNote) -> String {
        let count = note.images?.count ?? 0
        guard count > 0 else { return note.text }
        return note.text.isEmpty ? "\(count) 张图片" : "🖼 \(count) · \(note.text)"
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct ReportView: View {
    @EnvironmentObject private var inbox: Inbox
    @EnvironmentObject private var store: TodoStore
    let report: NoteReport
    @State private var picked: Set<Int>

    init(report: NoteReport) {
        self.report = report
        _picked = State(initialValue: Set(report.suggestions.indices))
    }

    private var nothing: Bool { !report.hasChanges && report.suggestions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if report.rowCount > 0 {
                if report.rowCount > 5 {
                    ScrollView { rows }.frame(maxHeight: 260)
                } else {
                    rows
                }
            }
            footer
        }
        .task(id: report.id) {
            // Short confirmations go away by themselves; answers and suggestions wait for the user.
            guard report.suggestions.isEmpty, (report.reply ?? "").count <= 40, report.rowCount <= 4, !nothing else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if case let .report(current) = inbox.outcome, current.id == report.id { inbox.outcome = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: nothing && (report.reply ?? "").isEmpty ? "text.bubble" : "sparkles")
                .foregroundStyle(AistBrand.gradient)
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { inbox.outcome = nil } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
    }

    private var headline: String {
        if let reply = report.reply, !reply.isEmpty { return reply }
        if nothing { return "没有发现要做的事" }
        var parts: [String] = []
        if !report.added.isEmpty { parts.append("新增 \(report.added.count) 项") }
        if !report.completed.isEmpty { parts.append("完成 \(report.completed.count) 项") }
        if !report.reopened.isEmpty { parts.append("恢复 \(report.reopened.count) 项") }
        if !report.changed.isEmpty || !report.merged.isEmpty { parts.append("更新 \(report.changed.count + report.merged.count) 项") }
        if !report.removed.isEmpty { parts.append("取消 \(report.removed.count) 项") }
        return parts.joined(separator: "，")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(report.added, id: \.self) { id in
                row("plus.circle.fill", AistBrand.blue, item(id)?.title, detail: item(id).flatMap(due))
            }
            ForEach(report.merged, id: \.self) { id in
                row("arrow.triangle.merge", .secondary, item(id)?.title, detail: "并入已有待办")
            }
            ForEach(report.completed, id: \.self) { id in
                row("checkmark.circle.fill", .green, item(id)?.title, detail: "已完成", struck: true)
            }
            ForEach(report.reopened, id: \.self) { id in
                row("arrow.uturn.backward.circle.fill", .indigo, item(id)?.title, detail: "重新打开")
            }
            ForEach(report.changed, id: \.self) { id in
                row("pencil.circle.fill", .orange, item(id)?.title, detail: item(id).flatMap(due) ?? "已修改")
            }
            ForEach(report.removed) { removed in
                row("minus.circle.fill", .red, removed.title, detail: "已取消", struck: true)
            }
            if !report.suggestions.isEmpty {
                Text("AI 建议，选好后添加")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, report.hasChanges ? 4 : 0)
                ForEach(report.suggestions.indices, id: \.self) { i in
                    suggestionRow(i)
                }
            }
        }
    }

    private func suggestionRow(_ i: Int) -> some View {
        let s = report.suggestions[i]
        let on = picked.contains(i)
        return Button {
            if on { picked.remove(i) } else { picked.insert(i) }
            Haptics.tick()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? AnyShapeStyle(AistBrand.blue) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.subheadline).foregroundStyle(.primary)
                    if let detail = [s.resolvedDueAt.map { DueFormat.short($0) }, s.priority == .high ? "重要" : nil]
                        .compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var footer: some View {
        if !report.suggestions.isEmpty {
            HStack {
                if report.hasChanges { Button("撤销") { inbox.undo(report) } }
                Spacer()
                Button("不用了") { inbox.accept([], from: report) }
                    .foregroundStyle(.secondary)
                Button("添加 \(picked.count) 项") {
                    inbox.accept(picked.sorted().map { report.suggestions[$0] }, from: report)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(picked.isEmpty)
            }
            .font(.subheadline.weight(.semibold))
        } else if nothing {
            if (report.reply ?? "").isEmpty, !report.text.isEmpty {
                HStack {
                    Text(report.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("记成待办") { inbox.keepAsTodo(report.text) }
                        .font(.subheadline.weight(.semibold))
                }
            }
        } else {
            HStack {
                Spacer()
                Button("撤销") { inbox.undo(report) }.font(.subheadline.weight(.semibold))
            }
        }
    }

    private func item(_ id: UUID) -> TodoItem? { store.items.first { $0.id == id } }

    private func due(_ item: TodoItem) -> String? {
        item.dueAt.map { DueFormat.short($0) } ?? item.dueText
    }

    private func row(_ symbol: String, _ color: Color, _ title: String?, detail: String?, struck: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title ?? "（已删除）")
                .font(.subheadline)
                .strikethrough(struck)
                .foregroundStyle(struck ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
