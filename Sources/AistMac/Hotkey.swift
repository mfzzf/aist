import AppKit
import Carbon.HIToolbox

/// A user-customisable global shortcut, stored in UserDefaults.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags raw value (device-independent subset).
    var modifiers: UInt
    var keyLabel: String

    /// Temporary default until the user picks one. (⌃⌥Space is macOS's "next input source", so not that.)
    static let fallback = Hotkey(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
        keyLabel: "T"
    )

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String { Self.symbols(flags) + keyLabel }

    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// Since macOS 15 the system refuses hotkeys whose only modifiers are ⌥ and/or ⇧ (to stop keyloggers).
    var rejectionReason: String? {
        let mods = flags.intersection([.command, .option, .control, .shift])
        if !mods.isEmpty, mods.isSubset(of: [.option, .shift]) {
            return "macOS 不允许只用 ⌥/⇧ 的快捷键，请加上 ⌘ 或 ⌃"
        }
        return nil
    }

    init(keyCode: UInt32, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// Builds a hotkey from a key-down event; nil if it would hijack normal typing (no modifier, not an F-key).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys[code] != nil
        guard !mods.subtracting(.shift).isEmpty || isFunctionKey else { return nil }
        self.keyCode = UInt32(code)
        self.modifiers = mods.rawValue
        self.keyLabel = Self.specialNames[code] ?? Self.functionKeys[code]
            ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    private static let specialNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_KeypadEnter: "⌤",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Registers one system-wide hotkey via Carbon's RegisterEventHotKey —
/// the native API that needs no Accessibility permission.
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    private static let defaultsKey = "hotkey"

    var current: Hotkey {
        get {
            UserDefaults.standard.data(forKey: Self.defaultsKey)
                .flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .fallback
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.defaultsKey)
            register()
        }
    }

    /// Returns false if another app already owns the combination.
    @discardableResult
    func register() -> Bool {
        unregister()
        installHandler()
        let hk = current
        let id = EventHotKeyID(signature: OSType(0x4149_5354), id: 1) // 'AIST'
        let status = RegisterEventHotKey(hk.keyCode, hk.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotkeyManager.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
