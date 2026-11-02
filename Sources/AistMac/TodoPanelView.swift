import AistCore
import AppKit
import SwiftUI

/// What the panel asks its owner to do.
struct PanelActions {
    var capture: () -> Void
    var startMeeting: () -> Void
    var stopMeeting: () -> Void
    /// Open the main window, optionally at one to-do or meeting.
    var openMain: (MainModel.Pane?, UUID?) -> Void
    /// Record a calendar meeting (named after the event).
    var recordEvent: (CalEvent) -> Void
}

/// The glance under the menu-bar icon: what's open, tick it off, start a meeting.
/// Anything more (notes, editing, minutes, history) lives in the main window — a row tap goes there.
///
/// Motion, in one vocabulary (see `OverlayModel`):
/// - Open: a roller blind. A mask unrolls from the top edge while the card settles down 8pt into place;
///   rows follow 22ms apart. Close: everything lifts and fades in 0.14s, no stagger.
/// - Complete: the circle fills, a checkmark draws itself, the title is struck through; then the row
///   fades and the rows below close the gap.
struct TodoPanelView: View {
    static let width: CGFloat = 340
    static let maxListHeight: CGFloat = 420
    static let radius: CGFloat = 18

    @ObservedObject var model: OverlayModel
    @ObservedObject var store: TodoStore
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var recorder: AudioRecorder
    let actions: PanelActions

    /// Rows ticked, showing the checkmark land before they leave.
    @State private var flipping: Set<UUID> = []
    @State private var listHeight: CGFloat = 0

    private var open: Bool { model.isOpen }
    private var items: [TodoItem] { store.openItems }
    private var processing: [Meeting] { meetings.sorted.filter(\.isProcessing) }

    var body: some View {
        card
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.contentFrame = $0 }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            if recorder.isRecording, let start = recorder.startedAt {
                RecordingBar(startedAt: start, onStop: actions.stopMeeting)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ForEach(processing) { m in
                ProcessingBar(meeting: m) { actions.openMain(.meetings, m.id) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let event = model.meetingPrompt, !recorder.isRecording {
                MeetingPromptBar(event: event, onRecord: {
                    model.meetingPrompt = nil
                    actions.recordEvent(event)
                }, onDismiss: { model.meetingPrompt = nil })
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let event = model.nextEvent, !recorder.isRecording {
                NextEventRow(event: event) { actions.openMain(.calendar, nil) }
                    .staggered(open, index: 0)
            }
            if let note = model.note {
                NoteBanner(note: note) {
                    if let target = note.target { actions.openMain(target.pane, target.id) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            list
            footer
        }
        .frame(width: Self.width)
        .panelBackground(radius: Self.radius)
        // Roller blind: the mask unrolls from the top edge.
        .mask(alignment: .top) {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .scaleEffect(x: 1, y: open ? 1 : 0.02, anchor: .top)
        }
        .shadow(color: .black.opacity(open ? 0.12 : 0), radius: 3, y: 2)
        .shadow(color: .black.opacity(open ? 0.18 : 0), radius: 28, y: 18)
        .offset(y: open ? 0 : -8)
        .opacity(open ? 1 : 0)
        .animation(open ? OverlayModel.openSpring : OverlayModel.closeCurve, value: open)
        .animation(OverlayModel.spring, value: items.map(\.id))
        .animation(OverlayModel.spring, value: processing.map(\.id))
        .animation(OverlayModel.spring, value: model.note)
        .animation(OverlayModel.spring, value: recorder.isRecording)
        .animation(OverlayModel.spring, value: model.meetingPrompt)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("待办").font(.system(size: 14, weight: .semibold))
                Text("\(items.count)")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.leading, 6)
            Spacer(minLength: 4)
            if model.isBusy {
                ProgressView().controlSize(.small).frame(width: 26, height: 26)
                    .help("读屏中…")
                    .transition(.opacity)
            } else {
                IconButton(symbol: "text.viewfinder", help: "截屏分析（\(HotkeyManager.shared.current.display)）",
                           action: actions.capture)
                    .transition(.opacity)
            }
            if !recorder.isRecording {
                IconButton(symbol: "mic", help: "开始会议录音（麦克风 + 系统声音）", action: actions.startMeeting)
                    .transition(.opacity)
            }
            IconButton(symbol: "macwindow", help: "打开 Aist 主窗口") { actions.openMain(nil, nil) }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .animation(OverlayModel.spring, value: model.isBusy)
        .animation(OverlayModel.spring, value: recorder.isRecording)
        .staggered(open, index: 0)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    emptyState.staggered(open, index: 1)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PanelRow(
                        item: item,
                        checked: flipping.contains(item.id),
                        fresh: model.freshIDs.contains(item.id),
                        onCheck: { complete(item) },
                        onOpen: { actions.openMain(.todos, item.id) }
                    )
                    .staggered(open, index: index + 1)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .leading))
                    ))
                }
            }
            .padding(.bottom, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        }
        .frame(height: min(listHeight, Self.maxListHeight))
        .scrollDisabled(listHeight <= Self.maxListHeight)
    }

    /// Show the checkmark land first, then let the row go to history.
    private func complete(_ item: TodoItem) {
        guard !flipping.contains(item.id) else { return }
        Haptics.thud()
        _ = flipping.insert(item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(OverlayModel.spring) {
                store.setDone(item.id, true)
                flipping.remove(item.id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
            Text("没有待办").font(.system(size: 13, weight: .medium))
            Text("按 \(HotkeyManager.shared.current.display) 截屏，AI 帮你找出待办")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
    }

    // MARK: Footer

    private var footer: some View {
        Button { actions.openMain(nil, nil) } label: {
            HStack(spacing: 6) {
                Text("打开 Aist")
                Spacer()
                Text("会议 \(meetings.meetings.count) · 已完成 \(store.doneItems.count)")
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
        .staggered(open, index: min(items.count + 1, 14))
    }
}

// MARK: - Row

private struct PanelRow: View {
    let item: TodoItem
    let checked: Bool
    let fresh: Bool
    let onCheck: () -> Void
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckButton(checked: checked, action: onCheck)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? .secondary : .primary)
                    .lineLimit(1)
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovered ? 1 : 0)
                .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fresh ? Color.accentColor.opacity(0.16) : .primary.opacity(hovered ? 0.06 : 0))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
        .help("在主窗口中查看")
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if item.pinned == true {
                Image(systemName: "pin.fill").font(.system(size: 8.5))
            }
            if item.priority == .high {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Style.flag)
            }
            if let due = DueFormatter.string(item.dueAt) ?? item.dueText {
                Text(due)
                    .fontWeight(Style.isUrgent(item.dueAt) ? .medium : .regular)
                    .foregroundStyle(Style.due(item.dueAt))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let who = item.requester, !who.isEmpty {
                Text(who).lineLimit(1)
            }
            if item.meetingID != nil {
                Image(systemName: "waveform").font(.system(size: 9))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Bars

/// Across the top of the panel while a meeting is being recorded.
private struct RecordingBar: View {
    let startedAt: Date
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text("会议录音中")
                .font(.system(size: 12, weight: .medium))
            TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                Text(DueFormatter.duration(ctx.date.timeIntervalSince(startedAt)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            Button(action: onStop) {
                Text("结束")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Capsule().fill(Style.overdue.opacity(0.16)))
                    .foregroundStyle(Style.overdue)
            }
            .buttonStyle(.plain)
            .help("结束录音，生成会议纪要")
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Style.overdue.opacity(0.07)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

private struct ProcessingBar: View {
    let meeting: Meeting
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(meeting.status == .transcribing ? "正在转写会议录音…" : "正在生成会议纪要…")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(DueFormatter.minutes(meeting.duration))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// "「周会」开始了" with a record button; the calendar title becomes the meeting's title.
private struct MeetingPromptBar: View {
    let event: CalEvent
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(event.start > .now ? "\(DueFormatter.time(event.start)) 开始" : "已开始 · 要录音吗？")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let url = event.joinURL {
                Button("加入") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
            Button(action: onRecord) {
                Label("录音", systemImage: "mic.fill")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("不录")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// One quiet line: the next calendar event today.
private struct NextEventRow: View {
    let event: CalEvent
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Circle().fill(event.color).frame(width: 7, height: 7)
                Text(event.start <= .now ? "进行中" : DueFormatter.time(event.start))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(event.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NoteBanner: View {
    let note: OverlayModel.Note
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: note.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(note.isError ? Style.overdue : Style.ok)
            Text(note.text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if note.target != nil {
                Text("查看").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill((note.isError ? Style.overdue : Style.ok).opacity(0.1)))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { if note.target != nil { onTap() } }
    }
}

private extension View {
    /// Rows follow the panel down one after another; on close they all leave together, fast.
    func staggered(_ open: Bool, index: Int) -> some View {
        opacity(open ? 1 : 0)
            .offset(y: open ? 0 : -6)
            .animation(open ? OverlayModel.openSpring.delay(0.05 + Double(min(index, 14)) * 0.022)
                            : .easeIn(duration: 0.1),
                       value: open)
    }
}
