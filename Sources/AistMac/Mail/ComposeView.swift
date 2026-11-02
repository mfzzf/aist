import AistCore
import AppKit
import SwiftUI

/// A message being written.
struct ComposeDraft {
    var account: UUID
    var to = ""
    var cc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var references: [String] = []

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
    @FocusState private var focus: Field?

    private enum Field { case to, cc, subject, body }

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
            TextEditor(text: $draft.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(draft.subject.isEmpty ? "新邮件" : draft.subject)
        .toolbar {
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
        .onAppear { focus = draft.to.isEmpty ? .to : .body }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label + "：").foregroundStyle(.secondary)
            content().textFieldStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await mail.send(from: draft.account, OutgoingMail(
                to: recipients, cc: MailFormat.addresses(draft.cc), subject: draft.subject,
                body: draft.body, inReplyTo: draft.inReplyTo, references: draft.references
            ))
            NSSound(named: "Purr")?.play()
            close()
        } catch {
            self.error = MailCenter.describe(error)
        }
    }
}
