import AppKit
import SwiftUI

/// The "drag the app into the list" helper many Mac apps show next to System Settings:
/// opens a privacy pane, then floats a small card under the Settings window with Aist's icon
/// as a drag source. Dropping it on the list is the same as dragging Aist.app in from Finder —
/// it also replaces a stale entry left by an older build signed differently.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()

    private var panel: NSPanel?
    private var model = GuideModel()
    private var follower: Timer?
    private var poller: Timer?
    private var lostSince: Date?
    private var openedAt = Date.distantPast

    /// - Parameters:
    ///   - pane: `Privacy_*` anchor of 隐私与安全性.
    ///   - isGranted: checked once a second; the card turns green and closes when it says yes.
    func show(pane: String, title: String, isGranted: @escaping @MainActor () async -> Bool) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
        model.title = title
        model.granted = false
        openedAt = .now
        lostSince = nil

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.alphaValue = 0 // shown once Settings' window is found
        panel.orderFrontRegardless()

        follower?.invalidate()
        follower = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.granted else { return }
                Task { @MainActor in
                    guard await isGranted(), !self.model.granted else { return }
                    withAnimation(.spring(duration: 0.3)) { self.model.granted = true }
                    try? await Task.sleep(for: .seconds(1.6))
                    self.close()
                }
            }
        }
    }

    func close() {
        follower?.invalidate()
        poller?.invalidate()
        follower = nil
        poller = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 84),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Non-activating, so System Settings stays frontmost and takes the drop.
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: GuideCard(model: model) { [weak self] in self?.close() })
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        return panel
    }

    /// Keeps the card centred under the Settings window (or just inside its bottom edge when
    /// there's no room below); closes when Settings goes away.
    private func follow() {
        guard let panel else { return }
        guard let frame = Self.settingsWindowFrame() else {
            // Settings takes a moment to launch; after that, losing its window means the user closed it.
            if Date.now.timeIntervalSince(openedAt) > 4 {
                if let lostSince, Date.now.timeIntervalSince(lostSince) > 0.6 { close() }
                else if lostSince == nil { lostSince = .now }
            }
            return
        }
        lostSince = nil
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 10)
        if origin.y < visible.minY { origin.y = frame.minY + 14 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if panel.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        }
    }

    /// Frame of System Settings' main window in AppKit coordinates. Window bounds and owner pid
    /// don't need screen-recording permission (only titles do).
    private static func settingsWindowFrame() -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let bounds = list.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 300, rect.height > 300 else { return nil }
            return rect
        }.first // front-to-back order: the frontmost Settings window
        guard let rect = bounds, let primary = NSScreen.screens.first else { return nil }
        // CoreGraphics: top-left origin on the primary display; AppKit: bottom-left.
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

@MainActor
private final class GuideModel: ObservableObject {
    @Published var title = ""
    @Published var granted = false
}

private struct GuideCard: View {
    @ObservedObject var model: GuideModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                AppDragSource()
                    .frame(width: 52, height: 52)
                    .opacity(model.granted ? 0.35 : 1)
                if model.granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white, .green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if model.granted {
                    Text("已允许\(model.title)").font(.headline)
                    Text("可以回到 Aist 继续了").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("把 Aist 拖到上面的列表里").font(.headline)
                    Text("列表里已有 Aist 也再拖一次，会换成现在这份。拖进去后确认开关是打开的。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 360, height: 84)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("关闭")
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// Aist's icon as a file drag of Aist.app itself — what System Settings expects from Finder.
private struct AppDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func draw(_ dirtyRect: NSRect) {
            icon.draw(in: bounds)
        }

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .link, .generic]
        }
    }
}
