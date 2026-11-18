import AppKit
import MacHostKit
import RDModels
import SwiftUI

/// 설정 창(⌘,): 알림과 고급. 매일 보지 않는 Tailscale·코어 설정을 여기에 둔다.
public struct SettingsView: View {
    enum Tab: String, Hashable {
        case notifications, advanced
    }

    /// 마지막으로 연 탭. 다른 화면이 특정 탭을 열 때도 쓴다.
    static let tabKey = "RemoteDebug.settings.tab"
    @AppStorage(SettingsView.tabKey) private var tab: Tab = .notifications

    public init() {}

    init(tab: Tab) {
        UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
    }

    public var body: some View {
        TabView(selection: $tab) {
            NotificationSettings()
                .tabItem { Label("알림", systemImage: "bell") }
                .tag(Tab.notifications)
            AdvancedSettings()
                .tabItem { Label("고급", systemImage: "gearshape.2") }
                .tag(Tab.advanced)
        }
        .frame(width: 600, height: 620)
    }
}

/// 설정 > 알림: 페어링한 iPhone에 새 빌드·파일 알림을 보내는 APNs 키.
struct NotificationSettings: View {
    @Environment(PushModel.self) private var push: PushModel?

    var body: some View {
        if push != nil {
            Form { PushSection() }
                .formStyle(.grouped)
        } else {
            ContentUnavailableView("알림을 설정할 수 없습니다", systemImage: "bell.slash",
                                   description: Text("RemoteDebug가 준비되지 않았습니다. 앱을 다시 열어 보세요."))
        }
    }
}

/// 설정 > 고급: 같은 네트워크 직접 연결, iPhone 자동 연결(OAuth 클라이언트), iPhone 앱 업데이트, 이 Mac의 노드·IP, 제어 서버와 진단.
struct AdvancedSettings: View {
    @AppStorage(FeedbackSetup.emailDefaultsKey) private var feedbackEmail = ""
    @Environment(HostModel.self) private var model
    @State private var controlDraft = ""
    @State private var confirmingControlURL = false

    static let directFooter = String(localized: "같은 Wi-Fi의 페어링한 iPhone이 VPN 없이 빌드 목록·파일·로그를 주고받습니다. 같은 네트워크의 다른 기기도 이 포트에 접속할 수는 있지만, 페어링한 iPhone의 토큰이 없으면 아무것도 받지 못합니다. 앱 설치는 계속 VPN으로 합니다.")

    static let cableFooter = String(localized: "USB 케이블로 이 Mac에 꽂은 페어링한 iPhone도 이 연결을 씁니다. 그때는 Wi-Fi와 VPN 없이 주고받고, 앱 설치도 케이블로 합니다.")

    /// "직접 연결" 줄의 상태 문구.
    static func directStatusText(_ model: HostModel) -> String {
        guard model.directEnabled else { return String(localized: "꺼짐") }
        guard model.isRunning else { return String(localized: "공유를 시작하면 켜집니다") }
        guard let direct = model.status?.direct else { return String(localized: "여는 중") }
        return direct.listening ? String(localized: "켜짐 · 포트 \(String(direct.port))") : String(localized: "포트를 열지 못했습니다")
    }

    private var isStopped: Bool { !model.isRunning && !model.isStarting }

    var body: some View {
        Form {
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.directFooter)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.cableFooter)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TailscaleTokenSection()

            UpdatePageSection()

            Section {
                TextField("받을 메일 주소", text: $feedbackEmail)
                    .textContentType(.emailAddress)
            } header: {
                Text("앱 피드백")
            } footer: {
                Text("앱에 피드백 보내기를 붙일 때 이 주소가 코드에 들어갑니다. 에이전트가 설정 코드를 받아 갈 때도 이 주소를 함께 받습니다. 배포판 사용자는 이 주소로 메일을 보냅니다.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("이 Mac") {
                LabeledContent("노드 이름") { Text(model.nodeName).textSelection(.enabled) }
                if let status = model.status {
                    LabeledContent("호스트 이름") { valueText(status.hostname) }
                    LabeledContent("주소(FQDN)") { valueText(status.fqdn) }
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
        .formStyle(.grouped)
        .onAppear { controlDraft = model.controlURL }
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
