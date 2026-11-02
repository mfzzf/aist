import AistCore
import PhotosUI
import SwiftUI

/// The bar at the bottom of the home screen: type and send, or hold the mic and talk.
///
///   hold 🎙  → listening panel with live transcript and waveform
///   release  → send          slide up → cancel          slide left → edit the text before sending
struct Composer: View {
    @EnvironmentObject private var inbox: Inbox
    @StateObject private var recorder = SpeechRecorder()

    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var arm: Arm = .send
    @State private var hint: String?
    @GestureState private var holding = false
    @Namespace private var glassSpace
    @State private var attachments: [Attachment] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showCamera = false

    enum Arm { case send, cancel, edit }

    /// A picked or pasted image: the JPEG that goes to the AI and a small preview.
    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let jpeg: Data
        let thumbnail: UIImage
    }

    private var listening: Bool { recorder.isRecording }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    var body: some View {
        GlassGroup(spacing: 6) {
            VStack(spacing: 10) {
                if listening {
                    ListeningPanel(recorder: recorder, arm: arm)
                        .glassID("panel", in: glassSpace)
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottom)))
                } else if let hint {
                    Text(hint)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glass(in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
                HStack(alignment: .bottom, spacing: 10) {
                    if !listening { attachButton }
                    field
                    actionButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            // While listening, fade the list away so the transcript has the stage.
            if listening {
                LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground).opacity(0.92)],
                               startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
                    .frame(height: 900)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: listening)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: arm)
        .animation(.easeOut(duration: 0.2), value: hint)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: canSend)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: attachments)
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 6, matching: .images)
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { attach(data) }
                }
                pickerItems = []
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in attach(data) }.ignoresSafeArea()
        }
        .onAppear {
            if Demo.attachments, let icon = UIImage(named: "Mascot")?.pngData() { attach(icon); attach(icon) }
        }
        .onAppear { if Demo.listening { recorder.startDemo() } }
        .onChange(of: holding) { isHolding in
            // The gesture can be cancelled without onEnded (a call comes in, the app goes away).
            if !isHolding, listening { finish() }
        }
    }

    // MARK: Text field

    private var field: some View {
        ZStack(alignment: .leading) {
            if listening {
                Text(armLabel)
                    .font(.body.weight(.medium))
                    .foregroundStyle(arm == .cancel ? Color.red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 13)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !attachments.isEmpty { thumbnails }
                TextField(attachments.isEmpty ? "记点什么，或按住麦克风说话" : "说说要做什么（可以不写）", text: $text, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .focused($focused)
                    // Return starts a new line: one line per thing, sent together with the arrow.
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                }
                .transition(.opacity)
            }
        }
        .frame(minHeight: 50)
        .glass(in: RoundedRectangle(cornerRadius: 25, style: .continuous), interactive: true)
        .glassID("field", in: glassSpace)
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    Image(uiImage: a.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { attachments.removeAll { $0.id == a.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("移除图片")
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.trailing, 6)
        }
    }

    private var attachButton: some View {
        Menu {
            Button { showPicker = true } label: { Label("照片", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
            }
            if UIPasteboard.general.hasImages {
                Button { UIPasteboard.general.images?.compactMap { $0.pngData() }.forEach(attach) } label: {
                    Label("粘贴图片", systemImage: "doc.on.clipboard")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .glass(in: Circle(), interactive: true)
        .glassID("attach", in: glassSpace)
        .accessibilityLabel("添加图片")
        .transition(.scale.combined(with: .opacity))
    }

    /// Any image bytes → upright JPEG for the AI, plus a preview.
    private func attach(_ data: Data) {
        guard attachments.count < 6,
              let jpeg = try? ImageCodec.jpeg(fromImageData: data),
              let small = try? ImageCodec.jpeg(fromImageData: data, maxDimension: 200),
              let thumbnail = UIImage(data: small) else { return }
        attachments.append(Attachment(jpeg: jpeg, thumbnail: thumbnail))
    }

    private var armLabel: String {
        switch arm {
        case .send: "松开发送"
        case .cancel: "松开取消"
        case .edit: "松开后编辑文字"
        }
    }

    // MARK: Send / mic button

    @ViewBuilder
    private var actionButton: some View {
        if canSend && !listening {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), tint: AistBrand.blue, interactive: true)
            .glassID("action", in: glassSpace)
            .accessibilityLabel("发送")
            .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(listening ? .white : .primary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .glass(in: Circle(), tint: listening ? micTint : nil, interactive: true)
                .glassID("action", in: glassSpace)
                .scaleEffect(listening ? 1.1 : 1)
                .gesture(holdToTalk)
                .accessibilityLabel("按住说话")
                .accessibilityAction { hint("按住说话，松开发送") }
        }
    }

    private var micTint: Color {
        switch arm {
        case .send: AistBrand.blue
        case .cancel: .red
        case .edit: AistBrand.violet
        }
    }

    private var holdToTalk: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case let .second(true, drag) = value else { return }
                if !listening { begin() }
                let t = drag?.translation ?? .zero
                let next: Arm = t.height < -60 ? .cancel : (t.width < -60 ? .edit : .send)
                if next != arm { arm = next; Haptics.tick() }
            }
            .onEnded { value in
                if case .second(true, _) = value { finish() } else { hint("按住说话，松开发送") }
            }
    }

    // MARK: Actions

    private func send() {
        guard canSend else { return }
        inbox.submit(text, voice: false, images: attachments.map(\.jpeg))
        text = ""
        attachments = []
    }

    private func begin() {
        switch SpeechRecorder.permission {
        case .granted:
            do {
                arm = .send
                focused = false
                try recorder.start()
                Haptics.tap()
            } catch {
                hint(error.localizedDescription)
            }
        case .undetermined:
            // The system prompt interrupts the press; ask now, talk on the next press.
            Task {
                if await SpeechRecorder.requestPermission() { hint("好了，再按住说话") }
            }
        case .denied:
            hint(SpeechRecorder.RecorderError.denied.localizedDescription)
        }
    }

    private func finish() {
        guard listening else { return }
        let action = arm
        arm = .send
        if action == .cancel {
            recorder.cancel()
            Haptics.warning()
            return
        }
        Task {
            let said = await recorder.stop()
            guard !said.isEmpty || !attachments.isEmpty else { hint("没听清，再说一次"); return }
            if action == .edit {
                text = said
                focused = true
            } else {
                inbox.submit(said, voice: true, images: attachments.map(\.jpeg))
                attachments = []
            }
        }
    }

    private func hint(_ message: String) {
        hint = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if hint == message { hint = nil }
        }
    }
}

/// Live transcript and waveform while the mic is held.
private struct ListeningPanel: View {
    @ObservedObject var recorder: SpeechRecorder
    let arm: Composer.Arm

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Waveform(levels: recorder.levels, color: arm == .cancel ? .red : AistBrand.blue)
                    .frame(height: 26)
                if let start = recorder.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(start)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(recorder.transcript.isEmpty ? "正在听…" : recorder.transcript)
                .font(.title3.weight(.medium))
                .foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(7)
                .animation(.easeOut(duration: 0.15), value: recorder.transcript)
            HStack(spacing: 14) {
                gestureHint("arrow.up", "上滑取消", active: arm == .cancel, color: .red)
                gestureHint("arrow.left", "左滑改文字", active: arm == .edit, color: AistBrand.violet)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
               tint: arm == .cancel ? .red.opacity(0.18) : nil)
    }

    private func gestureHint(_ symbol: String, _ label: String, active: Bool, color: Color) -> some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? color : .secondary)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(0.35 + 0.65 * Double(levels[i])))
                    .frame(width: 3, height: 4 + 22 * levels[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

/// The system camera, for photographing a poster, a receipt, a whiteboard.
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
