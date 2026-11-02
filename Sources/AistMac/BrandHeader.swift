import AppKit
import SwiftUI

/// Aist's colors, sampled from the app icon (sky blue → lavender).
enum AistBrand {
    static let blue = Color(red: 0.25, green: 0.62, blue: 0.97)
    static let violet = Color(red: 0.58, green: 0.47, blue: 0.96)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .leading, endPoint: .trailing)
}

/// Top of the sidebar: the mascot and wordmark, today's date, and a small card with what's next.
struct BrandHeader: View {
    /// Where a sidebar row's selection highlight starts; the card shares its edges.
    static let rowInset: CGFloat = 10
    /// Padding inside the card; the mascot row uses it too, so everything sits on one line.
    static let inner: CGFloat = 10

    let openCount: Int
    let urgentCount: Int
    let nextEvent: CalEvent?
    var onOpenEvent: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 46, height: 46)
                    .shadow(color: AistBrand.violet.opacity(0.3), radius: 6, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aist")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(AistBrand.gradient)
                    Text(greeting)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.inner - 3) // the icon's artwork has ~3pt of transparent margin

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    stat(openCount, "待办", color: AistBrand.blue)
                    stat(urgentCount, "紧急", color: urgentCount > 0 ? .orange : .secondary)
                }
                Divider().opacity(0.6)
                Button { onOpenEvent?() } label: { next }
                    .buttonStyle(.plain)
                    .disabled(nextEvent == nil)
            }
            .padding(Self.inner)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [AistBrand.blue.opacity(0.10), AistBrand.violet.opacity(0.10)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AistBrand.violet.opacity(0.18), lineWidth: 0.5)
            )
        }
    }

    private func stat(_ value: Int, _ label: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(value)")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var next: some View {
        if let e = nextEvent {
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(e.color)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.when(e))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(e.start <= .now ? .orange : .secondary)
                    Text(e.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        } else {
            Label("接下来没有日程", systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func when(_ e: CalEvent) -> String {
        let cal = Calendar.current
        let time = e.start.formatted(date: .omitted, time: .shortened)
        if e.start <= .now { return "进行中 · 至 \(e.end.formatted(date: .omitted, time: .shortened))" }
        let minutes = Int(e.start.timeIntervalSinceNow / 60)
        if minutes < 60 { return "\(max(minutes, 1)) 分钟后 · \(time)" }
        if cal.isDateInToday(e.start) { return "今天 \(time)" }
        if cal.isDateInTomorrow(e.start) { return "明天 \(time)" }
        return e.start.formatted(.dateTime.month().day().weekday(.abbreviated)) + " " + time
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let hello = switch hour {
        case 5 ..< 11: "早上好"
        case 11 ..< 13: "中午好"
        case 13 ..< 18: "下午好"
        default: "晚上好"
        }
        return hello + "，" + Date.now.formatted(.dateTime.weekday(.wide))
    }
}

/// Empty detail pane with the mascot instead of a gray glyph.
struct BrandEmptyState: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .opacity(0.9)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
