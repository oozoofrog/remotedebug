import AppKit
import MacHostKit
import RDModels
import SwiftUI

struct NetworkView: View {
    @Environment(HostModel.self) private var model
    @Environment(AuthKeyDraft.self) private var authKey
    @Environment(\.openSettings) private var openSettings
    /// 인증 키 입력란을 펼쳤는가. 기본은 접힘.
    @AppStorage(NetworkView.detailsKey) private var showsKeyEntry = false
    @State private var confirmingLogout = false
    @State private var isLoggingOut = false
    @State private var logoutError: String?
    @State private var confirmingForget = false

    /// 인증 키 입력란이 쓸모 있는 상태: 공유가 꺼져 있거나, 켜져 있지만 로그인·오류로 tailnet에 오르지 못했다.
    static func showsKeyField(_ model: HostModel) -> Bool {
        if !model.isRunning && !model.isStarting { return true }
        switch model.guidance.kind {
        case .needsLogin, .waitingForLoginURL, .error, .unknown: return true
        default: return false
        }
    }

    /// 인증 키 입력란 옆의 버튼 이름.
    static func keyFieldActionTitle(_ model: HostModel, draft: String) -> String {
        if !model.isRunning && !model.isStarting { return String(localized: "공유 시작") }
        return draft.isEmpty ? String(localized: "공유 다시 시작") : String(localized: "인증 키로 다시 시작")
    }

    /// 다시 연결 버튼을 따로 둘 상태: 공유 중이고, 안내 카드나 입력란이 이미 다시 시작 버튼을 보이지 않는다.
    static func showsReconnect(_ model: HostModel) -> Bool {
        model.isRunning && model.guidance.action != .restart && !showsKeyField(model)
    }

    private var showsKeyField: Bool { Self.showsKeyField(model) }
    /// 인증 키 입력란이 지금 화면에 보이는가(펼쳤을 때만).
    private var showsKeyFieldNow: Bool { showsKeyEntry && showsKeyField }

    static let detailsKey = "RemoteDebug.network.showsTailscaleDetails"
    static let copyAddressTitle = String(localized: "설치 페이지 주소 복사")
    static let copyAddressAnnouncement = String(localized: "설치 페이지 주소를 복사했습니다.")

    /// "설치 페이지" 줄에 보일 주소(코드 없음). 페어링할 수 없으면 nil("아직 없음").
    /// 앱이 없는 iPhone이 Safari로 여는 주소라 설치 페이지의 안내도 이 화면을 가리킨다.
    static func installPageAddress(_ model: HostModel) -> URL? { model.installPageURL }
    static let logoutTitle = String(localized: "로그아웃…")
    static let reconnectTitle = String(localized: "다시 연결")

    /// 로그아웃 확인 창의 설명.
    static func logoutMessage(devices: Int) -> String {
        let paired = devices > 0
            ? String(localized: "공유를 멈추고 이 Mac의 로그인 정보와 페어링한 iPhone \(devices)대를 지웁니다.")
            : String(localized: "공유를 멈추고 이 Mac의 로그인 정보를 지웁니다.")
        return paired + " " + String(localized: "다시 쓰려면 공유를 시작해 로그인하고 iPhone을 새로 페어링하세요. 이 Mac은 새 기기로 등록되고, 예전 기기 항목은 Tailscale 관리 화면에 남습니다.")
    }

    private var isStopped: Bool { !model.isRunning && !model.isStarting }

    var body: some View {
        @Bindable var authKey = authKey
        Form {
            Section("연결") {
                // 입력란이 보이면 시작·다시 시작 버튼은 입력란 옆에 하나만 둔다.
                GuidanceCard(guidance: model.guidance, showsStartActions: !showsKeyFieldNow)
                if let conflict = model.deviceScopeConflict {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(conflict.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("기기 목록 지우기…") { confirmingForget = true }
                    }
                }
                LabeledContent("설치 페이지") {
                    if let page = Self.installPageAddress(model) {
                        HStack(spacing: 6) {
                            Text(page.absoluteString).textSelection(.enabled)
                            CopyLinkButton(url: page, title: Self.copyAddressTitle,
                                           announcement: Self.copyAddressAnnouncement, iconOnly: true)
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Text("아직 없음").foregroundStyle(.secondary)
                    }
                }
                if Self.showsReconnect(model) {
                    LabeledContent {
                        RestartSharingButton(title: Self.reconnectTitle)
                    } label: {
                        Text("다시 연결")
                        Text("iPhone이 이 Mac에 닿지 않으면 공유를 멈췄다가 다시 시작합니다.")
                    }
                }
            }

            Section("로그인") {
                if let error = logoutError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fqdn = model.status?.fqdn, !fqdn.isEmpty {
                    LabeledContent("이 Mac의 tailnet 주소") { Text(fqdn).textSelection(.enabled) }
                }
                if model.hasSavedLogin {
                    LabeledContent {
                        HStack {
                            if isLoggingOut { ProgressView().controlSize(.small) }
                            Button(Self.logoutTitle) { confirmingLogout = true }
                                .disabled(isLoggingOut)
                        }
                    } label: {
                        Text("다른 계정으로 바꾸기")
                        Text("로그아웃한 뒤 공유를 시작하면 다시 로그인합니다.")
                    }
                } else {
                    Text("공유를 시작하면 Tailscale 로그인 페이지가 열립니다.")
                        .foregroundStyle(.secondary)
                }
                if showsKeyField {
                    DisclosureGroup("인증 키로 로그인", isExpanded: $showsKeyEntry) {
                        SecureField("인증 키(선택)", text: $authKey.value, prompt: Text("tskey-auth-…"))
                            .accessibilityLabel("tailnet 인증 키")
                        HStack {
                            Text("인증 키는 저장하지 않고 다음 공유 시작에 한 번만 씁니다.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isStopped {
                                SharingButton()
                            } else {
                                RestartSharingButton(title: Self.keyFieldActionTitle(model, draft: authKey.value))
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("설정 열기…") { openSettings() }
                } label: {
                    Text("알림과 고급 설정")
                    Text("iPhone 알림, iPhone 자동 연결, 같은 네트워크 직접 연결, 노드·IP, 제어 서버")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("네트워크")
        // 입력란이 보이지 않는 화면에서 남은 키가 조용히 쓰이지 않게 지운다.
        .onDisappear { authKey.value = "" }
        .confirmationDialog("이 Mac을 로그아웃할까요?", isPresented: $confirmingLogout) {
            Button("로그아웃", role: .destructive) {
                isLoggingOut = true
                logoutError = nil
                Task {
                    if await !model.logout() { logoutError = model.lastError }
                    isLoggingOut = false
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(Self.logoutMessage(devices: model.devices.count))
        }
        .confirmationDialog("기기 목록을 지울까요?", isPresented: $confirmingForget) {
            Button("기기 목록 지우기", role: .destructive) { model.forgetDevicesFromOtherServer() }
            Button("돌아가기", role: .cancel) {}
        } message: {
            Text("다른 제어 서버에서 페어링한 기기 \(model.devices.count)대를 지웁니다. 지금 제어 서버에서 iPhone을 새로 페어링해야 합니다.")
        }
    }
}

/// HostModel의 안내(제목·문장)를 그대로 보여 주고, 안내가 가리키는 행동 버튼을 붙인다.
/// `showsStartActions`가 false면 공유 시작·다시 시작 버튼을 뺀다(인증 키 입력란 옆에 있다).
struct GuidanceCard: View {
    @Environment(HostModel.self) private var model
    let guidance: StatusGuidance
    var showsStartActions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuidanceLabel(guidance: guidance)
                .font(.headline)
            Text(guidance.message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if guidance.kind == .needsLockSignature, let wait = model.status?.lockWait {
                LockSignCommand(command: wait.signCommand)
            }
            HStack {
                switch guidance.action {
                case .start where showsStartActions:
                    SharingButton()
                case .openLoginPage:
                    Button("로그인 페이지 열기") { model.openLoginPage() }
                        .buttonStyle(.borderedProminent)
                case .restart where showsStartActions:
                    RestartSharingButton()
                default:
                    EmptyView()
                }
                if guidance.kind == .certificatesDisabled || guidance.kind == .magicDNSDisabled,
                   let url = URL(string: StatusGuidance.dnsConsoleURL) {
                    Button("DNS 설정 페이지 열기") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Tailnet Lock 서명 명령을 보여 주고 복사한다.
struct LockSignCommand: View {
    let command: String
    @State private var copied = false

    static let copyTitle = String(localized: "서명 명령 복사")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(Self.copyTitle) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                if copied {
                    Label("복사했습니다", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
