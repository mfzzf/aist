import AppKit

// Menu-bar agent (LSUIElement): no Dock icon, never steals focus from the app being captured.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
