import AistCore
import AppKit
import SwiftUI
import Translation

// MARK: - Window

/// "会议实况": a small floating window while recording, with the live transcript (and subtitles)
/// and the notes so far. It never takes focus from the meeting app, and stays out of screen
/// sharing unless the user allows it in Settings.
@MainActor
final class LiveMeetingWindow: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let recorder: AudioRecorder
    var onStop: (() -> Void)?
    var onOpenMeeting: (() -> Void)?

    init(recorder: AudioRecorder) {
        self.recorder = recorder
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let panel = self.panel ?? build()
        panel.sharingType = MeetingSettings.shareLiveWindow ? .readOnly : .none
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func build() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 560),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "会议实况"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = CGSize(width: 300, height: 320)
        panel.delegate = self
        let view = LiveMeetingView(recorder: recorder, live: recorder.live, session: recorder.session,
                                   onStop: { [weak self] in self?.onStop?() },
                                   onOpenMeeting: { [weak self] in self?.onOpenMeeting?() })
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(CGSize(width: 380, height: 560))
        if !panel.setFrameUsingName("aist.live") {
            // Right edge of the screen, out of the way of the meeting's video.
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(CGPoint(x: screen.maxX - 400, y: screen.maxY - 580))
            }
        }
        panel.setFrameAutosaveName("aist.live")
        self.panel = panel
        return panel
    }
}

// MARK: - Content

private struct LiveMeetingView: View {
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var live: LiveTranscript
    @ObservedObject var session: LiveMeeting
    let onStop: () -> Void
    let onOpenMeeting: () -> Void

    enum Tab: Hashable { case transcript, notes }
    @State private var tab: Tab = .transcript
    @AppStorage(MeetingSettings.translateToKey) private var translateTo = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if let pending = session.ending {
                EndingBanner(session: session, pending: pending)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            if live.translationNeedsDownload != nil {
                TranslationDownloadRow(live: live)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Picker("", selection: $tab) {
                Text("转写").tag(Tab.transcript)
                Text("速记").tag(Tab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            switch tab {
            case .transcript: LiveTranscriptList(live: live)
            case .notes: LiveNotesView(session: session, live: live)
            }
        }
        .frame(minWidth: 300, minHeight: 320)
        .onChange(of: translateTo) { live.setTranslation(MeetingSettings.translateTo) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if recorder.isRecording, let start = recorder.startedAt {
                PulsingDot()
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    Text(DueFormatter.duration(ctx.date.timeIntervalSince(start)))
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
            } else {
                Text("未在录音").foregroundStyle(.secondary)
            }
            if let langs = languageLine {
                Text(langs).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Picker("字幕翻译", selection: $translateTo) {
                    ForEach(LiveTranscript.translationChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("在主窗口中打开", action: onOpenMeeting)
            } label: {
                Image(systemName: "character.bubble")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("字幕翻译")
            if recorder.isRecording {
                Button("结束录音", action: onStop)
                    .help("结束录音，生成会议纪要")
            }
        }
    }

    private var languageLine: String? {
        let me = live.languages[.me], them = live.languages[.others]
        if let me, let them, me != them { return "我：\(me) · 对方：\(them)" }
        return them ?? me
    }
}

private struct EndingBanner: View {
    @ObservedObject var session: LiveMeeting
    let pending: MeetingEndWatch.Pending

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.down.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.endingTitle(pending)).fontWeight(.medium)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("\(max(0, Int(pending.deadline.timeIntervalSince(ctx.date)))) 秒后结束录音并生成纪要")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button("继续录音") { session.keepGoing() }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.orange.opacity(0.1)))
    }
}

/// Live translation needs the language pair on this Mac: one tap asks the system to download it.
private struct TranslationDownloadRow: View {
    @ObservedObject var live: LiveTranscript
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        HStack {
            Label("字幕翻译需要先下载语言", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
            Spacer()
            Button("下载") {
                guard let pair = live.translationNeedsDownload else { return }
                config = TranslationSession.Configuration(source: pair.source, target: pair.target)
            }
        }
        .font(.callout)
        .translationTask(config) { session in
            do {
                try await session.prepareTranslation()
                await MainActor.run { live.translationReady() }
            } catch {}
        }
    }
}

// MARK: - Transcript

/// Finished lines and the ones being spoken, newest at the bottom, following along unless the
/// user scrolled up to read.
struct LiveTranscriptList: View {
    @ObservedObject var live: LiveTranscript
    var compact = false

    private var lines: [TranscriptSegment] { live.shownLines }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 6 : 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        LiveLine(speaker: line.speaker, text: line.text, translation: line.translation,
                                 time: line.start, draft: false)
                    }
                    ForEach([TranscriptSegment.Speaker.others, .me], id: \.self) { s in
                        if let d = live.drafts[s], !d.isEmpty {
                            LiveLine(speaker: s, text: d, translation: nil, time: nil, draft: true)
                        }
                    }
                    if lines.isEmpty, live.drafts.isEmpty {
                        Text(live.status ?? (live.isRunning ? "正在听…" : "开始会议录音后，这里会实时显示转写"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else if let status = live.status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .textSelection(.enabled)
            }
            .onChange(of: lines.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: live.drafts) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct LiveLine: View {
    let speaker: TranscriptSegment.Speaker
    let text: String
    let translation: String?
    let time: Double?
    let draft: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker == .me ? "我" : "对方")
                .fontWeight(.medium)
                .foregroundStyle(speaker == .me ? Color.accentColor : .secondary)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(draft ? .secondary : .primary)
                if let translation, !translation.isEmpty {
                    Text(translation).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let time {
                Text(DueFormatter.duration(time)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Notes

struct LiveNotesView: View {
    @ObservedObject var session: LiveMeeting
    @ObservedObject var live: LiveTranscript

    var body: some View {
        let n = session.notes
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stateLine
                if !n.summary.isEmpty {
                    Text(n.summary)
                }
                items("我的待办", n.myTodos, symbol: "circle")
                items("别人的待办", n.othersTodos, symbol: "person")
                items("结论", n.decisions, symbol: "checkmark.seal")
                ForEach(n.topics, id: \.title) { topic in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.title).font(.headline)
                        ForEach(topic.points, id: \.self) { p in
                            Text("• " + p).foregroundStyle(.secondary)
                        }
                    }
                }
                if !n.terms.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("人名与术语").font(.headline)
                        ForEach(n.terms, id: \.name) { t in
                            Text(t.name).fontWeight(.medium)
                                + Text(t.heard.isEmpty ? "" : "（听成 \(t.heard.joined(separator: "、"))）").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private var stateLine: some View {
        switch session.notesState {
        case .off:
            Text("会中速记已关闭（设置 › 会议）。会议结束后仍会生成完整纪要。").foregroundStyle(.secondary)
        case .waiting:
            if session.notes.isEmpty {
                Text(live.lines.isEmpty ? "有人说话后，大约每 45 秒整理一次要点和待办。" : "很快会整理出第一版速记…")
                    .foregroundStyle(.secondary)
            } else if let at = session.notesUpdatedAt {
                HStack {
                    Text("\(at.formatted(date: .omitted, time: .shortened)) 更新").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("立即更新") { session.refreshNow() }.controlSize(.small)
                }
            }
        case .updating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在更新速记…").font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("重试") { session.refreshNow() }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private func items(_ title: String, _ list: [LiveNotes.Item], symbol: String) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                ForEach(list, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
                        if let who = item.who, !who.isEmpty {
                            Text(who).fontWeight(.medium)
                        }
                        Text(item.text)
                        Spacer(minLength: 0)
                        if let t = item.time {
                            Text(DueFormatter.duration(t)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}
