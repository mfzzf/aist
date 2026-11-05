import AistCore
import AppKit
import SwiftUI

/// Borderless panel that never activates aist.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit pushes windows below the menu bar; the panel must hang right under it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the to-do panel that unrolls under the menu-bar icon.
///
/// The window is a fixed transparent canvas; SwiftUI animates the card inside it, so opening and
/// closing never resize the window (which would stutter). Only the card receives the mouse.
/// Opened by a click it stays until a click elsewhere or Esc; opened by itself (new to-dos, a
/// deadline coming up) it rolls back up a few seconds after the mouse leaves it.
@MainActor
final class PanelController {
    let model = OverlayModel()
    /// The menu-bar icon's frame in screen coordinates.
    var anchorFrame: () -> CGRect? = { nil }
    var onCapture: (() -> Void)?
    var onStartMeeting: (() -> Void)?
    var onStopMeeting: (() -> Void)?
    var onShowLive: (() -> Void)?
    var onOpenMain: ((MainModel.Pane?, UUID?) -> Void)?
    var onRecordEvent: ((CalEvent) -> Void)?

    private let store: TodoStore
    private let panel: OverlayPanel
    private var monitors: [Any] = []
    private var closeWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var autoOpened = false

    /// Card width plus room for its shadow.
    private static let canvas = CGSize(width: TodoPanelView.width + 48, height: 680)

    let voice: VoiceNote

    init(store: TodoStore, meetings: MeetingStore, recorder: AudioRecorder, voice: VoiceNote) {
        self.store = store
        self.voice = voice
        panel = OverlayPanel(
            contentRect: CGRect(origin: .zero, size: Self.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        let root = TodoPanelView(
            model: model, store: store, meetings: meetings, recorder: recorder, voice: voice,
            actions: PanelActions(
                capture: { [weak self] in self?.onCapture?() },
                voice: { [weak self] in self?.voice.hotkeyPressed() },
                startMeeting: { [weak self] in self?.onStartMeeting?() },
                stopMeeting: { [weak self] in self?.onStopMeeting?() },
                showLive: { [weak self] in self?.onShowLive?() },
                openMain: { [weak self] pane, id in
                    self?.close()
                    self?.onOpenMain?(pane, id)
                },
                recordEvent: { [weak self] event in self?.onRecordEvent?(event) }
            )
        )
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host

        let moved: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.mouseMoved() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { moved($0); return $0 }) {
            monitors.append(m)
        }
        // Global clicks land in other apps, i.e. outside the panel.
        // Clicks on our own menu bar icon can arrive here too (the menu bar is drawn by the system);
        // leave those to toggle(), or the panel would close on mouse-down and reopen on mouse-up.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isOpen else { return }
                if let icon = self.anchorFrame(), icon.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { return }
                self.close()
                self.closedByOutsideClick = .now
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53, let self, self.model.isOpen else { return e } // Esc
            MainActor.assumeIsolated {
                // Esc while listening drops what was said; the panel stays for the next try.
                if self.voice.phase == .listening { self.voice.cancel() } else { self.close() }
            }
            return nil
        }) { monitors.append(m) }
    }

    // MARK: Placement

    /// Card's left edge lines up with the icon, like a native menu-bar extra; kept on screen.
    private func position() {
        let icon = anchorFrame()
        let screen = icon.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let inset = (Self.canvas.width - TodoPanelView.width) / 2
        let cardX = min(max((icon?.minX ?? visible.maxX) - 8, visible.minX + 8),
                        visible.maxX - TodoPanelView.width - 8)
        let top = visible.maxY - 4
        panel.setFrame(CGRect(x: cardX - inset, y: top - Self.canvas.height,
                              width: Self.canvas.width, height: Self.canvas.height), display: false)
    }

    // MARK: Open / close

    var isOpen: Bool { model.isOpen }

    func open(autoClose seconds: Double? = nil) {
        hideWork?.cancel()
        if !model.isOpen {
            position()
            panel.orderFrontRegardless()
            withAnimation(OverlayModel.openSpring) { model.isOpen = true }
            autoOpened = seconds != nil
        }
        if let seconds, autoOpened {
            scheduleClose(after: seconds)
        } else {
            autoOpened = false
            closeWork?.cancel()
            panel.makeKey() // for search and Esc; non-activating, so the user's app stays active
        }
    }

    func close() {
        guard model.isOpen else { return }
        closeWork?.cancel()
        autoOpened = false
        withAnimation(OverlayModel.closeCurve) { model.isOpen = false }
        panel.ignoresMouseEvents = true
        let hide = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isOpen else { return }
                self.panel.orderOut(nil)
            }
        }
        hideWork = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: hide)
    }

    /// When an outside click last closed the panel — a click on the icon that closed it shouldn't reopen it.
    private var closedByOutsideClick: Date?

    func toggle() {
        if !model.isOpen, let t = closedByOutsideClick, Date.now.timeIntervalSince(t) < 0.5 { return }
        model.isOpen && !autoOpened ? close() : open()
    }

    private func scheduleClose(after seconds: Double) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.isOpen, self.autoOpened else { return }
                if self.mouseNear { self.scheduleClose(after: 1.5) } else { self.close() }
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Mouse

    private var localMouse: CGPoint {
        let p = NSEvent.mouseLocation, f = panel.frame
        return CGPoint(x: p.x - f.minX, y: f.maxY - p.y)
    }

    private var mouseNear: Bool { model.contentFrame.insetBy(dx: -30, dy: -30).contains(localMouse) }

    private func mouseMoved() {
        guard model.isOpen else { return }
        panel.ignoresMouseEvents = !model.contentFrame.insetBy(dx: -2, dy: -2).contains(localMouse)
        if autoOpened, mouseNear { scheduleClose(after: 2) }
    }

    // MARK: Results & messages

    func showResults(_ ids: Set<UUID>) {
        withAnimation(OverlayModel.spring) { model.freshIDs = ids }
        open(autoClose: 6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            withAnimation(.easeOut(duration: 0.8)) { self?.model.freshIDs = [] }
        }
    }

    func show(message: String, isError: Bool, for seconds: Double = 4, target: OverlayModel.Note.Target? = nil) {
        let note = OverlayModel.Note(text: message, isError: isError, target: target)
        withAnimation(OverlayModel.spring) { model.note = note }
        open(autoClose: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard self?.model.note == note else { return }
            withAnimation(OverlayModel.spring) { self?.model.note = nil }
        }
    }
}
