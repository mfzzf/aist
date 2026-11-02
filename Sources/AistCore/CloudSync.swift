import CloudKit
import Combine
import Foundation
#if os(macOS)
import Security
#endif

/// Mirrors the to-do list to the user's private iCloud database, so the Mac and the iPhone share it.
///
/// One record per to-do (type `Todo`, record name = the to-do's UUID) in a custom zone `Todos`,
/// holding the item as JSON plus `updatedAt`. Changes come down through the zone's change token
/// (and a silent push when one arrives); local edits go up as they happen. When both sides edited the
/// same to-do, the newer `updatedAt` wins. What hasn't been uploaded yet is kept on disk, so edits made
/// offline go up later.
///
/// Built on plain CKDatabase calls rather than CKSyncEngine, which needs iOS 17.
@MainActor
public final class CloudSync: ObservableObject {
    public nonisolated static let containerID = "iCloud.com.mfzzf.aist"

    public enum Status: Equatable, Sendable {
        /// Sync can't run here (not configured, no iCloud account); the reason is user-facing.
        case off(String)
        case idle
        case syncing
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var lastSync: Date?

    public var isEnabled: Bool { container != nil }

    private let store: TodoStore
    private let container: CKContainer?
    private let zoneID = CKRecordZone.ID(zoneName: "Todos", ownerName: CKCurrentUserDefaultName)
    private static let recordType = "Todo"
    private static let subscriptionID = "todo-changes"

    private var state: State
    private let stateURL: URL
    private var running = false
    private var again = false
    private var pushDebounce: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?

    struct State: Codable {
        var userRecordName: String?
        var zoneReady = false
        var subscribed = false
        var token: Data?
        /// Archived CKRecord system fields (change tag) per record name, for conflict-safe saves.
        var systemFields: [String: Data] = [:]
        var pendingSave: Set<UUID> = []
        var pendingDelete: Set<UUID> = []
        /// The first full download has been merged with what was already on this device.
        var merged = false
    }

    enum SyncError: Error { case noAccount(CKAccountStatus) }

    /// `container` is nil when this build isn't signed for iCloud: sync stays off and says why.
    public init(store: TodoStore, containerID: String = CloudSync.containerID) {
        self.store = store
        stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aist/cloud-sync.json")
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        container = Self.hasEntitlement(containerID) ? CKContainer(identifier: containerID) : nil
        guard container != nil else {
            status = .off("这个版本没有开启 iCloud")
            return
        }
        lastSync = UserDefaults.standard.object(forKey: "cloud.lastSync") as? Date
        store.onLocalChange = { [weak self] changed, deleted in
            self?.localChanged(changed, deleted)
        }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    /// Whether the running app carries the iCloud entitlement for `containerID`. CloudKit traps without it.
    public static func hasEntitlement(_ containerID: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) == true
        #else
        // iOS has no public entitlement lookup: the target sets AistCloudKit when it's signed for iCloud.
        if ProcessInfo.processInfo.arguments.contains("-noCloud") { return false }
        return Bundle.main.object(forInfoDictionaryKey: "AistCloudKit") as? Bool == true
        #endif
    }

    /// Short line for Settings: 「已同步 · 3 分钟前」「正在同步…」「没有登录 iCloud」…
    public var statusText: String {
        switch status {
        case let .off(reason): return reason
        case .syncing: return "正在同步…"
        case let .failed(message): return message
        case .idle:
            guard let lastSync else { return "等待第一次同步" }
            let f = RelativeDateTimeFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.unitsStyle = .short
            return Date.now.timeIntervalSince(lastSync) < 60 ? "已同步 · 刚刚" : "已同步 · \(f.localizedString(for: lastSync, relativeTo: .now))"
        }
    }

    // MARK: Triggers

    /// Pull, then push. Safe to call often (launch, foreground, a push arrived, a timer).
    public func sync() {
        guard container != nil else { return }
        Task { await run() }
    }

    /// For a silent push: completes once the changes are in.
    public func syncNow() async {
        guard container != nil else { return }
        await run()
    }

    private func localChanged(_ changed: Set<UUID>, _ deleted: Set<UUID>) {
        state.pendingSave.formUnion(changed)
        state.pendingSave.subtract(deleted)
        state.pendingDelete.formUnion(deleted)
        saveState()
        // Typing in a title saves on every keystroke; send once the edits settle.
        pushDebounce?.cancel()
        pushDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    // MARK: Run

    private func run() async {
        guard let container else { return }
        if running { again = true; return }
        running = true
        defer { running = false }
        var attempts = 0
        repeat {
            again = false
            attempts += 1
            status = .syncing
            do {
                try await prepare(container)
                try await fetch(container.privateCloudDatabase)
                try await push(container.privateCloudDatabase)
                lastSync = .now
                UserDefaults.standard.set(lastSync, forKey: "cloud.lastSync")
                status = .idle
            } catch {
                handle(error)
                if again, attempts > 3 { again = false }
            }
        } while again
    }

    private func handle(_ error: Error) {
        if case let SyncError.noAccount(account) = error {
            status = .off(account == .noAccount ? "没有登录 iCloud" : "iCloud 暂时不可用")
            return
        }
        guard let ck = error as? CKError else {
            status = .failed(error.localizedDescription)
            return
        }
        switch ck.code {
        case .notAuthenticated:
            status = .off("没有登录 iCloud")
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            status = .failed("网络不通，稍后自动重试")
        case .quotaExceeded:
            status = .failed("iCloud 存储空间已满")
        case .zoneNotFound, .userDeletedZone:
            // The zone was removed (another device reset iCloud data): start over, re-upload everything.
            state = State(userRecordName: state.userRecordName)
            saveState()
            again = true
        default:
            status = .failed("同步出错：\(ck.localizedDescription)")
        }
    }

    // MARK: Steps

    private func prepare(_ container: CKContainer) async throws {
        let account = try await container.accountStatus()
        guard account == .available else { throw SyncError.noAccount(account) }
        let user = try await container.userRecordID().recordName
        if state.userRecordName != user {
            // First run, or a different iCloud account: everything here goes up to that account.
            state = State(userRecordName: user)
            saveState()
        }
        let db = container.privateCloudDatabase
        if !state.zoneReady {
            let (saved, _) = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            if case let .failure(error) = saved[zoneID] { throw error }
            state.zoneReady = true
            saveState()
        }
        if !state.subscribed {
            let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true // silent: wakes the app, shows nothing
            subscription.notificationInfo = info
            _ = try await db.save(subscription)
            state.subscribed = true
            saveState()
        }
    }

    private func fetch(_ db: CKDatabase) async throws {
        var token = state.token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var upserts: [UUID: TodoItem] = [:]
        var deletions = Set<UUID>()
        var onServer = Set<UUID>()
        while true {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion],
                          changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                state.merged = false
                continue
            }
            for (recordID, result) in changes.modificationResultsByID {
                guard case let .success(modification) = result,
                      let id = UUID(uuidString: recordID.recordName),
                      let remote = Self.decode(modification.record) else { continue }
                state.systemFields[recordID.recordName] = Self.systemFields(of: modification.record)
                onServer.insert(id)
                if state.pendingDelete.contains(id) { continue }
                if state.pendingSave.contains(id),
                   let local = store.items.first(where: { $0.id == id }), local.updatedAt > remote.updatedAt {
                    continue // our newer edit goes up in push()
                }
                state.pendingSave.remove(id)
                upserts[id] = remote
                deletions.remove(id)
            }
            for deletion in changes.deletions {
                guard let id = UUID(uuidString: deletion.recordID.recordName) else { continue }
                state.systemFields[deletion.recordID.recordName] = nil
                state.pendingSave.remove(id)
                state.pendingDelete.remove(id)
                upserts[id] = nil
                deletions.insert(id)
            }
            token = changes.changeToken
            if !changes.moreComing { break }
        }
        store.applyRemote(upserts: Array(upserts.values), deletions: deletions)
        state.token = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        if !state.merged {
            // First download: whatever only this device has goes up.
            state.pendingSave.formUnion(store.items.map(\.id).filter { !onServer.contains($0) && state.systemFields[$0.uuidString] == nil })
            state.merged = true
        }
        saveState()
    }

    private func push(_ db: CKDatabase) async throws {
        for _ in 0 ..< 3 {
            let byID = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            state.pendingSave = state.pendingSave.filter { byID[$0] != nil }
            let toSave = state.pendingSave.compactMap { byID[$0] }
            let toDelete = Array(state.pendingDelete)
            guard !toSave.isEmpty || !toDelete.isEmpty else { return }

            var retry = false
            for start in stride(from: 0, to: max(toSave.count, toDelete.count), by: 200) {
                let saves = Array(toSave[min(start, toSave.count) ..< min(start + 200, toSave.count)])
                let deletes = Array(toDelete[min(start, toDelete.count) ..< min(start + 200, toDelete.count)])
                let sent = Dictionary(saves.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
                let (saveResults, deleteResults) = try await db.modifyRecords(
                    saving: saves.map(record(for:)),
                    deleting: deletes.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) },
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: false
                )
                for (recordID, result) in saveResults {
                    guard let id = UUID(uuidString: recordID.recordName) else { continue }
                    switch result {
                    case let .success(saved):
                        state.systemFields[recordID.recordName] = Self.systemFields(of: saved)
                        // Edited again while uploading? Then it stays pending for the next round.
                        if let now = store.items.first(where: { $0.id == id })?.updatedAt, let was = sent[id], now <= was {
                            state.pendingSave.remove(id)
                        }
                    case let .failure(error as CKError) where error.code == .serverRecordChanged:
                        guard let server = error.serverRecord else { retry = true; continue }
                        state.systemFields[recordID.recordName] = Self.systemFields(of: server)
                        if let remote = Self.decode(server), let local = byID[id], remote.updatedAt >= local.updatedAt {
                            store.applyRemote(upserts: [remote], deletions: [])
                            state.pendingSave.remove(id)
                        } else {
                            retry = true // ours is newer: save again on top of the server's version
                        }
                    case let .failure(error as CKError) where error.code == .unknownItem:
                        state.systemFields[recordID.recordName] = nil // gone on the server: create it fresh
                        retry = true
                    case let .failure(error):
                        throw error
                    }
                }
                for (recordID, result) in deleteResults {
                    guard let id = UUID(uuidString: recordID.recordName) else { continue }
                    switch result {
                    case .success:
                        break
                    case let .failure(error as CKError) where error.code == .unknownItem:
                        break
                    case let .failure(error):
                        throw error
                    }
                    state.pendingDelete.remove(id)
                    state.systemFields[recordID.recordName] = nil
                }
                saveState()
            }
            if !retry { return }
        }
    }

    // MARK: Records

    private func record(for item: TodoItem) -> CKRecord {
        let name = item.id.uuidString
        let record = state.systemFields[name].flatMap(Self.restore)
            ?? CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        record["json"] = (try? Self.encoder.encode(item)).map { String(decoding: $0, as: UTF8.self) } as CKRecordValue?
        record["updatedAt"] = item.updatedAt as CKRecordValue
        return record
    }

    private static func decode(_ record: CKRecord) -> TodoItem? {
        guard let json = record["json"] as? String else { return nil }
        return try? decoder.decode(TodoItem.self, from: Data(json.utf8))
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func restore(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    private func saveState() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    // Same date format as todos.json, so an item round-trips unchanged.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
