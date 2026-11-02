import AppKit
import CryptoKit
import Foundation
import Security

/// Updates from GitHub Releases (github.com/mfzzf/aist): checks the latest release, downloads its DMG,
/// checks the new app is signed by the same Developer ID team, swaps it in and relaunches.
///
/// The feed is a `latest.json` attached to each release, read through
/// `releases/latest/download/…` — a redirect to GitHub's download CDN, not the REST API, so it isn't
/// subject to the API's 60-requests-an-hour-per-IP limit (offices behind one NAT). The API is the
/// fallback for releases without the file. The DMG must match the manifest's SHA-256, and the app in it
/// must be signed by our Developer ID team — a DMG that isn't ours is refused.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "mfzzf/aist"
    private static let autoKey = "update.autoCheck"
    private static let skipKey = "update.skippedVersion"
    private static let lastCheckKey = "update.lastCheck"
    /// The bundle identifier and Developer ID team an update must carry.
    private static let bundleID = "com.jianfengmei.aist"
    private static let teamID = "7MNRRP3W76"

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL
        var size: Int
        /// Hex SHA-256 of the DMG, when the release has a manifest.
        var sha256: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoKey) }
    }

    @Published private(set) var lastCheck: Date?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var timer: Timer?
    /// Versions already offered this session, so a periodic check doesn't nag.
    private var offered: Set<String> = []

    private init() {
        UserDefaults.standard.register(defaults: [Self.autoKey: true])
        autoCheck = UserDefaults.standard.bool(forKey: Self.autoKey)
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    /// Checks shortly after launch, then every 6 hours, while automatic checks are on.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.autoTick() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoTick() }
        }
    }

    private func autoTick() {
        guard autoCheck else { return }
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 6 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: Check

    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            lastCheck = .now
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            guard let release, Self.isNewer(release.version, than: currentVersion) else {
                state = .upToDate
                if userInitiated { alertUpToDate() }
                return
            }
            state = .available(release)
            let skipped = UserDefaults.standard.string(forKey: Self.skipKey) == release.version
            if userInitiated || (!skipped && !offered.contains(release.version)) {
                offered.insert(release.version)
                offer(release)
            }
        } catch UpdateError.rateLimited where !userInitiated {
            // Shared IP used up the API quota; nothing is wrong, try again at the next check.
            state = .idle
            lastCheck = .now
            UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
        } catch {
            state = .failed(error.localizedDescription)
            if userInitiated { alertFailure(error.localizedDescription) }
        }
    }

    private static func fetchLatest() async throws -> Release? {
        if let release = try? await fetchManifest() { return release }
        return try await fetchFromAPI()
    }

    /// `latest.json` from the latest release, e.g.
    /// `{"version":"0.2.2","notes":"…","dmg":"https://…/Aist-0.2.2.dmg","size":123,"sha256":"…","page":"https://…"}`.
    private static func fetchManifest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest/download/latest.json")!)
        request.setValue("Aist", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.malformed }
        struct Manifest: Decodable {
            var version: String
            var notes: String?
            var dmg: URL
            var size: Int?
            var sha256: String?
            var page: URL?
        }
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        let version = m.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return Release(version: version, notes: m.notes ?? "",
                       page: m.page ?? URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")!,
                       dmg: m.dmg, size: m.size ?? 0, sha256: m.sha256?.lowercased())
    }

    private static func fetchFromAPI() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Aist", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil } // no releases yet
        if status == 429 || (status == 403 && (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "x-ratelimit-remaining") == "0") { throw UpdateError.rateLimited }
        guard status == 200 else { throw UpdateError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let url = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError.malformed }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                       notes: json["body"] as? String ?? "",
                       page: page, dmg: url, size: dmg["size"] as? Int ?? 0)
    }

    /// "0.10.0" > "0.9.3"; missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Prompts

    private func offer(_ release: Release) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Aist \(release.version) 可以更新了"
        var info = "当前版本 \(currentVersion)。"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(900)) + (notes.count > 900 ? "…" : "") }
        alert.informativeText = info
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "安装并重新打开")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(release) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skipKey)
        default:
            break
        }
    }

    private func alertUpToDate() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "Aist \(currentVersion) 是目前最新的版本。"
        alert.icon = NSApp.applicationIconImage
        alert.runModal()
    }

    private func alertFailure(_ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "没能完成更新"
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "前往下载页")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
        }
    }

    // MARK: Install

    func install(_ release: Release) async {
        let target = Bundle.main.bundleURL
        // Can't replace ourselves (e.g. installed by another admin user): send them to the download page.
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: target.path)
        else {
            state = .available(release)
            alertFailure("没有权限替换 \(target.path)。请从下载页手动安装新版本。")
            return
        }
        do {
            state = .downloading(0)
            let dmg = try await download(release.dmg, expected: release.size, sha256: release.sha256)
            state = .installing
            let staged = try await Task.detached { try Self.extractApp(from: dmg) }.value
            try Self.verify(staged)
            try relaunch(replacing: target, with: staged)
        } catch {
            state = .failed(error.localizedDescription)
            alertFailure(error.localizedDescription)
        }
    }

    private func download(_ url: URL, expected: Int, sha256: String?) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let total = max(expected, Int(response.expectedContentLength))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Aist-update-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written = 0
        var hasher = SHA256()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                hasher.update(data: buffer)
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { state = .downloading(Double(written) / Double(total)) }
            }
        }
        hasher.update(data: buffer)
        try handle.write(contentsOf: buffer)
        if let sha256 {
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else {
                try? FileManager.default.removeItem(at: dest)
                throw UpdateError.checksum
            }
        }
        return dest
    }

    /// Mounts the DMG read-only, copies the app out, unmounts.
    private nonisolated static func extractApp(from dmg: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Aist-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dmg) }
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, "-quiet"])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
        guard let name = try fm.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.noApp
        }
        let staged = work.appendingPathComponent(name)
        try run("/usr/bin/ditto", [mount.appendingPathComponent(name).path, staged.path])
        return staged
    }

    /// The new app must be intact and signed with our Developer ID, for our bundle identifier.
    private static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.badSignature
        }
        let text = """
        anchor apple generic and identifier "\(bundleID)" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(teamID)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw UpdateError.badSignature
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError.badSignature
        }
    }

    /// A small script waits for us to quit, swaps the bundles (keeping the old one until the copy succeeds),
    /// and opens the new version.
    private func relaunch(replacing target: URL, with staged: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let backup = target.deletingLastPathComponent().appendingPathComponent(".Aist-old-\(UUID().uuidString).app")
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        if /bin/mv \(q(target.path)) \(q(backup.path)); then
          if /usr/bin/ditto \(q(staged.path)) \(q(target.path)); then
            /bin/rm -rf \(q(backup.path))
          else
            /bin/rm -rf \(q(target.path)); /bin/mv \(q(backup.path)) \(q(target.path))
          fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine \(q(target.path)) 2>/dev/null
        /bin/rm -rf \(q(staged.deletingLastPathComponent().path))
        /usr/bin/open \(q(target.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.tool((tool as NSString).lastPathComponent) }
        return p.terminationStatus
    }

    enum UpdateError: LocalizedError {
        case http(Int)
        case malformed
        case noApp
        case badSignature
        case checksum
        case rateLimited
        case tool(String)

        var errorDescription: String? {
            switch self {
            case let .http(code): "连接 GitHub 失败（HTTP \(code)）"
            case .malformed: "GitHub 上的最新版本没有可用的安装包"
            case .noApp: "安装包里没有找到 Aist"
            case .badSignature: "安装包的签名校验没有通过，已放弃安装"
            case .checksum: "下载的安装包不完整或被改动过（SHA-256 不符），已放弃安装"
            case .rateLimited: "GitHub 暂时限制了这个网络的访问次数，过一会儿再试"
            case let .tool(name): "解开安装包失败（\(name)）"
            }
        }
    }
}
