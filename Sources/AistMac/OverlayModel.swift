import AppKit
import Combine
import SwiftUI

/// Shared UI state for the to-do panel and the menu-bar item.
@MainActor
final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case idle, capturing, analyzing }
    struct Note: Equatable {
        struct Target: Equatable {
            var pane: MainModel.Pane
            var id: UUID?
        }

        let id = UUID()
        let text: String
        let isError: Bool
        /// Tapping the note opens this in the main window.
        var target: Target?
    }

    @Published var phase: Phase = .idle
    /// To-dos added or updated by the latest capture, highlighted briefly.
    @Published var freshIDs: Set<UUID> = []
    /// The panel is unrolled under the menu-bar icon.
    @Published var isOpen = false
    /// Transient status line at the top of the panel ("这屏没有发现待办", errors).
    @Published var note: Note?
    /// A calendar meeting that just started: "record it?".
    @Published var meetingPrompt: CalEvent?
    /// What's on now / next today, from the calendar.
    @Published var nextEvent: CalEvent?

    /// The visible card's frame in the panel's (top-left origin) coordinates; for mouse pass-through.
    var contentFrame: CGRect = .zero

    var isBusy: Bool { phase != .idle }

    // One motion vocabulary for the whole panel.
    /// Unrolling: a soft spring that settles without overshooting the menu bar.
    static let openSpring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Rolling up: quick and decisive, never lingers.
    static let closeCurve = Animation.easeIn(duration: 0.14)
    /// Everything inside the panel: rows appearing, collapsing, expanding.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
}
