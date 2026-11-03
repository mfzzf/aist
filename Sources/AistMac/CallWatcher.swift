import AppKit
import CoreAudio

// Adapted from Cicada (知了, https://github.com/wquguru/cicada, Apache-2.0): MicUsers.swift.

/// Which meeting apps are in a call right now, seen from outside: Core Audio lists every process
/// reading a microphone (macOS 14.2+). A meeting app taking the mic is a call starting (→ "要录这场会
/// 吗？"); letting go of it is hanging up (→ the recording can end).
@MainActor
final class CallWatcher {
    /// Dedicated meeting apps. Browsers aren't counted: their mic use doesn't say a meeting started.
    static let meetingApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.tencent.meeting": "腾讯会议", "com.tencent.WeWorkMac": "企业微信",
        // 企业微信's meetings run in their own app (企业微信·会议), not in the main one.
        "com.tencent.wwmapp": "企业微信会议",
        "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams", "com.electron.lark": "飞书",
        "com.bytedance.lark": "飞书", "com.alibaba.DingTalkMac": "钉钉", "Cisco-Systems.Spark": "Webex",
        "com.tinyspeck.slackmacgap": "Slack", "com.apple.FaceTime": "FaceTime", "net.whatsapp.WhatsApp": "WhatsApp",
        "com.tencent.xinWeChat": "微信",
    ]

    /// Every poll: meeting apps reading a microphone now (bundle id → name).
    var onPoll: (([String: String]) -> Void)?
    /// A meeting app just started a call.
    var onCallStarted: ((_ bundleID: String, _ name: String) -> Void)?

    private var timer: Timer?
    /// When each app started reading the mic, and the ones already announced.
    private var since: [String: Date] = [:]
    private var announced: Set<String> = []
    /// A voice message or a quick mic test isn't a call: announce after this long.
    private let settle: TimeInterval = 12

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        let calls = Self.currentCalls()
        let now = Date()
        since = since.filter { calls[$0.key] != nil }
        announced.formIntersection(calls.keys)
        for (id, name) in calls {
            let start = since[id] ?? now
            since[id] = start
            if !announced.contains(id), now.timeIntervalSince(start) >= settle {
                announced.insert(id)
                onCallStarted?(id, name)
            }
        }
        onPoll?(calls)
    }

    static func currentCalls() -> [String: String] {
        var running: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, let name = meetingApps[id] else { continue }
            running[id] = app.localizedName ?? name
        }
        guard !running.isEmpty else { return [:] }
        let ids = Set(running.keys)
        var out: [String: String] = [:]
        for bundleID in readers() {
            if let app = owner(of: bundleID, running: ids) { out[app] = running[app] }
        }
        return out
    }

    /// The app a process belongs to: Electron and Chromium apps capture audio in helper processes
    /// ("com.tencent.meeting.helper"), so walk up the bundle id until it names a running app.
    static func owner(of bundleID: String, running: Set<String>) -> String? {
        var parts = bundleID.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            let id = parts.joined(separator: ".")
            if running.contains(id) { return id }
            parts.removeLast()
        }
        return nil
    }

    /// Bundle ids of the processes that have audio input running.
    static func readers() -> [String] {
        objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { process in
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr, running != 0 else { return nil }
            return string(process, kAudioProcessPropertyBundleID)
        }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return s
    }

    private static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
