import AistCore
import AppKit
import SwiftUI

// Pieces shared by the menu-bar panel and the main window.

/// Quiet palette: rows are neutral; color only marks time pressure, and muted at that.
enum Style {
    /// A color that adapts to light/dark appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }

    /// Muted brick red: overdue, recording, destructive.
    static let overdue = adaptive(light: 0xB5534A, dark: 0xD98A80)
    /// Muted amber: due today.
    static let today = adaptive(light: 0x9A6B22, dark: 0xD2AA66)
    static let flag = adaptive(light: 0xC07A6E, dark: 0xC9938A)
    static let ok = adaptive(light: 0x4E8A5A, dark: 0x8CC499)

    static func isUrgent(_ due: Date?) -> Bool {
        guard let due else { return false }
        return due < .now || Calendar.current.isDateInToday(due)
    }

    static func due(_ due: Date?) -> Color {
        guard let due else { return .secondary }
        if due < .now { return overdue }
        if Calendar.current.isDateInToday(due) { return today }
        return .secondary
    }
}

enum Haptics {
    static func thud() { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
}

enum DueFormatter {
    private static let zh = Locale(identifier: "zh_CN")

    /// "今天 15:00" / "明天 15:00" / "周四 15:00" / "11月8日"; past deadlines get "已过期".
    static func string(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let cal = Calendar.current
        if date < now, !cal.isDateInToday(date) { return "已过期" }
        if cal.isDateInToday(date) { return "今天 \(time(date))" }
        if cal.isDateInTomorrow(date) { return "明天 \(time(date))" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 99
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated).locale(zh)) + " \(time(date))" }
        return date.formatted(.dateTime.month().day().locale(zh))
    }

    /// Past moments: "今天 22:41" / "昨天 09:10" / "10月28日 14:02".
    static func stamp(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天 \(time(date))" }
        if cal.isDateInYesterday(date) { return "昨天 \(time(date))" }
        return date.formatted(.dateTime.month().day().locale(zh)) + " \(time(date))"
    }

    /// "11月1日 周日 14:02".
    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(zh)) + " \(time(date))"
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// "5:21" / "1:02:03".
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "32 分钟" / "不到 1 分钟" / "1 小时 5 分钟".
    static func minutes(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return "不到 1 分钟" }
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分钟" : "\(m) 分钟"
    }

    /// "今天" / "昨天" / "本周" / "更早", for grouping past things.
    static func bucket(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        return now.timeIntervalSince(date) < 7 * 86400 ? "本周" : "更早"
    }

    /// Where an open to-do falls by deadline.
    static func dueBucket(_ item: TodoItem, now: Date = .now) -> String {
        if item.pinned == true { return "置顶" }
        guard let due = item.dueAt else { return "无期限" }
        let cal = Calendar.current
        if due < now { return "已过期" }
        if cal.isDateInToday(due) { return "今天" }
        if cal.isDateInTomorrow(due) { return "明天" }
        return due.timeIntervalSince(now) < 7 * 86400 ? "本周" : "以后"
    }

    static let dueBucketOrder = ["置顶", "已过期", "今天", "明天", "本周", "以后", "无期限"]
    static let pastBucketOrder = ["今天", "昨天", "本周", "更早"]
}

/// Neutral circle that fills with the accent color and draws a checkmark when ticked.
struct CheckButton: View {
    let checked: Bool
    var size: CGFloat = 17
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(checked ? 0 : (hovered ? 0.7 : 0.45)), lineWidth: 1.3)
                Circle().fill(Color.accentColor).scaleEffect(checked ? 1 : 0.01)
                CheckmarkShape()
                    .trim(from: 0, to: checked ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .padding(size * 0.26)
                    .animation(.easeOut(duration: 0.22).delay(checked ? 0.08 : 0), value: checked)
                if hovered, !checked {
                    CheckmarkShape()
                        .stroke(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        .padding(size * 0.26)
                }
            }
            .frame(width: size, height: size)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: checked)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(checked ? "恢复为待办" : "完成")
    }
}

struct CheckmarkShape: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.55))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.82))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.9, y: r.minY + r.height * 0.22))
        }
    }
}

struct PulsingDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Style.overdue)
            .frame(width: size, height: size)
            .phaseAnimator([1.0, 0.35]) { dot, phase in dot.opacity(phase) } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.primary.opacity(hovered ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
        .help(help)
    }
}

struct QuoteBox: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.04))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.35)).frame(width: 2.5).padding(.vertical, 8).padding(.leading, 4)
                    }
            }
    }
}

extension View {
    /// Liquid Glass on macOS 26+, the system material before that.
    @ViewBuilder func panelBackground(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
