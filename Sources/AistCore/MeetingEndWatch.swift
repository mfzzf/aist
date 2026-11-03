import Foundation

// Adapted from Cicada (知了, https://github.com/wquguru/cicada, Apache-2.0): MeetingEnd.swift.

/// Decides when a recorded meeting is over, so one nobody stopped doesn't run on for hours.
///
/// Two signals. The main one: a meeting app (Zoom, 腾讯会议…) that was reading a microphone during
/// the meeting lets go of it, which is what hanging up looks like from outside; a short grace
/// covers switching devices. The fallback, for meetings in a browser or in the room: nothing was
/// recognised for a while. It counts words, not sound, so background music doesn't keep a meeting
/// alive. While a meeting app is still in a call, silence doesn't count: muted webinars are still
/// meetings. Pure; the app ticks it.
public struct MeetingEndWatch: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var followApps = true
        /// 0 = never end on silence.
        public var silenceAfter: TimeInterval = 600
        /// How long the "没人说话" prompt waits before ending.
        public var countdown: TimeInterval = 60
        /// How long after a hang-up before ending: a device switch drops the mic for a moment.
        public var appGrace: TimeInterval = 30

        public init(followApps: Bool = true, silenceAfter: TimeInterval = 600) {
            self.followApps = followApps
            self.silenceAfter = silenceAfter
        }
    }

    public enum Reason: Equatable, Sendable {
        /// The meeting app (by name) hung up.
        case appLeft(String)
        case silence
        /// Nobody spoke at all: there is nothing to keep.
        case nobodySpoke
    }

    public struct Pending: Equatable, Sendable {
        public var reason: Reason
        public var deadline: Date
    }

    public var config: Config
    /// The meeting ends at `deadline` unless someone keeps it going.
    public private(set) var pending: Pending?
    public private(set) var lastSpeech: Date
    /// Meeting apps seen in a call during this meeting (bundle id → name).
    public private(set) var inCall: [String: String] = [:]

    public init(config: Config, start: Date) {
        self.config = config
        lastSpeech = start
    }

    /// Words were recognised: a silence countdown stops. A hang-up doesn't.
    public mutating func heard(at now: Date) {
        lastSpeech = now
        if pending?.reason == .silence { pending = nil }
    }

    /// "继续录音": forget the hang-up and start counting silence again.
    public mutating func keepGoing(at now: Date) {
        pending = nil
        lastSpeech = now
        inCall = [:]
    }

    /// `calls`: meeting apps reading a microphone now. `said`: the meeting has lines.
    /// Returns why the meeting ends now, if it does.
    public mutating func tick(at now: Date, calls: [String: String], said: Bool) -> Reason? {
        let silenceOn = config.silenceAfter > 0
        guard said else {
            inCall = config.followApps ? calls : [:]
            pending = nil
            let inACall = config.followApps && !calls.isEmpty
            if silenceOn, !inACall, now.timeIntervalSince(lastSpeech) >= config.silenceAfter { return .nobodySpoke }
            return nil
        }
        if config.followApps {
            for (id, name) in calls { inCall[id] = name }
            let hungUp = !inCall.isEmpty && inCall.keys.allSatisfy { calls[$0] == nil }
            if case .appLeft = pending?.reason, !hungUp { pending = nil } // rejoined
            if hungUp, pending == nil || pending?.reason == .silence {
                let name = inCall.sorted { $0.key < $1.key }.first?.value ?? ""
                pending = Pending(reason: .appLeft(name), deadline: now.addingTimeInterval(config.appGrace))
            }
        } else if case .appLeft = pending?.reason {
            pending = nil
        }
        let inACall = config.followApps && !calls.isEmpty
        if pending == nil, silenceOn, !inACall, now.timeIntervalSince(lastSpeech) >= config.silenceAfter {
            pending = Pending(reason: .silence, deadline: now.addingTimeInterval(config.countdown))
        }
        if !silenceOn || inACall, pending?.reason == .silence { pending = nil }
        if let p = pending, now >= p.deadline {
            pending = nil
            return p.reason
        }
        return nil
    }
}
