import PhoneClientKit
import RDModels
import SwiftUI
import UIKit

/// VPN 상태와 켜기·끄기·로그인.
struct VPNCard: View {
    var state: PhoneViewState
    var actions: PhoneActions
    /// 업데이트 앱(RD 업데이트)으로 VPN을 옮기는 단추를 보일지. 페어링 전에는 보이지 않는다.
    var showsUpdaterHandover = false

    @State private var busy = false
    @State private var showsAuthKeySheet = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: state.vpnSymbol)
                    .font(.title2)
                    .foregroundStyle(state.vpnTint)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VPN").font(.headline)
                    Text(state.vpnStatusLabel)
                        .font(.subheadline)
                        .foregroundStyle(state.vpnTint)
                }
                Spacer()
                if isWorking {
                    ProgressView()
                        .accessibilityLabel("VPN \(state.vpnStatusLabel)")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("VPN \(state.vpnStatusLabel)")

            if let detail = state.vpnDetail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let wait = state.lockWait {
                LockSignNote(command: wait.signCommand)
            }

            if state.tunnelAvailable {
                controls
            }

            if showsUpdaterHandover, state.tunnelAvailable {
                handoverButton
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
            if state.vpnPair.owner == .other {
                // 다른 앱(공식 Tailscale 앱 등)의 VPN이다. iOS는 VPN을 하나만 켜므로 넘겨받으면 그 VPN은 꺼진다.
                // Mac이 그 앱의 노드를 아직 이 기기로 알지 못할 때(addenda S) 이 앱의 노드로 연결하는 길이다.
                handover("이 앱으로 VPN 가져오기", actions.takeOverVPN)
            }
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
        default: state.isAutoStartingVPN
        }
    }

    /// VPN을 가진 쪽에 따라 RD 업데이트와 VPN을 주고받는 단추 하나. RD 업데이트가 없으면 없다.
    @ViewBuilder private var handoverButton: some View {
        let pair = state.vpnPair
        if pair.installed != nil || pair.present || pair.owner == .pairedApp {
            switch pair.owner {
            case .thisApp:
                handover("RD 업데이트로 VPN 옮기기", actions.moveVPNToUpdater)
            case .pairedApp:
                handover("이 앱으로 VPN 가져오기", actions.takeOverVPN)
            case .none:
                handover("RD 업데이트에서 VPN 켜기", actions.moveVPNToUpdater)
            case .other:
                EmptyView()
            }
        }
    }

    private func handover(_ title: LocalizedStringKey, _ work: @escaping @MainActor @Sendable () async -> Void) -> some View {
        Button {
            run(work)
        } label: {
            Label(title, systemImage: "arrow.left.arrow.right")
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

/// Tailnet Lock 서명 안내: 서명 전에는 다른 기기와 통신하지 못한다. 명령을 복사해 서명 기기에서 실행한다.
struct LockSignNote: View {
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("이 계정은 Tailnet Lock이 켜져 있어, 서명 전에는 Mac과 통신하지 못합니다. 이미 서명된 기기의 터미널에서 아래 명령을 실행하세요.", systemImage: "signature")
                .font(.subheadline)
                .foregroundStyle(.orange)
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button(copied ? String(localized: "복사했습니다") : String(localized: "서명 명령 복사")) {
                UIPasteboard.general.string = command
                copied = true
            }
        }
    }
}
