import AppKit
import SwiftUI

/// 企业微信, through the official `wecom-cli`. Authorizing is a QR scan: aist runs
/// `wecom-cli auth init --noninteractive --output-qrcode …` and shows the code in a sheet.
@MainActor
final class WeComCenter: ObservableObject {
    enum Status: Equatable { case checking, notInstalled, installing, unauthorized, authorized }
    enum Scan: Equatable {
        case idle
        case fetching
        case waiting(qr: NSImage?, link: URL?)
        case failed(String)
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var scan: Scan = .idle
    @Published var connecting = false
    @Published private(set) var installError: String?
    /// The next two weeks of 企业微信 schedules, as calendar events.
    @Published private(set) var schedules: [CalEvent] = []
    @Published private(set) var lastError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?

    private var process: Process?
    private var qrFile: URL?
    private var log = ""
    private var timer: Timer?

    init() {
        Task { await check() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refreshSchedules() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.refreshSchedules() } }
        }
    }

    /// aist's own copy (installed from the sheet), then the native binary inside an npm install,
    /// then the npm shims. GUI apps don't get the shell's PATH, so these are spelled out.
    nonisolated static var ownBinary: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("aist/bin/wecom-cli")
    }

    nonisolated static var cliPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let arch = Self.arch
        var candidates = [ownBinary.path]
        for prefix in ["/opt/homebrew/lib", "/usr/local/lib", "\(home)/.npm-global/lib"] {
            candidates.append("\(prefix)/node_modules/@wecom/cli/node_modules/@wecom/cli-darwin-\(arch)/bin/wecom-cli")
        }
        candidates += ["/opt/homebrew/bin/wecom-cli", "/usr/local/bin/wecom-cli",
                       "\(home)/.npm-global/bin/wecom-cli", "\(home)/.local/bin/wecom-cli"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    // MARK: Install

    /// Downloads the official native binary (`@wecom/cli-darwin-<arch>` on npm) into aist's folder:
    /// no Node.js needed. npmmirror first (fast in mainland China), then npmjs.
    func install() async {
        status = .installing
        installError = nil
        let package = "@wecom/cli-darwin-\(Self.arch)"
        var lastError = "网络不可用"
        for registry in ["https://registry.npmmirror.com", "https://registry.npmjs.org"] {
            do {
                try await Self.download(package: package, from: registry)
                await check()
                if status == .unauthorized { startScan() }
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        installError = "安装失败：\(lastError)"
        status = .notInstalled
    }

    private nonisolated static func download(package: String, from registry: String) async throws {
        struct Meta: Decodable {
            struct Dist: Decodable { var tarball: String }
            var version: String
            var dist: Dist
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        let (metaData, _) = try await session.data(from: URL(string: "\(registry)/\(package)/latest")!)
        let meta = try JSONDecoder().decode(Meta.self, from: metaData)
        guard let tarURL = URL(string: meta.dist.tarball) else { throw URLError(.badURL) }
        let (tgz, response) = try await session.download(from: tarURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("aist-wecom-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tgz.path, "-C", work.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }

        let found = fm.enumerator(at: work, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "wecom-cli" }
        guard let found else { throw CocoaError(.fileNoSuchFile) }
        let dest = ownBinary
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: found, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["NO_COLOR"] = "1"
        return env
    }

    func check() async {
        guard let path = Self.cliPath else {
            status = .notInstalled
            return
        }
        let output = await Task.detached { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "show"]
            p.environment = Self.environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
        guard let output else {
            status = .notInstalled
            return
        }
        status = output.localizedCaseInsensitiveContains("unauthorized") || output.contains("未授权") ? .unauthorized : .authorized
        if status == .authorized { await refreshSchedules() }
    }

    // MARK: Calling the CLI

    /// `wecom-cli <args…> --json '<body>'`; the CLI answers in JSON on stdout, errors included.
    func call(_ args: [String], body: [String: Any] = [:]) async throws -> [String: Any] {
        guard let path = Self.cliPath else { throw WeComError.notInstalled }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let data = await Task.detached { () -> Data in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args + ["--json", json]
            p.environment = Self.environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return Data() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return data
        }.value
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw WeComError.failed(text.isEmpty ? "wecom-cli 没有返回内容" : String(text.prefix(200)))
        }
        if let code = object["errcode"] as? Int, code != 0 {
            let message = object["errmsg"] as? String ?? "错误 \(code)"
            if message.localizedCaseInsensitiveContains("auth") || message.contains("授权") {
                status = .unauthorized
            }
            throw WeComError.failed(message.components(separatedBy: ", hint").first ?? message)
        }
        return object
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Every 2 minutes, on wake, and from the 刷新 button (⌘R) on the 日程 / 企业微信 pages.
    func refreshSchedules() async {
        guard status == .authorized, !refreshing else { return }
        refreshing = true
        defer { refreshing = false; lastRefresh = .now }
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 14, to: start)!
        do {
            let rsp = try await call(["calendar", "schedules", "list"], body: [
                "begin_time": Self.timeFormat.string(from: start),
                "end_time": Self.timeFormat.string(from: end),
            ])
            let list = rsp["schedule_list"] as? [[String: Any]] ?? []
            schedules = list.compactMap(Self.event).sorted { $0.start < $1.start }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func event(_ s: [String: Any]) -> CalEvent? {
        guard let id = s["schedule_id"] as? String,
              let begin = (s["begin_time"] as? String).flatMap(timeFormat.date(from:)) else { return nil }
        let end = (s["end_time"] as? String).flatMap(timeFormat.date(from:)) ?? begin.addingTimeInterval(3600)
        let attendees = (s["attendees"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let meeting = s["meeting"] as? [String: Any]
        let room = (s["meeting_room"] as? [String: Any])?["meeting_room_name"] as? String
        return CalEvent(
            eventID: id,
            title: (s["subject"] as? String)?.nonEmpty ?? "（无标题）",
            start: begin,
            end: end,
            isAllDay: s["is_all_day"] as? Bool ?? false,
            location: (s["location"] as? String)?.nonEmpty ?? room,
            notes: (s["description"] as? String)?.nonEmpty,
            url: (meeting?["meeting_link"] as? String).flatMap(URL.init(string:)),
            attendees: attendees,
            organizer: s["creator_name"] as? String,
            calendarTitle: (s["calendar_name"] as? String)?.nonEmpty ?? "企业微信",
            color: BrandColor.wecom,
            source: .wecom,
            meetingCode: meeting?["meeting_code"] as? String,
            room: room
        )
    }

    // MARK: QR sign-in

    func startScan() {
        guard let path = Self.cliPath else {
            status = .notInstalled
            return
        }
        cancelScan()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aist-wecom-\(UUID().uuidString).png")
        qrFile = file
        scan = .fetching

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["auth", "init", "--noninteractive", "--no-browser", "--output-qrcode", file.path]
        p.environment = Self.environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice

        log = ""
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.log += chunk
                self.parse(self.log)
            }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in
                out.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                await self.finished(code: code, killed: reason == .uncaughtSignal, log: self.log)
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            scan = .failed("没能运行 wecom-cli：\(error.localizedDescription)")
        }
    }

    /// Picks up the link and the PNG as soon as the CLI prints them.
    private func parse(_ log: String) {
        guard process != nil else { return }
        let link = log.split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("https://work.weixin.qq.com/") }
            .flatMap { URL(string: String($0)) }
        var qr: NSImage?
        if let qrFile, log.contains("二维码已保存") || FileManager.default.fileExists(atPath: qrFile.path) {
            qr = NSImage(contentsOf: qrFile)
        }
        if link != nil || qr != nil {
            let next = Scan.waiting(qr: qr, link: link)
            if next != scan { scan = next }
        }
    }

    private func finished(code: Int32, killed: Bool, log: String) async {
        process = nil
        if let qrFile { try? FileManager.default.removeItem(at: qrFile) }
        if killed { return } // cancelled
        await check()
        if status == .authorized {
            scan = .idle
            connecting = false
        } else {
            let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("█") && !$0.contains("▀") && !$0.contains("▄") }
            scan = .failed(lines.last.map { "授权没有完成：\($0)" } ?? "授权没有完成（退出码 \(code)）")
        }
    }

    func cancelScan() {
        process?.terminate()
        process = nil
        if case .failed = scan { } else { scan = .idle }
    }
}

enum WeComError: LocalizedError {
    case notInstalled, failed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: "没有安装 wecom-cli"
        case let .failed(message): "企业微信：\(message)"
        }
    }
}

// MARK: - Sidebar row

struct WeComSidebarRow: View {
    @ObservedObject var wecom: WeComCenter

    var body: some View {
        switch wecom.status {
        case .authorized:
            // No fixed color: like the other sidebar icons it takes the accent, and turns white when selected.
            Label { Text("企业微信") } icon: { BrandIcon(image: BrandMark.wecom, size: 17) }
                .badge(wecom.schedules.filter { Calendar.current.isDateInToday($0.start) && $0.end > .now }.count)
                .tag(MainModel.Pane.wecom)
                .contextMenu {
                    Button("刷新日程") { Task { await wecom.refreshSchedules() } }
                    Button("重新扫码授权") { wecom.connecting = true }
                }
        case .checking:
            EmptyView()
        case .notInstalled, .installing, .unauthorized:
            Button { wecom.connecting = true } label: {
                Label { Text("连接企业微信…") } icon: { BrandIcon(image: BrandMark.wecom, size: 17) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Connect sheet

struct ConnectWeComView: View {
    @ObservedObject var wecom: WeComCenter
    @Environment(\.dismiss) private var dismiss

    static let brand = BrandColor.wecom

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                ConnectHeader(icon: .wecom, tint: Self.brand,
                              title: "连接企业微信",
                              subtitle: "用企业微信扫码授权，Aist 就能读取你的日程和会议，会议开始时提醒你录音。")
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    wecom.cancelScan()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if wecom.status == .authorized {
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.default, value: wecom.scan)
        .animation(.default, value: wecom.status)
        .task {
            await wecom.check()
            // Not installed: install right away (the user already asked to connect).
            if wecom.status == .notInstalled { await wecom.install() }
            else if wecom.status == .unauthorized { wecom.startScan() }
        }
        .onDisappear { wecom.cancelScan() }
    }

    @ViewBuilder private var content: some View {
        switch wecom.status {
        case .checking:
            ProgressView().frame(height: 240)
        case .notInstalled, .installing:
            install
        case .authorized where wecom.scan == .idle:
            Label("已连接企业微信", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.headline)
                .frame(height: 60)
        default:
            scanArea
        }
    }

    @ViewBuilder private var scanArea: some View {
        switch wecom.scan {
        case .idle, .fetching:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在获取二维码…").foregroundStyle(.secondary)
            }
            .frame(width: 220, height: 220)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
            steps
        case let .waiting(qr, link):
            VStack(spacing: 10) {
                Group {
                    if let qr {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 220, height: 220)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))

                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("等待扫码…").foregroundStyle(.secondary)
                }
                .font(.callout)
                if let link {
                    Link("在浏览器中打开二维码", destination: link).font(.callout)
                }
            }
            steps
        case let .failed(message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新获取二维码") { wecom.startScan() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(minHeight: 120)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            step(1, "打开手机上的企业微信")
            step(2, "点右上角「＋」›「扫一扫」，扫描上面的二维码")
            step(3, "在手机上确认授权，这里会自动完成")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Self.brand))
            Text(text).foregroundStyle(.secondary)
        }
    }

    /// One click: aist fetches Tencent's official build itself (no Node.js, no Terminal).
    private var install: some View {
        VStack(spacing: 12) {
            Text("需要企业微信官方的 wecom-cli 工具（约 10 MB）。Aist 可以帮你下载安装，不需要用终端。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if wecom.status == .installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在下载 wecom-cli…").foregroundStyle(.secondary)
                }
                .frame(height: 32)
            } else {
                Button { Task { await wecom.install() } } label: {
                    Text("安装 wecom-cli").frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if let error = wecom.installError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("来源：腾讯官方 npm 包 @wecom/cli", destination: URL(string: "https://www.npmjs.com/package/@wecom/cli")!)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
