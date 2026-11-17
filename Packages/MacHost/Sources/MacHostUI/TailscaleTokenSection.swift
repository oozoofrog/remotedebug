import MacHostKit
import SwiftUI

/// 설정 > 고급: Tailscale OAuth 클라이언트. 넣으면 페어링 QR에 1회용 키가 들어가 iPhone은 Tailscale 로그인 없이 연결된다.
struct TailscaleTokenSection: View {
    @Environment(HostModel.self) private var model
    @State private var clientID = ""
    @State private var secret = ""
    @State private var tags = TailscaleAPI.defaultTags.joined(separator: ", ")
    @State private var confirmsClear = false

    static let guide = URL(string: "https://tailscale.com/kb/1215/oauth-clients")!

    var body: some View {
        Section {
            if model.hasTailscaleClient {
                LabeledContent("OAuth 클라이언트") {
                    HStack {
                        Label("키체인에 저장됨", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("지우기…") { confirmsClear = true }
                    }
                }
                LabeledContent("키에 붙는 태그", value: model.tailscaleTags.joined(separator: ", "))
            } else {
                TextField("클라이언트 ID", text: $clientID)
                    .accessibilityLabel("Tailscale OAuth 클라이언트 ID")
                SecureField("클라이언트 비밀값", text: $secret, prompt: Text("tskey-client-…"))
                    .accessibilityLabel("Tailscale OAuth 클라이언트 비밀값")
                TextField("태그", text: $tags, prompt: Text("tag:rd-phone"))
                    .accessibilityLabel("키에 붙일 태그")
                HStack {
                    Link("OAuth 클라이언트 만드는 법", destination: Self.guide)
                    Spacer()
                    if model.isCheckingToken { ProgressView().controlSize(.small) }
                    Button("저장") {
                        let (id, value, tagText) = (clientID, secret, tags)
                        Task {
                            await model.saveTailscaleClient(id: id, secret: value, tags: tagText)
                            if model.hasTailscaleClient {
                                clientID = ""
                                secret = ""
                            }
                        }
                    }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty
                              || secret.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isCheckingToken)
                }
            }
            if let check = model.tokenCheck {
                Label(check.message, systemImage: check.ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(check.ok ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("iPhone 자동 연결")
        } footer: {
            // 긴 설명이 한 줄로 잘리지 않게 줄을 바꿔 다 보인다.
            VStack(alignment: .leading, spacing: 6) {
                Text("이 Mac이 로그인한 tailnet의 관리 콘솔에서 OAuth 클라이언트를 만드세요. 권한은 Auth Keys 쓰기(auth_keys) 하나면 됩니다. 태그는 위와 같은 태그를 고르고, 목록에 없으면 정책 파일의 tagOwners에 먼저 추가하세요.")
                Text("정책 파일은 그 태그에서 이 Mac의 443·4747 포트로 가는 연결을 허용해야 합니다.")
                Text("앱용 페어링 QR을 열 때마다 QR과 같은 5분 동안 한 번만 쓸 수 있는 키를 만들어 QR에 넣습니다. QR을 다른 사람에게 보여 주지 마세요.")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Tailscale OAuth 클라이언트를 지울까요?", isPresented: $confirmsClear) {
            Button("클라이언트 지우기", role: .destructive) { model.clearTailscaleClient() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이후 앱용 페어링 QR에는 Tailscale 키가 들어가지 않아 iPhone에서 Tailscale 로그인이 필요합니다. 관리 콘솔의 클라이언트는 그대로 남습니다.")
        }
    }
}

/// 페어링 시트: QR에 Tailscale 키가 들어 있는지와 다음 행동.
struct PairingKeyNote: View {
    @Environment(HostModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let dismiss: () -> Void

    var body: some View {
        switch model.pairingKeyState {
        case .ready:
            Label("이 QR에는 한 번만 쓸 수 있는 Tailscale 키가 들어 있어, iPhone은 로그인 없이 연결됩니다. 다른 사람에게 보여 주지 마세요.", systemImage: "key.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .creating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Tailscale 키를 만드는 중…").font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label("Tailscale 키를 만들지 못해 QR에는 키가 없습니다. iPhone에서 Tailscale 로그인이 필요합니다. \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .off:
            HStack(alignment: .firstTextBaseline) {
                Text("Tailscale OAuth 클라이언트를 넣으면 iPhone에서 Tailscale 로그인 없이 QR 한 번으로 연결됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("설정하기…") {
                    // 이 설정은 설정 창의 고급 탭에 있다.
                    UserDefaults.standard.set(SettingsView.Tab.advanced.rawValue, forKey: SettingsView.tabKey)
                    dismiss()
                    openSettings()
                }
            }
        }
    }
}
