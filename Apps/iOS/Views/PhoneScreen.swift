import PhoneClientKit
import RDModels
import SwiftUI

/// 앱의 한 화면. 상태(`PhoneViewState`)만 그리고 동작은 `PhoneActions`로 넘긴다.
struct PhoneScreen: View {
    var state: PhoneViewState
    var actions: PhoneActions
    var settings: SettingsViewState?
    var settingsActions: SettingsActions?

    @State private var showsSettings = false
    @State private var showsPairingSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhoneHero(hostName: state.host?.hostName)
                }

                if let message = state.lastError {
                    ErrorBanner(message: message, dismiss: actions.clearError)
                }

                if let mismatch = state.tailnetMismatch {
                    TailnetMismatchSection(phone: mismatch.phone, mac: mismatch.mac, relogin: actions.reloginTunnel)
                }

                VPNCard(state: state, actions: actions)

                VPNPairSection(pair: state.vpnPair, actions: actions)

                if state.host != nil {
                    UpdaterBuildsSection(state: state, actions: actions)
                }

                if state.host == nil, !state.isPairingInFlight, state.queuedPairingHost == nil {
                    Section {
                        PairingForm(pair: actions.pair, handleScanned: actions.handleScanned, onSubmit: {})
                    } header: {
                        Text("Mac 페어링")
                    } footer: {
                        Text("Mac 앱의 페어링 화면에 있는 QR 코드를 스캔하거나 주소와 코드를 입력하세요.")
                    }
                }

                PairingProgressSection(state: state, cancel: actions.cancelPairing)

                if let host = state.host {
                    Section {
                        LabeledContent {
                            Button("다른 Mac과 페어링") { showsPairingSheet = true }
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

                    BuildListSection(state: state, actions: actions)
                }
            }
            .listStyle(.insetGrouped)
            .tint(PhoneTheme.tint)
            .refreshable {
                if state.host != nil { await actions.refresh() }
            }
            .navigationTitle("RemoteDebug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if settings != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsSettings = true
                        } label: {
                            Label("설정", systemImage: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                if let settings, let settingsActions {
                    SettingsView(state: settings, actions: settingsActions)
                }
            }
            .sheet(isPresented: $showsPairingSheet) {
                NavigationStack {
                    Form {
                        Section {
                            PairingForm(pair: actions.pair, handleScanned: actions.handleScanned) {
                                showsPairingSheet = false
                            }
                        } footer: {
                            Text("새 Mac이 승인하기 전까지는 지금 Mac을 계속 사용합니다.")
                        }
                    }
                    .navigationTitle("다른 Mac과 페어링")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("닫기") { showsPairingSheet = false }
                        }
                    }
                }
            }
            .alert(
                "다른 Mac과 페어링할까요?",
                isPresented: Binding(
                    get: { state.pendingReplacementHost != nil },
                    set: { presented in if !presented { actions.dismissReplacement() } }
                ),
                presenting: state.pendingReplacementHost
            ) { _ in
                Button("페어링 요청") { actions.confirmReplacement() }
                Button("취소", role: .cancel) { actions.dismissReplacement() }
            } message: { newHost in
                Text(replacementMessage(newHost: newHost))
            }
        }
    }

    private func replacementMessage(newHost: String) -> String {
        if let current = state.host {
            return "\(newHost)에 페어링을 요청합니다. 새 Mac이 승인하기 전까지는 지금 Mac(\(current.hostName))을 계속 사용합니다."
        }
        return "진행 중인 페어링을 멈추고 \(newHost)에 페어링을 요청합니다."
    }
}

// MARK: - 오류 배너

struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("안내 닫기")
            }
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - 다른 tailnet

/// iPhone이 Mac과 다른 Tailscale 계정(tailnet)에 로그인했다. 이대로는 Mac에 닿지 못한다.
struct TailnetMismatchSection: View {
    var phone: String
    var mac: String
    var relogin: @MainActor @Sendable () async -> Void
    @State private var working = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Mac과 다른 Tailscale 계정에 로그인됨", systemImage: "person.2.slash")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("이 iPhone은 \(phone)에, Mac은 \(mac)에 있어 서로 닿지 않습니다. Mac과 같은 계정으로 다시 로그인하세요.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    working = true
                    Task {
                        await relogin()
                        working = false
                    }
                } label: {
                    HStack {
                        Text("다른 계정으로 로그인")
                        if working { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
            }
            .padding(.vertical, 4)
        } footer: {
            Text("이 iPhone에 저장된 Tailscale 로그인을 지우고 VPN을 다시 켭니다. 로그인 페이지가 나오면 Mac과 같은 계정을 고르세요.")
        }
    }
}

/// 업데이트 앱(RD 업데이트)의 상태와, 두 앱 사이에서 VPN을 옮기는 동작. RemoteDebug의 새 빌드는 업데이트 앱에서 설치한다.
struct VPNPairSection: View {
    var pair: VPNPairState
    var actions: PhoneActions
    @State private var working = false
    @State private var openFailed = false

    private var updaterAvailable: Bool { pair.installed != nil || pair.owner == .pairedApp }

    var body: some View {
        Section {
            Label(title, systemImage: pair.owner == .pairedApp ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .foregroundStyle(pair.owner == .pairedApp ? Color.green : Color.primary)
            if pair.hasNewerStoreBuild {
                Label("새 RemoteDebug 빌드가 있습니다. 업데이트 앱에서 설치하세요.", systemImage: "arrow.down.app")
                    .font(.subheadline)
            }
            if updaterAvailable || pair.hasNewerStoreBuild {
                button("업데이트 앱 열기", "arrow.up.forward.app") { openFailed = await !actions.openUpdaterApp() }
            }
            if openFailed {
                Label("업데이트 앱을 열지 못했습니다. 아래 RD 업데이트 빌드 칸에서 설치하세요.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if updaterAvailable {
                switch pair.owner {
                case .thisApp:
                    button("업데이트 앱으로 VPN 옮기기", "arrow.left.arrow.right", actions.moveVPNToUpdater)
                case .pairedApp:
                    button("이 앱으로 VPN 넘겨받기", "arrow.left.arrow.right", actions.takeOverVPN)
                case .none:
                    button("업데이트 앱에서 VPN 켜기", "power", actions.moveVPNToUpdater)
                case .other:
                    EmptyView()
                }
            }
        } header: {
            Text("업데이트 앱")
        } footer: {
            Text(footer)
        }
        .disabled(working)
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            working = true
            Task {
                await action()
                working = false
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var title: String {
        switch pair.owner {
        case .pairedApp: return "업데이트 앱이 VPN을 켜 두었습니다"
        case .thisApp: return pair.installed == nil ? "이 앱이 VPN을 켜 두었습니다" : "이 앱이 VPN을 켜 두었습니다 · 업데이트 앱 \(version)"
        case .other: return "다른 앱의 VPN이 켜져 있습니다"
        case .none: return pair.installed == nil ? "업데이트 앱이 설치되어 있지 않습니다" : "업데이트 앱 \(version) 설치됨"
        }
    }

    private var version: String {
        pair.installed.map { "\($0.version) (\($0.buildNumber))" } ?? ""
    }

    private var footer: String {
        if !updaterAvailable {
            return pair.published == nil
                ? "RemoteDebug의 새 빌드는 업데이트 앱(RD 업데이트)에서 설치합니다. Mac에서 RemoteDebugVPN 스킴을 게시하면 아래 RD 업데이트 빌드 칸에서 설치할 수 있습니다."
                : "RemoteDebug의 새 빌드는 업데이트 앱(RD 업데이트)에서 설치합니다. 아래 RD 업데이트 빌드 칸에서 설치하세요."
        }
        return "RemoteDebug의 새 빌드는 업데이트 앱에서, 업데이트 앱의 새 빌드는 아래 빌드 목록에서 설치합니다. 두 앱은 같은 tailnet 기기로 연결하고, 한 번에 한 앱만 VPN을 켭니다."
    }
}
