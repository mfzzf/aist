import AistCore
import SwiftUI

/// The bar at the bottom of the home screen: type and send, or hold the mic and talk.
///
///   hold 🎙  → listening panel with live transcript and waveform
///   release  → send          slide up → cancel          slide left → edit the text before sending
struct Composer: View {
    @EnvironmentObject private var inbox: Inbox
    @StateObject private var recorder = SpeechRecorder()

    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var arm: Arm = .send
    @State private var hint: String?
    @GestureState private var holding = false
    @Namespace private var glassSpace

    enum Arm { case send, cancel, edit }

    private var listening: Bool { recorder.isRecording }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        GlassGroup(spacing: 6) {
            VStack(spacing: 10) {
                if listening {
                    ListeningPanel(recorder: recorder, arm: arm)
                        .glassID("panel", in: glassSpace)
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottom)))
                } else if let hint {
                    Text(hint)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glass(in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
                HStack(alignment: .bottom, spacing: 10) {
                    field
                    actionButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            // While listening, fade the list away so the transcript has the stage.
            if listening {
                LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground).opacity(0.92)],
                               startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
                    .frame(height: 900)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: listening)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: arm)
        .animation(.easeOut(duration: 0.2), value: hint)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: canSend)
        .onAppear { if Demo.listening { recorder.startDemo() } }
        .onChange(of: holding) { isHolding in
            // The gesture can be cancelled without onEnded (a call comes in, the app goes away).
            if !isHolding, listening { finish() }
        }
    }

    // MARK: Text field

    private var field: some View {
        ZStack(alignment: .leading) {
            if listening {
                Text(armLabel)
                    .font(.body.weight(.medium))
                    .foregroundStyle(arm == .cancel ? Color.red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 13)
                    .transition(.opacity)
            } else {
                TextField("记点什么，或按住麦克风说话", text: $text, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 50)
        .glass(in: RoundedRectangle(cornerRadius: 25, style: .continuous), interactive: true)
        .glassID("field", in: glassSpace)
    }

    private var armLabel: String {
        switch arm {
        case .send: "松开发送"
        case .cancel: "松开取消"
        case .edit: "松开后编辑文字"
        }
    }

    // MARK: Send / mic button

    @ViewBuilder
    private var actionButton: some View {
        if canSend && !listening {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), tint: AistBrand.blue, interactive: true)
            .glassID("action", in: glassSpace)
            .accessibilityLabel("发送")
            .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(listening ? .white : .primary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .glass(in: Circle(), tint: listening ? micTint : nil, interactive: true)
                .glassID("action", in: glassSpace)
                .scaleEffect(listening ? 1.1 : 1)
                .gesture(holdToTalk)
                .accessibilityLabel("按住说话")
                .accessibilityAction { hint("按住说话，松开发送") }
        }
    }

    private var micTint: Color {
        switch arm {
        case .send: AistBrand.blue
        case .cancel: .red
        case .edit: AistBrand.violet
        }
    }

    private var holdToTalk: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case let .second(true, drag) = value else { return }
                if !listening { begin() }
                let t = drag?.translation ?? .zero
                let next: Arm = t.height < -60 ? .cancel : (t.width < -60 ? .edit : .send)
                if next != arm { arm = next; Haptics.tick() }
            }
            .onEnded { value in
                if case .second(true, _) = value { finish() } else { hint("按住说话，松开发送") }
            }
    }

    // MARK: Actions

    private func send() {
        guard canSend else { return }
        inbox.submit(text, voice: false)
        text = ""
    }

    private func begin() {
        switch SpeechRecorder.permission {
        case .granted:
            do {
                arm = .send
                focused = false
                try recorder.start()
                Haptics.tap()
            } catch {
                hint(error.localizedDescription)
            }
        case .undetermined:
            // The system prompt interrupts the press; ask now, talk on the next press.
            Task {
                if await SpeechRecorder.requestPermission() { hint("好了，再按住说话") }
            }
        case .denied:
            hint(SpeechRecorder.RecorderError.denied.localizedDescription)
        }
    }

    private func finish() {
        guard listening else { return }
        let action = arm
        arm = .send
        if action == .cancel {
            recorder.cancel()
            Haptics.warning()
            return
        }
        Task {
            let said = await recorder.stop()
            guard !said.isEmpty else { hint("没听清，再说一次"); return }
            if action == .edit {
                text = said
                focused = true
            } else {
                inbox.submit(said, voice: true)
            }
        }
    }

    private func hint(_ message: String) {
        hint = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if hint == message { hint = nil }
        }
    }
}

/// Live transcript and waveform while the mic is held.
private struct ListeningPanel: View {
    @ObservedObject var recorder: SpeechRecorder
    let arm: Composer.Arm

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Waveform(levels: recorder.levels, color: arm == .cancel ? .red : AistBrand.blue)
                    .frame(height: 26)
                if let start = recorder.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(start)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(recorder.transcript.isEmpty ? "正在听…" : recorder.transcript)
                .font(.title3.weight(.medium))
                .foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(7)
                .animation(.easeOut(duration: 0.15), value: recorder.transcript)
            HStack(spacing: 14) {
                gestureHint("arrow.up", "上滑取消", active: arm == .cancel, color: .red)
                gestureHint("arrow.left", "左滑改文字", active: arm == .edit, color: AistBrand.violet)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
               tint: arm == .cancel ? .red.opacity(0.18) : nil)
    }

    private func gestureHint(_ symbol: String, _ label: String, active: Bool, color: Color) -> some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? color : .secondary)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(0.35 + 0.65 * Double(levels[i])))
                    .frame(width: 3, height: 4 + 22 * levels[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

/// Above the bar: 「正在整理…」, then what came out of it (with undo), or why it didn't work.
struct InboxCard: View {
    @EnvironmentObject private var inbox: Inbox
    @EnvironmentObject private var store: TodoStore
    var openSettings: () -> Void

    var body: some View {
        Group {
            if let note = inbox.working {
                row {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在整理…").font(.subheadline.weight(.semibold))
                        Text(note.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else if let outcome = inbox.outcome {
                content(for: outcome)
            } else if !inbox.pending.isEmpty {
                row {
                    Image(systemName: "tray.full").foregroundStyle(.secondary)
                    Text("\(inbox.pending.count) 条等待整理").font(.subheadline)
                    Spacer()
                    Button("重试") { Task { await inbox.process() } }.font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 14)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: inbox.outcome)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: inbox.working)
    }

    @ViewBuilder
    private func content(for outcome: Inbox.Outcome) -> some View {
        switch outcome {
        case let .added(_, added, updated):
            let titles = (added + updated).compactMap { id in store.items.first { $0.id == id }?.title }
            row {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary(added: added.count, updated: updated.count)).font(.subheadline.weight(.semibold))
                    ForEach(titles.prefix(3), id: \.self) { t in
                        Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if !added.isEmpty {
                    Button("撤销") { inbox.undo(added) }.font(.subheadline.weight(.semibold))
                }
            }
            .task(id: outcome) { await autoDismiss(outcome) }
        case let .nothing(text):
            row {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("没有发现要做的事").font(.subheadline.weight(.semibold))
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("记成待办") { inbox.keepAsTodo(text) }.font(.subheadline.weight(.semibold))
            }
            .task(id: outcome) { await autoDismiss(outcome) }
        case let .failed(id, message, needsSetup):
            row {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("没能整理").font(.subheadline.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
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
    }

    private func summary(added: Int, updated: Int) -> String {
        switch (added, updated) {
        case (0, _): "更新了 \(updated) 项待办"
        case (_, 0): "新增 \(added) 项待办"
        default: "新增 \(added) 项，更新 \(updated) 项"
        }
    }

    private func autoDismiss(_ outcome: Inbox.Outcome) async {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        if inbox.outcome == outcome { inbox.outcome = nil }
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
