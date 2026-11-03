import AistCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A message being written.
struct ComposeDraft {
    var account: UUID
    var to = ""
    var cc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var references: [String] = []
    var attachments: [MailAttachment] = []

    static func new(from account: UUID) -> ComposeDraft { ComposeDraft(account: account) }

    static func reply(to header: MailHeader, body: MailBody, account: UUID, myAddress: String, all: Bool) -> ComposeDraft {
        var draft = ComposeDraft(account: account)
        let me = myAddress.lowercased()
        draft.to = header.replyTo ?? header.fromAddress
        if all {
            let others = (MailFormat.addresses(header.to.joined(separator: ",")) + MailFormat.addresses(header.cc.joined(separator: ",")))
                .filter { $0.lowercased() != me && $0.lowercased() != draft.to.lowercased() }
            draft.cc = Array(NSOrderedSet(array: others)).compactMap { $0 as? String }.joined(separator: ", ")
        }
        draft.subject = header.subject.lowercased().hasPrefix("re:") ? header.subject : "Re: \(header.subject)"
        draft.body = "\n\n在 \(MailFormat.long(header.date))，\(header.sender) <\(header.fromAddress)> 写道：\n"
            + quote(body.plainText)
        draft.inReplyTo = header.messageID
        draft.references = header.references + [header.messageID].compactMap { $0 }
        return draft
    }

    static func forward(_ header: MailHeader, body: MailBody, account: UUID) -> ComposeDraft {
        var draft = ComposeDraft(account: account)
        draft.subject = header.subject.lowercased().hasPrefix("fwd:") ? header.subject : "Fwd: \(header.subject)"
        draft.body = """


        ---------- 转发的邮件 ----------
        发件人：\(header.sender) <\(header.fromAddress)>
        日期：\(MailFormat.long(header.date))
        主题：\(header.subject)
        收件人：\(header.to.joined(separator: ", "))

        \(body.plainText)
        """
        draft.attachments = body.attachments
        return draft
    }

    private static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }
}

/// One window per message being written, like Mail.
@MainActor
final class ComposeWindows: NSObject, NSWindowDelegate {
    private let mail: MailCenter
    private var windows: [NSWindow] = []

    init(mail: MailCenter) { self.mail = mail }

    func open(_ draft: ComposeDraft) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        let host = NSHostingController(rootView: ComposeView(draft: draft, mail: mail) { [weak window] in
            window?.close()
        })
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(CGSize(width: 640, height: 560))
        window.center()
        if let last = windows.last { window.setFrameTopLeftPoint(CGPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24)) }
        windows.append(window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as? NSWindow }
    }
}

struct ComposeView: View {
    @State var draft: ComposeDraft
    @ObservedObject var mail: MailCenter
    let close: () -> Void

    @State private var sending = false
    @State private var error: String?
    @State private var picking = false
    @State private var dropping = false
    @FocusState private var focus: Field?

    private enum Field { case to, cc, subject }

    private var recipients: [String] { MailFormat.addresses(draft.to) }

    var body: some View {
        VStack(spacing: 0) {
            row("收件人") { TextField("", text: $draft.to).focused($focus, equals: .to) }
            Divider()
            row("抄送") { TextField("", text: $draft.cc).focused($focus, equals: .cc) }
            Divider()
            row("主题") { TextField("", text: $draft.subject).focused($focus, equals: .subject) }
            Divider()
            if mail.accounts.accounts.count > 1 {
                row("发件人") {
                    Picker("发件人", selection: $draft.account) {
                        ForEach(mail.accounts.accounts) { Text($0.email).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                Divider()
            }
            if !draft.attachments.isEmpty {
                AttachmentStrip(attachments: $draft.attachments)
                Divider()
            }
            BodyEditor(text: $draft.body, focusOnAppear: !draft.to.isEmpty,
                       onFiles: { attach($0) }, onImage: { add(Self.pngAttachment($0, name: "图片")) })
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            Task { await accept(providers) }
            return true
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { attach(urls) }
        }
        .navigationTitle(draft.subject.isEmpty ? "新邮件" : draft.subject)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { picking = true } label: {
                    Label("添加附件", systemImage: "paperclip")
                }
                .help("添加附件（⇧⌘A），也可以把文件或图片拖进来")
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await send() } } label: {
                    Label("发送", systemImage: sending ? "hourglass" : "paperplane")
                }
                .help("发送（⇧⌘D）")
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(sending || recipients.isEmpty)
            }
        }
        .alert("邮件没有发出去", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onAppear { if draft.to.isEmpty { focus = .to } }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label + "：").foregroundStyle(.secondary)
            content().textFieldStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    /// Most providers refuse messages over about 25 MB once encoded (base64 grows data by a third).
    static let sizeLimit = 25 * 1024 * 1024

    private func attach(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                error = "「\(url.lastPathComponent)」是文件夹，请先压缩再添加"
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                error = "读不了「\(url.lastPathComponent)」"
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            add(MailAttachment(filename: url.lastPathComponent, contentType: type, data: data))
        }
    }

    private func add(_ a: MailAttachment) {
        let total = draft.attachments.reduce(0) { $0 + $1.data.count } + a.data.count
        guard total * 4 / 3 <= Self.sizeLimit else {
            error = "附件太大了：加上「\(a.filename)」一共 \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))，大多数邮箱只收 25 MB 以内的邮件"
            return
        }
        draft.attachments.append(a)
    }

    /// Files from Finder, or image data dragged out of an app (a screenshot thumbnail, a browser image).
    private func accept(_ providers: [NSItemProvider]) async {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(p) {
                attach([url])
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                var data = await loadData(p, UTType.png)
                if data == nil { data = await loadData(p, UTType.image) }
                guard let data, let image = NSImage(data: data) else { continue }
                add(Self.pngAttachment(image, name: p.suggestedName ?? "图片"))
            }
        }
    }

    static func pngAttachment(_ image: NSImage, name: String) -> MailAttachment {
        let png = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
        let stamp = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: ".")
        return MailAttachment(filename: "\(name) \(stamp).png", contentType: "image/png", data: png)
    }

    private func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
        }
    }

    private func loadData(_ p: NSItemProvider, _ type: UTType) async -> Data? {
        guard p.hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return await withCheckedContinuation { c in
            p.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in c.resume(returning: data) }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await mail.send(from: draft.account, OutgoingMail(
                to: recipients, cc: MailFormat.addresses(draft.cc), subject: draft.subject,
                body: draft.body, inReplyTo: draft.inReplyTo, references: draft.references,
                attachments: draft.attachments
            ))
            NSSound(named: "Purr")?.play()
            close()
        } catch {
            self.error = MailCenter.describe(error)
        }
    }
}

/// The files going with the message, as removable chips.
private struct AttachmentStrip: View {
    @Binding var attachments: [MailAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    HStack(spacing: 6) {
                        Image(nsImage: icon(a))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(a.filename).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            attachments.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("移除")
                    }
                    .font(.callout)
                    .padding(.leading, 7)
                    .padding(.trailing, 6)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.6)))
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 42)
    }

    private func icon(_ a: MailAttachment) -> NSImage {
        if a.contentType.hasPrefix("image/"), let image = NSImage(data: a.data) { return image }
        let ext = (a.filename as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

/// The message body: a plain-text NSTextView that turns dropped files and pasted images into attachments
/// (the stock text view would insert a file path, or nothing).
private struct BodyEditor: NSViewRepresentable {
    @Binding var text: String
    let focusOnAppear: Bool
    let onFiles: ([URL]) -> Void
    let onImage: (NSImage) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = AttachingTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? AttachingTextView else { return scroll }
        view.delegate = context.coordinator
        view.string = text
        view.font = .preferredFont(forTextStyle: .body)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.onFiles = onFiles
        view.onImage = onImage
        if focusOnAppear {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view); view.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AttachingTextView else { return }
        if view.string != text { view.string = text }
        view.onFiles = onFiles
        view.onImage = onImage
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BodyEditor
        init(_ parent: BodyEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class AttachingTextView: NSTextView {
    var onFiles: (([URL]) -> Void)?
    var onImage: ((NSImage) -> Void)?

    override class func scrollableTextView() -> NSScrollView {
        let scroll = NSScrollView()
        let view = AttachingTextView()
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }

    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    private func files(_ pb: NSPasteboard) -> [URL] {
        pb.readObjects(forClasses: [NSURL.self], options: Self.fileOptions) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if !files(pb).isEmpty || NSImage.canInit(with: pb) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if !files(pb).isEmpty || NSImage.canInit(with: pb) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let urls = files(pb)
        if !urls.isEmpty { onFiles?(urls); return true }
        if let image = pastedImage(pb) { onImage?(image); return true }
        return super.performDragOperation(sender)
    }

    /// An image on the pasteboard that should become an attachment: a screenshot, or "Copy Image" in a
    /// browser (which adds the image's URL as text). Rich text from Word also carries a picture of itself,
    /// so real text wins over the image.
    private func pastedImage(_ pb: NSPasteboard) -> NSImage? {
        guard pb.availableType(from: [.png, .tiff]) != nil || NSImage.canInit(with: pb) else { return nil }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
           URL(string: text)?.scheme?.hasPrefix("http") != true {
            return nil
        }
        return NSImage(pasteboard: pb)
    }

    /// A plain-text view greys out Paste when the pasteboard holds no text; keep it on for files and images.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pb = NSPasteboard.general
            if !files(pb).isEmpty || pastedImage(pb) != nil { return true }
        }
        return super.validateUserInterfaceItem(item)
    }

    /// ⌘V of a copied file or a screenshot attaches it; text pastes as plain text.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let urls = files(pb)
        if !urls.isEmpty { onFiles?(urls); return }
        if let image = pastedImage(pb) { onImage?(image); return }
        pasteAsPlainText(sender)
    }
}
