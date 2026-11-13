#if os(iOS) && !targetEnvironment(macCatalyst)
import MessageUI
import PhotosUI
import SwiftUI
import UIKit

/// 피드백 화면에 쓰는 문구. 앱의 언어에 맞게 바꿔 넣는다.
public struct RemoteDebugFeedbackLabels: Sendable {
    public var title = "피드백 보내기"
    public var prompt = "무엇이 문제인가요?"
    public var screenshot = "화면 사진"
    public var pickPhoto = "사진 고르기"
    public var removePhoto = "사진 빼기"
    public var includeLogs = "최근 로그 붙이기"
    public var send = "보내기"
    public var close = "닫기"
    public var disclosure = "앱 버전과 기기 종류가 함께 개발자에게 갑니다."
    public var notConfigured = "이 빌드는 피드백을 보낼 곳이 설정되지 않았습니다."
    public var collectingLogs = "로그를 모으는 중…"
    public var sendingToMac = "개발자의 Mac으로 보내는 중…"
    public var preparingMail = "메일을 준비하는 중…"
    public var saving = "저장하는 중…"
    public var sent = "보냈습니다."
    public var unreachable = "지금은 개발자의 Mac에 닿지 않습니다."
    public var sendByMail = "메일로 보내기"
    public var sendLater = "저장하고 나중에 보내기"
    public var saved = "저장해 두었습니다. RemoteDebug 앱의 VPN을 켜고 이 앱을 다시 열면 보냅니다."
    public var mail = FeedbackLabels()

    public init() {}
}

/// 피드백을 적어 보내는 화면. Mac으로 바로 보내고, 닿지 않으면 메일이나 나중에 보내기를 고르게 한다.
public struct RemoteDebugFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var mail: FeedbackSession
    @State private var draft = FeedbackDraft()
    @State private var message = ""
    @State private var image: Data?
    @State private var includesLogs = true
    /// 지금 하고 있는 일. `nil`이면 쉬는 중이다.
    @State private var progress: String?
    @State private var collectedLogs: [String]?
    @State private var notice: String?
    @State private var asksRoute = false
    @State private var picked: PhotosPickerItem?
    private let labels: RemoteDebugFeedbackLabels
    private let configuration: RemoteDebugFeedback.Configuration

    /// `screenshot`은 화면을 띄우기 전에 찍어 둔 앱 화면이다.
    public init(screenshot: Data? = nil, labels: RemoteDebugFeedbackLabels = RemoteDebugFeedbackLabels()) {
        self.labels = labels
        let configuration = RemoteDebugFeedback.configuration
        self.configuration = configuration
        let draft = FeedbackDraft()
        let info = FeedbackAppInfo(name: RemoteDebugFeedback.appName, version: RemoteDebugFeedback.shortVersion,
                                   build: RemoteDebugFeedback.buildNumber,
                                   system: ProcessInfo.processInfo.operatingSystemVersionString,
                                   device: RemoteDebugFeedback.deviceModel)
        _draft = State(initialValue: draft)
        _image = State(initialValue: screenshot)
        _mail = StateObject(wrappedValue: FeedbackSession(recipient: configuration.email ?? "", appInfo: info, labels: labels.mail) { info in
            FeedbackContent(subject: "\(info.name) feedback", body: draft.message + FeedbackContent.standard(info).body)
        })
    }

    private var hasMail: Bool { !(configuration.email ?? "").isEmpty }
    private var hasMac: Bool { RemoteDebugFeedback.client != nil }
    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $message)
                        .frame(minHeight: 140)
                        .accessibilityLabel(labels.prompt)
                } header: {
                    Text(labels.prompt)
                }
                Section {
                    if let image, let preview = UIImage(data: image) {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(labels.screenshot)
                        Button(labels.removePhoto, role: .destructive) { self.image = nil }
                    }
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label(labels.pickPhoto, systemImage: "photo")
                    }
                    Toggle(labels.includeLogs, isOn: $includesLogs)
                } header: {
                    Text(labels.screenshot)
                } footer: {
                    Text(hasMac || hasMail ? labels.disclosure : labels.notConfigured)
                }
                if let progress {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(progress)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else if let status = notice ?? mail.status {
                    Section { Text(status).font(.footnote) }
                }
            }
            .disabled(progress != nil)
            .navigationTitle(labels.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(labels.close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(labels.send) { Task { await send() } }
                        .disabled(progress != nil || trimmed.isEmpty || !(hasMac || hasMail))
                }
            }
            .confirmationDialog(labels.unreachable, isPresented: $asksRoute, titleVisibility: .visible) {
                if hasMail { Button(labels.sendByMail) { Task { await sendMail() } } }
                Button(labels.sendLater) { Task { await sendLater() } }
            }
            .sheet(item: $mail.composing) { mail in
                FeedbackMailComposer(mail: mail, onFinish: self.mail.finish).ignoresSafeArea()
            }
            .onChange(of: includesLogs) { _, _ in collectedLogs = nil }
            .onChange(of: picked) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                    image = FeedbackScreenshot.compressed(data)
                }
            }
        }
    }

    /// 붙일 로그. 한 번 모은 것은 이 화면에서 다시 모으지 않는다.
    private func logLines() async -> [String] {
        guard includesLogs else { return [] }
        if let collectedLogs { return collectedLogs }
        progress = labels.collectingLogs
        let lines = await Task.detached { FeedbackLog.shared.collect() }.value
        collectedLogs = lines
        return lines
    }

    private func report() async -> FeedbackReport {
        let lines = await logLines()
        let details = lines.isEmpty ? "" : "\n최근 로그\n" + lines.joined(separator: "\n")
        return RemoteDebugFeedback.report(message: trimmed, details: details, image: image, date: Date())
    }

    private func send() async {
        notice = nil
        guard let client = RemoteDebugFeedback.client else {
            await sendMail()
            return
        }
        let report = await report()
        progress = labels.sendingToMac
        let delivered = await client.trySend(report)
        progress = nil
        if delivered {
            dismiss()
        } else {
            asksRoute = true
        }
    }

    private func sendLater() async {
        guard let client = RemoteDebugFeedback.client else { return }
        let report = await report()
        progress = labels.saving
        let delivered = await client.submit(report)
        progress = nil
        if delivered {
            dismiss()
        } else {
            notice = labels.saved
            message = ""
        }
    }

    private func sendMail() async {
        draft.message = trimmed
        #if DEBUG
        if let key = configuration.publicKeyBase64, !key.isEmpty, includesLogs || image != nil {
            let lines = await logLines()
            let shot = image
            mail.diagnostics = FeedbackDiagnostics(publicKeyBase64: key, disclosure: labels.disclosure) {
                var object: [String: Any] = ["logs": lines]
                if let shot { object["screenshotBase64"] = shot.base64EncodedString() }
                return try JSONSerialization.data(withJSONObject: object)
            }
            mail.attachesDiagnostics = true
        } else {
            mail.diagnostics = nil
        }
        #endif
        progress = labels.preparingMail
        let url = await mail.prepare(canSendMail: MFMailComposeViewController.canSendMail())
        progress = nil
        if let url { openURL(url) { mail.openedMailLink(accepted: $0) } }
    }
}

/// 메일 본문에 넣을 글을 세션의 `content` 클로저에 넘기는 상자.
@MainActor
final class FeedbackDraft {
    var message = ""
}

enum FeedbackScreenshot {
    /// 코어가 받는 화면 사진 크기 한도(바이트)보다 조금 작게 맞춘다.
    static let maxBytes = 900 << 10

    /// 지금 보이는 앱 화면. 피드백 화면을 띄우기 전에 부른다.
    @MainActor
    static func capture() -> Data? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let shot = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        return compressed(shot)
    }

    static func compressed(_ data: Data) -> Data? {
        UIImage(data: data).flatMap(compressed)
    }

    /// 긴 변을 1600픽셀 아래로 줄이고 한도에 들어올 때까지 JPEG 품질을 낮춘다.
    static func compressed(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height) * image.scale
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for quality in [0.7, 0.5, 0.3, 0.15] {
            if let data = resized.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
        }
        return nil
    }
}

private struct FeedbackPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let labels: RemoteDebugFeedbackLabels
    @State private var screenshot: Data?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, shown in
                if shown { screenshot = FeedbackScreenshot.capture() }
            }
            .sheet(isPresented: $isPresented) {
                RemoteDebugFeedbackSheet(screenshot: screenshot, labels: labels)
            }
    }
}

public extension View {
    /// `isPresented`가 참이 되면 지금 화면을 찍고 피드백 화면을 띄운다.
    func remoteDebugFeedback(isPresented: Binding<Bool>, labels: RemoteDebugFeedbackLabels = RemoteDebugFeedbackLabels()) -> some View {
        modifier(FeedbackPresenter(isPresented: isPresented, labels: labels))
    }
}
#endif
