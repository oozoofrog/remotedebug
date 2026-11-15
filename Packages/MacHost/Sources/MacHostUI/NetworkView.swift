import AppKit
import MacHostKit
import RDModels
import SwiftUI

struct NetworkView: View {
    @Environment(HostModel.self) private var model
    @Environment(AuthKeyDraft.self) private var authKey
    /// Tailscale을 직접 다루는 설정을 펼쳤는가. 기본은 접힘.
    @AppStorage(NetworkView.detailsKey) private var showsDetails = false
    @State private var confirmingLogout = false
    @State private var isLoggingOut = false
    @State private var logoutError: String?
    @State private var controlDraft = ""
    @State private var confirmingControlURL = false
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

    private var showsKeyField: Bool { Self.showsKeyField(model) }
    /// 인증 키 입력란이 지금 화면에 보이는가(세부 설정을 펼쳤을 때만).
    private var showsKeyFieldNow: Bool { showsDetails && showsKeyField }

    static let detailsKey = "RemoteDebug.network.showsTailscaleDetails"
    static let detailsTitle = String(localized: "Tailscale 세부 설정 보기")
    static let logoutTitle = String(localized: "로그아웃…")

    /// 로그아웃 확인 창의 설명.
    static func logoutMessage(devices: Int) -> String {
        let paired = devices > 0
            ? String(localized: "공유를 멈추고 이 Mac의 로그인 정보와 페어링한 iPhone \(devices)대를 지웁니다.")
            : String(localized: "공유를 멈추고 이 Mac의 로그인 정보를 지웁니다.")
        return paired + " " + String(localized: "다시 쓰려면 공유를 시작해 로그인하고 iPhone을 새로 페어링하세요. 이 Mac은 새 기기로 등록되고, 예전 기기 항목은 Tailscale 관리 화면에 남습니다.")
    }

    /// "설치 페이지" 줄에 보일 주소(코드 없음). 페어링할 수 없으면 nil("아직 없음").
    static func installPageAddress(_ model: HostModel) -> URL? { model.installPageURL }

    static let copyAddressTitle = String(localized: "설치 페이지 주소 복사")
    static let copyAddressAnnouncement = String(localized: "설치 페이지 주소를 복사했습니다.")

    private var isStopped: Bool { !model.isRunning && !model.isStarting }

    static let directFooter = String(localized: "같은 Wi-Fi의 페어링한 iPhone이 VPN 없이 빌드 목록·파일·로그를 주고받습니다. 같은 네트워크의 다른 기기도 이 포트에 접속할 수는 있지만, 페어링한 iPhone의 토큰이 없으면 아무것도 받지 못합니다. 앱 설치는 계속 VPN으로 합니다.")

    /// "직접 연결" 줄의 상태 문구.
    static func directStatusText(_ model: HostModel) -> String {
        guard model.directEnabled else { return String(localized: "꺼짐") }
        guard model.isRunning else { return String(localized: "공유를 시작하면 켜집니다") }
        guard let direct = model.status?.direct else { return String(localized: "여는 중") }
        return direct.listening ? String(localized: "켜짐 · 포트 \(String(direct.port))") : String(localized: "포트를 열지 못했습니다")
    }

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
                if let error = logoutError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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
                }
            }

            Section {
                Toggle("같은 네트워크에서 직접 연결", isOn: Binding(
                    get: { model.directEnabled },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: LaunchOptions(defaults: .standard).savedDirectListenKey)
                        Task { await model.setDirectEnabled(on) }
                    }
                ))
                LabeledContent("상태") { Text(Self.directStatusText(model)) }
            } header: {
                Text("직접 연결")
            } footer: {
                Text(Self.directFooter)
            }

            PushSection()

            Section {
                Toggle(Self.detailsTitle, isOn: $showsDetails)
            } footer: {
                Text("인증 키 로그인, QR 한 번으로 iPhone 연결, iPhone 앱 업데이트, 이 Mac의 주소, 제어 서버 설정입니다. 켜지 않아도 연결과 설치는 됩니다.")
            }

            if showsDetails {
                if showsKeyField {
                    Section("인증 키로 로그인") {
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

                TailscaleTokenSection()

                UpdatePageSection()

                Section("이 Mac") {
                    LabeledContent("노드 이름") { Text(model.nodeName).textSelection(.enabled) }
                    if let status = model.status {
                        LabeledContent("호스트 이름") { valueText(status.hostname) }
                        LabeledContent("주소(FQDN)") { valueText(status.fqdn) }
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
                        LabeledContent("tailnet IP") {
                            if status.tailscaleIPs.isEmpty {
                                Text("아직 없음").foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .trailing) {
                                    ForEach(status.tailscaleIPs, id: \.self) { Text($0).textSelection(.enabled) }
                                }
                            }
                        }
                        if status.backendState == .running {
                            LabeledContent("HTTPS 인증서") {
                                Text(status.certDomains.isEmpty ? "사용 안 함" : (status.tlsReady ? "발급됨" : "발급 중"))
                            }
                        }
                    } else {
                        Text("공유 중에만 tailnet 주소를 표시합니다.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("제어 서버와 진단") {
                    HStack {
                        TextField("제어 서버 URL", text: $controlDraft, prompt: Text("비우면 Tailscale 기본 서버"))
                            .disabled(!isStopped)
                            .onSubmit(applyControlURL)
                        Button("적용", action: applyControlURL)
                            .disabled(!isStopped || controlDraft.trimmingCharacters(in: .whitespacesAndNewlines) == model.controlURL)
                    }
                    if !isStopped {
                        Text("공유를 중지해야 바꿀 수 있습니다. 새 값은 다음 공유 시작부터 씁니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("코어 메모리") {
                        if let rss = model.status?.rssMiB, rss > 0 {
                            Text("\(rss.formatted(.number.precision(.fractionLength(1)))) MiB")
                        } else {
                            Text("공유 중에만 표시").foregroundStyle(.secondary)
                        }
                    }
                    if let status = model.status {
                        LabeledContent("게시 빌드(코어)") { Text("\(status.publishedBuilds)개") }
                        LabeledContent("허용 기기(코어)") { Text("\(status.pairedDevices)대") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("네트워크")
        .onAppear { controlDraft = model.controlURL }
        // 입력란이 보이지 않는 화면에서 남은 키가 조용히 쓰이지 않게 지운다.
        .onDisappear { authKey.value = "" }
        .task(id: model.isRunning) {
            // 공유 중에는 상태(메모리·인증서)를 주기적으로 새로 읽는다.
            while model.isRunning, !Task.isCancelled {
                await model.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("제어 서버를 바꿀까요?", isPresented: $confirmingControlURL) {
            Button("바꾸고 기기 목록 지우기", role: .destructive) { commitControlURL(forget: true) }
            Button("취소", role: .cancel) { controlDraft = model.controlURL }
        } message: {
            Text("페어링한 기기 \(model.devicesDroppedByControlURL(controlDraft))대는 지금 제어 서버에서 페어링해 새 서버에서는 쓸 수 없습니다. 바꾸면 기기 목록을 지우고, 새 서버에서 iPhone을 다시 페어링해야 합니다.")
        }
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

    private func applyControlURL() {
        guard isStopped else { return }
        if model.devicesDroppedByControlURL(controlDraft) > 0 {
            confirmingControlURL = true
        } else {
            commitControlURL(forget: false)
        }
    }

    private func commitControlURL(forget: Bool) {
        guard model.applyControlURL(controlDraft, forgetOtherServerDevices: forget) else { return }
        controlDraft = model.controlURL
        UserDefaults.standard.set(model.controlURL, forKey: LaunchOptions(defaults: .standard).savedControlURLKey)
    }

    @ViewBuilder private func valueText(_ value: String) -> some View {
        if value.isEmpty {
            Text("아직 없음").foregroundStyle(.secondary)
        } else {
            Text(value).textSelection(.enabled)
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
