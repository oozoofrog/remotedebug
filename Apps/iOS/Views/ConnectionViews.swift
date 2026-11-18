import PhoneClientKit
import RDModels
import SwiftUI

// 연결 상태를 화면에 올리는 방법: 정상이면 맨 위에 한 줄로 접고(눌러서 상세),
// 사용자가 해야 할 일이 있을 때만 원인과 버튼 하나를 가진 카드로 펼친다.

// MARK: - 상태 값

extension PhoneViewState {
    /// 앱이 VPN을 켜고 연결을 기다리는 중이다.
    var isAutoStartingVPN: Bool {
        guard vpnAutoStarting else { return false }
        switch tunnel {
        case .off, .connecting, .disconnecting: return true
        default: return false
        }
    }

    var connectionStatus: ConnectionStatus {
        ConnectionStatus(
            tunnel: tunnel, tunnelAvailable: tunnelAvailable, tunnelActive: tunnelActive, directConnected: directConnected,
            autoStartReady: vpnAutoStartReady, autoStarting: vpnAutoStarting, lockWaiting: lockWait != nil
        )
    }

    /// VPN 상태 이름. VoiceOver 레이블에도 쓴다.
    var vpnStatusLabel: String {
        if !tunnelAvailable { return directLink.map(VPNStatusText.direct) ?? String(localized: "사용할 수 없음") }
        if isAutoStartingVPN { return VPNStatusText.autoStarting }
        switch tunnel {
        case .off: return directLink.map(VPNStatusText.direct) ?? String(localized: "꺼짐")
        case .connecting: return String(localized: "연결 중")
        case .disconnecting: return String(localized: "끄는 중")
        case .needsLogin: return String(localized: "로그인 필요")
        case .connected:
            if lockWait != nil { return String(localized: "서명 필요") }
            switch vpnPair.owner {
            case .pairedApp: return String(localized: "연결됨 · RD 업데이트의 VPN")
            case .other: return String(localized: "연결됨 · 다른 앱의 VPN")
            case .none, .thisApp: return VPNStatusText.connected(holder: vpnPair.owner, path: peerPath)
            }
        case .failed: return String(localized: "오류")
        }
    }

    /// VPN 상태 아래의 설명. 없으면 `nil`.
    var vpnDetail: String? {
        switch tunnel {
        case .off:
            directLink.map(VPNStatusText.directDetail) ?? (vpnAutoStartReady
                ? String(localized: "Mac에 연결할 때 자동으로 켜고, 쓰지 않으면 30초 뒤에 끕니다.")
                : String(localized: "Mac과 통신하려면 VPN이 켜져 있어야 합니다. 여기서 한 번 켜 두면 다음부터는 필요할 때 자동으로 켭니다."))
        case .connecting, .disconnecting: nil
        case .needsLogin(let url): url == nil ? String(localized: "tailnet 로그인 주소를 받는 중입니다.") : String(localized: "tailnet에 로그인해야 합니다. 로그인하면 자동으로 연결됩니다.")
        case .connected:
            vpnAutoStarted ? String(localized: "Mac에 연결하려고 자동으로 켰습니다. 쓰지 않으면 30초 뒤에 끕니다.")
                : directLink.map(VPNStatusText.directWithVPNDetail)
        case .failed(let message): message
        }
    }

    var vpnSymbol: String {
        if !tunnelAvailable { return "network.slash" }
        switch tunnel {
        case .off: return directLink == .cable ? "cable.connector" : directConnected ? "wifi" : "network.slash"
        case .connecting: return "network"
        case .disconnecting: return "network.slash"
        case .needsLogin: return "person.badge.key"
        case .connected: return "checkmark.shield.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var vpnTint: Color {
        if !tunnelAvailable { return directConnected ? .green : .secondary }
        switch tunnel {
        case .off: return directConnected ? .green : .secondary
        case .connecting: return .blue
        case .disconnecting: return .secondary
        case .needsLogin: return .orange
        case .connected: return lockWait == nil ? .green : .orange
        case .failed: return .red
        }
    }

    /// 로그인 페이지 주소. 필요 없거나 아직 모르면 `nil`.
    var loginURL: URL? {
        if case .needsLogin(let url) = tunnel { return url }
        return nil
    }

    /// 상태 한 줄의 두 번째 줄.
    var connectionLine: String {
        switch connectionStatus {
        case .standby: String(localized: "VPN 꺼짐 · 필요할 때 자동으로 켭니다")
        case .ready, .working, .problem: vpnStatusLabel
        }
    }
}

// MARK: - 맨 위 연결 칸

/// 연결 요약. 정상이면 Mac 이름과 상태 한 줄, 해야 할 일이 있으면 원인과 버튼 하나.
/// 페어링 전에는 사용자가 해야 할 일이 생겼을 때만 보인다(페어링을 시작하면 앱이 VPN을 켠다).
struct ConnectionSection: View {
    var state: PhoneViewState
    var actions: PhoneActions
    var pairAnotherMac: () -> Void

    var body: some View {
        let status = state.connectionStatus
        if let host = state.host {
            if let problem = status.problem {
                ConnectionProblemCard(problem: problem, state: state, actions: actions, pairAnotherMac: pairAnotherMac)
            } else {
                Section {
                    NavigationLink {
                        ConnectionDetailView(state: state, actions: actions, pairAnotherMac: pairAnotherMac)
                    } label: {
                        ConnectionSummaryRow(hostName: host.hostName, status: status, state: state)
                    }
                }
            }
        } else if status.isShownBeforePairing(vpnNeeded: state.needsTunnel || state.queuedPairingHost != nil),
                  let problem = status.problem {
            ConnectionProblemCard(problem: problem, state: state, actions: actions, pairAnotherMac: pairAnotherMac)
        }
    }
}

/// "Mac 이름 / 연결됨". 아이콘 모양과 글자로 상태를 말하고, 색은 거드는 데만 쓴다.
private struct ConnectionSummaryRow: View {
    var hostName: String
    var status: ConnectionStatus
    var state: PhoneViewState

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if status == .working {
                    ProgressView()
                } else {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
            }
            .font(.title3)
            .frame(width: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hostName).font(.headline)
                Text(state.connectionLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hostName), \(state.connectionLine)")
    }

    private var symbol: String { status == .standby ? "pause.circle" : "checkmark.circle.fill" }
    private var tint: Color { status == .standby ? .secondary : .green }
}

/// 해야 할 일이 있을 때의 카드. 제목 줄을 누르면 상세(VPN 전체 컨트롤)로 간다.
private struct ConnectionProblemCard: View {
    var problem: ConnectionStatus.Problem
    var state: PhoneViewState
    var actions: PhoneActions
    var pairAnotherMac: () -> Void

    @State private var busy = false

    var body: some View {
        Section {
            NavigationLink {
                ConnectionDetailView(state: state, actions: actions, pairAnotherMac: pairAnotherMac)
            } label: {
                Label {
                    Text("VPN \(state.vpnStatusLabel)")
                } icon: {
                    Image(systemName: state.vpnSymbol)
                }
                .font(.headline)
                .foregroundStyle(.orange)
            }
            if case .lockSignature = problem, let wait = state.lockWait {
                LockSignNote(command: wait.signCommand)
            } else if let cause {
                Text(cause)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionButton
        }
        .disabled(busy)
    }

    private var cause: String? {
        if case .unavailable = problem { return TunnelStateMapping.simulatorUnavailableMessage }
        return state.vpnDetail
    }

    @ViewBuilder private var actionButton: some View {
        switch problem {
        case .vpnOff:
            button("VPN 켜기", actions.connectTunnel)
        case .needsLogin(let hasURL):
            if hasURL, let url = state.loginURL {
                Button {
                    actions.openLogin(url)
                } label: {
                    Label("로그인 페이지 열기", systemImage: "safari")
                }
                .bold()
            } else {
                ProgressView().accessibilityLabel("tailnet 로그인 주소를 받는 중입니다.")
            }
        case .failed(let running):
            button("다시 연결", running ? actions.restartTunnel : actions.connectTunnel)
        case .unavailable, .lockSignature:
            EmptyView()
        }
    }

    private func button(_ title: LocalizedStringKey, _ work: @escaping @MainActor @Sendable () async -> Void) -> some View {
        Button(title) {
            busy = true
            Task {
                await work()
                busy = false
            }
        }
        .bold()
    }
}

// MARK: - 상세

/// 연결 상세: 페어링한 Mac, VPN의 모든 컨트롤, RD 업데이트. 정상일 때는 여기까지 올 일이 없다.
struct ConnectionDetailView: View {
    var state: PhoneViewState
    var actions: PhoneActions
    var pairAnotherMac: () -> Void

    var body: some View {
        List {
            if let host = state.host {
                Section {
                    LabeledContent {
                        Button("다른 Mac과 페어링", action: pairAnotherMac)
                            .font(.subheadline)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.hostName).font(.headline)
                            Text(host.fqdn)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("페어링한 Mac")
                }
            }
            VPNCard(state: state, actions: actions, showsUpdaterHandover: state.host != nil)
            if state.host != nil {
                UpdaterAppSection(pair: state.vpnPair, actions: actions)
            }
        }
        .listStyle(.insetGrouped)
        .tint(PhoneTheme.tint)
        .navigationTitle("연결")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// RD 업데이트 앱의 설치 여부와 열기. VPN을 옮기는 단추는 VPN 칸에 있다.
private struct UpdaterAppSection: View {
    var pair: VPNPairState
    var actions: PhoneActions
    @State private var openFailed = false

    private var installed: Bool { pair.installed != nil || pair.present || pair.owner == .pairedApp }

    var body: some View {
        Section {
            Label(title, systemImage: installed ? "checkmark.circle.fill" : "xmark.circle")
            if installed {
                Button {
                    Task { openFailed = await !actions.openUpdaterApp() }
                } label: {
                    Label("RD 업데이트 열기", systemImage: "arrow.up.forward.app")
                }
            }
            if openFailed {
                Label("RD 업데이트를 열지 못했습니다. 아래 RD 업데이트 빌드 칸에서 설치하세요.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("RD 업데이트")
        } footer: {
            Text(footer)
        }
    }

    private var title: String {
        guard installed else { return String(localized: "RD 업데이트가 설치되어 있지 않습니다") }
        guard let app = pair.installed else { return String(localized: "RD 업데이트 설치됨") }
        return String(localized: "RD 업데이트 \(app.version) (\(app.buildNumber)) 설치됨")
    }

    /// VPN은 한 번에 한 앱만 켤 수 있다는 규칙을 여기서 한 번만 말한다.
    private var footer: String {
        if !installed {
            return pair.published == nil
                ? String(localized: "RemoteDebug의 새 빌드는 RD 업데이트에서 설치합니다. Mac에서 RD 업데이트를 게시하면 빌드 목록의 RD 업데이트 빌드에서 설치할 수 있습니다.")
                : String(localized: "RemoteDebug의 새 빌드는 RD 업데이트에서 설치합니다. 빌드 목록의 RD 업데이트 빌드에서 설치하세요.")
        }
        return String(localized: "RemoteDebug의 새 빌드는 RD 업데이트에서, RD 업데이트의 새 빌드는 빌드 목록에서 설치합니다. VPN은 한 번에 한 앱만 켤 수 있습니다.")
    }
}

// MARK: - 업데이트 알림

/// 할 일이 있을 때만 보이는 칸: RemoteDebug의 새 빌드가 Mac에 있다. 설치는 RD 업데이트에서 한다.
struct UpdateNoticeSection: View {
    var pair: VPNPairState
    var actions: PhoneActions
    @State private var openFailed = false

    var body: some View {
        if pair.hasNewerStoreBuild {
            Section {
                Label("새 RemoteDebug 빌드가 있습니다. RD 업데이트에서 설치하세요.", systemImage: "arrow.down.app")
                    .font(.subheadline)
                Button {
                    Task { openFailed = await !actions.openUpdaterApp() }
                } label: {
                    Label("RD 업데이트 열기", systemImage: "arrow.up.forward.app")
                }
                .bold()
                if openFailed {
                    Label("RD 업데이트를 열지 못했습니다. 아래 RD 업데이트 빌드 칸에서 설치하세요.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
