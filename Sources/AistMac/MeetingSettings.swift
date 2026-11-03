import Foundation

/// Meeting preferences (设置 › 会议), read where a meeting starts and runs.
enum MeetingSettings {
    static let languageKey = "meeting.language"
    static let translateToKey = "meeting.translateTo"
    static let liveNotesKey = "meeting.liveNotes"
    static let endOnHangUpKey = "meeting.endOnHangUp"
    static let silenceMinutesKey = "meeting.silenceMinutes"
    static let promptOnCallKey = "meeting.promptOnCall"
    static let showLiveWindowKey = "meeting.showLiveWindow"
    static let shareLiveWindowKey = "meeting.shareLiveWindow"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            languageKey: "auto",
            translateToKey: "",
            liveNotesKey: true,
            endOnHangUpKey: true,
            silenceMinutesKey: 10,
            promptOnCallKey: true,
            showLiveWindowKey: true,
            shareLiveWindowKey: false,
        ])
    }

    /// A BCP-47 locale, or "auto".
    static var language: String { UserDefaults.standard.string(forKey: languageKey) ?? "auto" }

    static var translateTo: Locale.Language? {
        let id = UserDefaults.standard.string(forKey: translateToKey) ?? ""
        return id.isEmpty ? nil : Locale.Language(identifier: id)
    }

    static var liveNotes: Bool { UserDefaults.standard.bool(forKey: liveNotesKey) }
    static var endOnHangUp: Bool { UserDefaults.standard.bool(forKey: endOnHangUpKey) }
    static var silenceMinutes: Int { UserDefaults.standard.integer(forKey: silenceMinutesKey) }
    static var promptOnCall: Bool { UserDefaults.standard.bool(forKey: promptOnCallKey) }
    static var showLiveWindow: Bool { UserDefaults.standard.bool(forKey: showLiveWindowKey) }
    static var shareLiveWindow: Bool { UserDefaults.standard.bool(forKey: shareLiveWindowKey) }
}
