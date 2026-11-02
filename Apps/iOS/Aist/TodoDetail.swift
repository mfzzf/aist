import AistCore
import SwiftUI

struct TodoDetail: View {
    @EnvironmentObject private var store: TodoStore
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    private var item: TodoItem? { store.items.first { $0.id == id } }

    var body: some View {
        NavigationStack {
            if let item {
                Form {
                    Section {
                        TextField("标题", text: bind(\.title, item.title), axis: .vertical)
                            .font(.title3.weight(.semibold))
                        Toggle("已完成", isOn: Binding(get: { item.status == .done },
                                                     set: { store.setDone(id, $0) }))
                    }

                    Section {
                        Toggle("截止时间", isOn: Binding(
                            get: { item.dueAt != nil },
                            set: { on in store.update(id) { $0.dueAt = on ? Self.defaultDue() : nil } }
                        ))
                        if let due = item.dueAt {
                            DatePicker("时间", selection: Binding(get: { due }, set: { d in store.update(id) { $0.dueAt = d } }))
                        }
                        Picker("优先级", selection: bind(\.priority, item.priority)) {
                            Text("高").tag(TodoPriority.high)
                            Text("中").tag(TodoPriority.medium)
                            Text("低").tag(TodoPriority.low)
                        }
                        .pickerStyle(.segmented)
                    }

                    if let tip = item.suggestion, !tip.isEmpty {
                        Section {
                            Label {
                                Text(tip)
                            } icon: {
                                Image(systemName: "sparkles").foregroundStyle(AistBrand.violet)
                            }
                        } header: {
                            Text("AI 建议")
                        }
                    }

                    Section("备注") {
                        TextField("添加备注", text: Binding(get: { item.notes ?? "" }, set: { store.setNotes(id, $0) }),
                                  axis: .vertical)
                            .lineLimit(3 ... 10)
                    }

                    Section("来源") {
                        if let evidence = item.evidence, !evidence.isEmpty {
                            Text("「\(evidence)」").foregroundStyle(.secondary)
                        }
                        if let who = item.requester { LabeledContent("交代人", value: who) }
                        if let source = item.source { LabeledContent("渠道", value: source) }
                        LabeledContent("记下于", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }

                    Section {
                        Button("删除待办", role: .destructive) {
                            store.delete(id)
                            dismiss()
                        }
                    }
                }
                .navigationTitle("待办")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func bind<V: Equatable>(_ key: WritableKeyPath<TodoItem, V>, _ current: V) -> Binding<V> {
        Binding(get: { current }, set: { value in store.update(id) { $0[keyPath: key] = value } })
    }

    /// Tomorrow 9:00.
    private static func defaultDue() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) ?? .now
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
