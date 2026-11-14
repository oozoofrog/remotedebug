import AppKit
import MacHostKit
import SwiftUI
import UniformTypeIdentifiers

/// 페어링한 iPhone에 새 빌드·파일 알림을 보내는 APNs 키 설정.
struct PushSection: View {
    @Environment(PushModel.self) private var push: PushModel?
    /// 고른 .p8 파일의 내용과 이름. 저장하기 전까지 메모리에만 둔다.
    @State private var keyDraft: String?
    @State private var keyFileName = ""
    @State private var keyIDDraft = ""
    @State private var teamIDDraft = ""
    @State private var readError: String?

    static let title = String(localized: "iPhone 알림")
    static let chooseKeyTitle = String(localized: "키 파일 고르기…")
    static let saveTitle = String(localized: "저장")
    static let clearTitle = String(localized: "키 지우기")
    static let testTitle = String(localized: "시험 알림 보내기")
    static let hideNamesTitle = String(localized: "알림에 이름을 넣지 않기")
    static let lastDeliveryTitle = String(localized: "마지막 전송")

    var body: some View {
        if let push {
            Section {
                if !push.isConfigured {
                    Text("Apple Developer의 Keys에서 만든 APNs 인증 키(.p8)와 Key ID, Team ID를 넣으면 빌드를 게시하거나 파일·링크를 보낼 때 페어링한 iPhone에 알림이 갑니다.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("키 파일") {
                    HStack(spacing: 8) {
                        Text(keyFileLabel(push))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(Self.chooseKeyTitle) { chooseKey() }
                    }
                }
                TextField("Key ID", text: $keyIDDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                TextField("Team ID", text: $teamIDDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                HStack {
                    Button(Self.saveTitle) {
                        if push.save(pem: keyDraft, keyID: keyIDDraft, teamID: teamIDDraft) {
                            keyDraft = nil
                            keyFileName = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyDraft == nil && !push.hasKey)
                    if push.hasKey || push.isConfigured {
                        Button(Self.clearTitle, role: .destructive) {
                            push.clearKey()
                            keyIDDraft = ""
                            teamIDDraft = ""
                        }
                    }
                }
                if let error = readError ?? push.setupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if push.isConfigured {
                    Toggle(Self.hideNamesTitle, isOn: Binding(get: { push.hideNames }, set: { push.hideNames = $0 }))
                    HStack {
                        Button(Self.testTitle) { Task { await push.sendTest() } }
                            .disabled(push.testUnavailableReason != nil || push.isSending)
                        if push.isSending { ProgressView().controlSize(.small) }
                    }
                    if let reason = push.testUnavailableReason {
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LabeledContent(Self.lastDeliveryTitle) {
                        if let delivery = push.lastDelivery {
                            Text("\(delivery.date.formatted(date: .omitted, time: .shortened)) · \(delivery.text)")
                                .foregroundStyle(delivery.failed ? .orange : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("없음").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(Self.title)
            } footer: {
                Text("알림 제목과 내용(앱 이름·버전, 파일 이름)은 Apple 푸시 서버를 거쳐 iPhone에 갑니다. 이름을 보내고 싶지 않으면 ‘알림에 이름을 넣지 않기’를 켜세요. 키는 이 Mac의 키체인에만 저장합니다.")
            }
            .onAppear {
                keyIDDraft = push.keyID
                teamIDDraft = push.teamID
            }
        }
    }

    private func keyFileLabel(_ push: PushModel) -> String {
        if keyDraft != nil { return keyFileName }
        return push.hasKey ? String(localized: "키체인에 저장됨") : String(localized: "없음")
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readError = nil
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            readError = String(localized: "\(url.lastPathComponent)을(를) 읽지 못했습니다.")
            return
        }
        keyDraft = text
        keyFileName = url.lastPathComponent
    }
}
