import AppKit
import ScreenCaptureKit

struct CaptureResult {
    let image: CGImage
    let frontApp: String?
    let windowTitle: String?
}

enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "找不到要截取的显示器" }
}

enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// `CGPreflightScreenCaptureAccess` caches a "no" for the life of the process, so after the user
    /// turns the switch on it keeps refusing until relaunch. ScreenCaptureKit reads the live state.
    static func checkPermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
    }


    /// Shows the system prompt the first time; afterwards the user must toggle it in System Settings.
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// Opens 录屏与系统录音 with the drag-Aist-into-the-list card beside it.
    @MainActor static func openPermissionSettings() {
        PermissionGuide.shared.show(pane: "Privacy_ScreenCapture", title: "录屏与系统录音") { await checkPermission() }
    }

    /// Captures the display under the mouse, leaving out aist's own windows (the island).
    static func captureDisplayUnderMouse() async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let me = getpid()
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.processID == me },
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        let scale = screen?.backingScaleFactor ?? 2
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // aist never activates, so the frontmost app is still whatever the user was looking at.
        let front = NSWorkspace.shared.frontmostApplication
        let title = content.windows.first {
            $0.owningApplication?.processID == front?.processIdentifier && $0.windowLayer == 0 && $0.isOnScreen
        }?.title
        return CaptureResult(image: image, frontApp: front?.localizedName, windowTitle: title)
    }
}
