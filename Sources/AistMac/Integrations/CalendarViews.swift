import AistCore
import AppKit
import SwiftUI

// MARK: - Event list

/// The next two weeks from every calendar set up in Calendar.app, grouped by day.
struct CalendarListColumn: View {
    @ObservedObject var model: MainModel
    @ObservedObject var calendar: CalendarCenter
    @ObservedObject var meetings: MeetingStore
    /// Only one source (the 企业微信 pane), or everything.
    var source: CalSource?

    private var q: String { model.query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var filtered: [CalEvent] {
        let all = calendar.events.filter { $0.end > Calendar.current.startOfDay(for: .now) && (source == nil || $0.source == source) }
        guard !q.isEmpty else { return all }
        return all.filter { e in
            ([e.title, e.location ?? "", e.notes ?? ""] + e.attendees).contains { $0.lowercased().contains(q) }
        }
    }

    private var days: [(Date, [CalEvent])] {
        let grouped = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: max($0.start, Calendar.current.startOfDay(for: .now))) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }) }
    }

    var body: some View {
        List(selection: $model.calendarSelection) {
            if source == nil, !calendar.authorized, !filtered.isEmpty {
                Button { Task { await calendar.requestAccess() } } label: {
                    Label("同时显示「日历」App 里的日程…", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.link)
            }
            ForEach(days, id: \.0) { day, events in
                Section(Self.dayTitle(day)) {
                    ForEach(events) { e in
                        EventRow(event: e, recorded: meetings.meetings.contains { $0.calendarEventID == e.id })
                            .tag(e.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if source == nil, !calendar.authorized, filtered.isEmpty {
                ContentUnavailableView {
                    Label("连接日历", systemImage: "calendar")
                } description: {
                    Text("读取「日历」App 里的所有账户（iCloud、Google、Exchange…），\n会议开始时提醒你录音，纪要自动带上会议名和参会人。")
                } actions: {
                    Button("允许访问日历") { Task { await calendar.requestAccess() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if filtered.isEmpty {
                if !q.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    ContentUnavailableView("近两周没有日程", systemImage: source == .wecom ? "bubble.left.and.bubble.right" : "calendar")
                }
            }
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        let weekday = day.formatted(.dateTime.weekday(.wide))
        if cal.isDateInToday(day) { return "今天 · \(weekday)" }
        if cal.isDateInTomorrow(day) { return "明天 · \(weekday)" }
        return day.formatted(.dateTime.month().day().weekday(.wide))
    }
}

private struct EventRow: View {
    let event: CalEvent
    let recorded: Bool

    private var isNow: Bool { event.start <= .now && event.end > .now }
    private var isPast: Bool { event.end <= .now }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(event.color)
                .frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .lineLimit(2)
                    .foregroundStyle(isPast ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(event.isAllDay ? "全天" : "\(DueFormatter.time(event.start)) – \(DueFormatter.time(event.end))")
                        .monospacedDigit()
                    if let place = event.location, event.joinURL == nil {
                        Text(place).lineLimit(1)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if recorded {
                Image(systemName: "waveform").foregroundStyle(.secondary).help("已录音")
            } else if isNow {
                Text("进行中").font(.caption.weight(.medium)).foregroundStyle(.red)
            } else if event.isMeeting {
                Image(systemName: event.joinURL != nil ? "video" : "person.2")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Event detail

struct EventDetail: View {
    /// 853 8561 1721
    static func grouped(_ code: String) -> String {
        guard code.count > 6 else { return code }
        var out = String(code.prefix(3))
        var rest = code.dropFirst(3)
        while !rest.isEmpty {
            out += " " + rest.prefix(4)
            rest = rest.dropFirst(4)
        }
        return out
    }

    let event: CalEvent
    @ObservedObject var model: MainModel
    @ObservedObject var calendar: CalendarCenter
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var recorder: AudioRecorder
    let actions: MainActions

    private var recordings: [Meeting] {
        meetings.sorted.filter { $0.calendarEventID == event.id }
    }

    private var when: String {
        let day = event.start.formatted(.dateTime.month().day().weekday(.wide))
        if event.isAllDay { return "\(day) 全天" }
        return "\(day) \(DueFormatter.time(event.start)) – \(DueFormatter.time(event.end))"
    }

    var body: some View {
        Form {
            Section {
                Text(event.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                LabeledContent("时间", value: when)
                if let place = event.location {
                    LabeledContent(event.room == place ? "会议室" : "地点") { Text(place).textSelection(.enabled) }
                }
                if let code = event.meetingCode {
                    LabeledContent("会议号") {
                        HStack(spacing: 8) {
                            Text(Self.grouped(code)).monospacedDigit().textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("拷贝会议号")
                        }
                    }
                }
                LabeledContent("日历") {
                    HStack(spacing: 6) {
                        if event.source == .wecom {
                            BrandIcon(image: BrandMark.wecom, size: 13).foregroundStyle(BrandColor.wecom)
                        } else {
                            Circle().fill(event.color).frame(width: 8, height: 8)
                        }
                        Text(event.calendarTitle)
                    }
                }
                if let organizer = event.organizer {
                    LabeledContent("组织者", value: organizer)
                }
            }

            if !event.attendees.isEmpty {
                Section("参会人（\(event.attendees.count)）") {
                    ForEach(event.attendees, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }

            Section("会议录音") {
                ForEach(recordings) { m in
                    Button {
                        model.pane = .meetings
                        model.selection = m.id
                    } label: {
                        LabeledContent(m.title, value: DueFormatter.long(m.startedAt))
                    }
                    .buttonStyle(.plain)
                }
                if recorder.isRecording {
                    Text(recordings.contains { $0.status == .recording } ? "正在录这场会议" : "正在录另一场会议")
                        .foregroundStyle(.secondary)
                } else if !event.isAllDay {
                    Button { actions.recordEvent(event) } label: {
                        Label("开始会议录音", systemImage: "mic")
                    }
                }
            }

            if let notes = event.notes {
                Section("备注") {
                    Text(notes).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                if let url = event.joinURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("加入会议", systemImage: "video")
                    }
                    .help(event.joinsInTencentMeeting ? "用腾讯会议按会议号加入" : "打开会议链接")
                } else if event.source == .wecom, let code = event.meetingCode {
                    // No 腾讯会议 to join with: the number on the clipboard, 企业微信's 日程 open.
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        calendar.reveal(event)
                    } label: {
                        Label("加入会议", systemImage: "video")
                    }
                    .help("拷贝会议号并打开企业微信日程")
                }
                Button { calendar.reveal(event) } label: {
                    if event.source == .wecom {
                        Label { Text("在企业微信中打开") } icon: { Image.wecom }
                    } else {
                        Label("在日历中打开", systemImage: "calendar")
                    }
                }
                .help(event.source == .wecom ? "打开企业微信的日程页" : "在「日历」App 中打开")
            }
        }
    }
}
