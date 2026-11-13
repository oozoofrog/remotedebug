import PhoneClientKit
import RDModels
import SwiftUI

/// VPN 상태와 켜기·끄기·로그인.
struct VPNCard: View {
    var state: PhoneViewState
    var actions: PhoneActions

    @State private var busy = false
    @State private var showsAuthKeySheet = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN").font(.headline)
                    Text(statusLabel)
                        .font(.subheadline)
                        .foregroundStyle(tint)
                }
                Spacer()
                if isWorking {
                    ProgressView()
                        .accessibilityLabel("VPN \(statusLabel)")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("VPN \(statusLabel)")

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if state.tunnelAvailable {
                controls
            }
        }
        .disabled(busy)
        .sheet(isPresented: $showsAuthKeySheet) {
            AuthKeySheet { key in
                showsAuthKeySheet = false
                run { await actions.connectWithAuthKey(key) }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state.tunnel {
        case .off:
            Button("VPN 켜기") { run(actions.connectTunnel) }
                .bold()
            authKeyButton
        case .connecting:
            Button("VPN 끄기", role: .destructive) { run(actions.disconnectTunnel) }
        case .disconnecting:
            // 다 꺼질 때까지 켜기를 받지 않는다.
            EmptyView()
        case .needsLogin(let url):
            if let url {
                Button {
                    actions.openLogin(url)
                } label: {
                    Label("로그인 페이지 열기", systemImage: "safari")
                }
                .bold()
            }
            authKeyButton
            Button("VPN 끄기", role: .destructive) { run(actions.disconnectTunnel) }
        case .connected:
            Button("VPN 끄기", role: .destructive) { run(actions.disconnectTunnel) }
        case .failed:
            if state.tunnelActive {
                // VPN은 켜져 있고 tailnet 쪽만 오류다. 다시 켜려면 먼저 끈다(끄기 → 꺼질 때까지 대기 → 켜기).
                // 꺼진 오류 상태의 버튼과 이름이 같아야 안내 문구(‘다시 연결’)가 두 경우 모두 맞는다.
                Button("다시 연결") { run(actions.restartTunnel) }
                    .bold()
                authKeyButton
                Button("VPN 끄기", role: .destructive) { run(actions.disconnectTunnel) }
            } else {
                Button("다시 연결") { run(actions.connectTunnel) }
                    .bold()
                authKeyButton
            }
        }
    }

    private var authKeyButton: some View {
        Button("인증 키로 켜기") { showsAuthKeySheet = true }
    }

    private func run(_ work: @escaping @MainActor @Sendable () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }

    private var isWorking: Bool {
        switch state.tunnel {
        case .connecting, .disconnecting: true
        default: isAutoStarting
        }
    }

    /// 앱이 VPN을 켜고 연결을 기다리는 중이다.
    private var isAutoStarting: Bool {
        guard state.vpnAutoStarting else { return false }
        switch state.tunnel {
        case .off, .connecting, .disconnecting: return true
        default: return false
        }
    }

    private var statusLabel: String {
        if !state.tunnelAvailable { return "사용할 수 없음" }
        if isAutoStarting { return VPNStatusText.autoStarting }
        switch state.tunnel {
        case .off: return "꺼짐"
        case .connecting: return "연결 중"
        case .disconnecting: return "끄는 중"
        case .needsLogin: return "로그인 필요"
        case .connected: return VPNStatusText.connected(holder: state.vpnPair.owner, path: state.peerPath)
        case .failed: return "오류"
        }
    }

    private var detail: String? {
        switch state.tunnel {
        case .off:
            state.vpnAutoStartReady
                ? "Mac에 연결할 때 자동으로 켜고, 쓰지 않으면 30초 뒤에 끕니다."
                : "Mac과 통신하려면 VPN이 켜져 있어야 합니다. 여기서 한 번 켜 두면 다음부터는 필요할 때 자동으로 켭니다."
        case .connecting, .disconnecting: nil
        case .needsLogin(let url): url == nil ? "tailnet 로그인 주소를 받는 중입니다." : "tailnet에 로그인해야 합니다. 로그인하면 자동으로 연결됩니다."
        case .connected: state.vpnAutoStarted ? "Mac에 연결하려고 자동으로 켰습니다. 쓰지 않으면 30초 뒤에 끕니다." : nil
        case .failed(let message): message
        }
    }

    private var symbol: String {
        if !state.tunnelAvailable { return "network.slash" }
        switch state.tunnel {
        case .off: return "network.slash"
        case .connecting: return "network"
        case .disconnecting: return "network.slash"
        case .needsLogin: return "person.badge.key"
        case .connected: return "checkmark.shield.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        if !state.tunnelAvailable { return .secondary }
        switch state.tunnel {
        case .off: return .secondary
        case .connecting: return .blue
        case .disconnecting: return .secondary
        case .needsLogin: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }
}

/// 처음 로그인용 인증 키 입력. 키는 저장하지 않고 다음 VPN 시작에 한 번만 넘긴다.
struct AuthKeySheet: View {
    var submit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("tskey-auth-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(send)
                        .accessibilityLabel("인증 키")
                } header: {
                    Text("인증 키")
                } footer: {
                    Text("tailnet 관리 콘솔에서 만든 인증 키로 이 기기를 로그인합니다. 키는 앱에 저장하지 않습니다.")
                }
            }
            .navigationTitle("인증 키로 켜기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("VPN 켜기", action: send)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !trimmed.isEmpty else { return }
        submit(trimmed)
        key = ""
    }
}
