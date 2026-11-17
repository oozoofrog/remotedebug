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
                if let message = state.lastError {
                    ErrorBanner(message: message, dismiss: actions.clearError)
                }

                if let mismatch = state.tailnetMismatch {
                    TailnetMismatchSection(phone: mismatch.phone, mac: mismatch.mac, relogin: actions.reloginTunnel)
                }

                ConnectionSection(state: state, actions: actions, pairAnotherMac: { showsPairingSheet = true })

                if state.host != nil {
                    UpdateNoticeSection(pair: state.vpnPair, actions: actions)
                }

                if state.host == nil, !state.isPairingInFlight, state.queuedPairingHost == nil {
                    Section {
                        PairingForm(handleScanned: actions.handleScanned, onSubmit: {}, isPrimary: true)
                    } header: {
                        Text("Mac 페어링")
                    } footer: {
                        Text("Mac 앱의 페어링 화면에 있는 QR 코드를 스캔하세요. Mac이 보낸 링크를 이 iPhone에서 열어도 됩니다.")
                    }
                }

                PairingProgressSection(state: state, cancel: actions.cancelPairing, takeOverVPN: actions.takeOverVPN)

                if state.host != nil {
                    BuildListSection(state: state, actions: actions)
                    UpdaterBuildsSection(state: state, actions: actions)
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
                            PairingForm(handleScanned: actions.handleScanned) {
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
                state.pendingPairing?.fromLink == true ? String(localized: "링크로 페어링할까요?") : String(localized: "다른 Mac과 페어링할까요?"),
                isPresented: Binding(
                    get: { state.pendingPairing != nil },
                    set: { presented in if !presented { actions.dismissPending() } }
                ),
                presenting: state.pendingPairing
            ) { _ in
                Button("페어링 요청") { actions.confirmPending() }
                Button("취소", role: .cancel) { actions.dismissPending() }
            } message: { pending in
                Text(pendingMessage(pending))
            }
        }
    }

    private func pendingMessage(_ pending: PendingPairingPrompt) -> String {
        if pending.fromLink {
            if let current = state.host {
                return String(localized: "\(pending.host)에 페어링을 요청합니다. 이 링크는 다른 앱이나 웹 페이지에서 열렸을 수 있으니, 직접 연 Mac 앱의 링크일 때만 진행하세요. 새 Mac이 승인하기 전까지는 지금 Mac(\(current.hostName))을 계속 사용합니다.")
            }
            return String(localized: "\(pending.host)에 페어링을 요청합니다. 이 링크는 다른 앱이나 웹 페이지에서 열렸을 수 있으니, 직접 연 Mac 앱의 링크일 때만 진행하세요.")
        }
        if let current = state.host {
            return String(localized: "\(pending.host)에 페어링을 요청합니다. 새 Mac이 승인하기 전까지는 지금 Mac(\(current.hostName))을 계속 사용합니다.")
        }
        return String(localized: "진행 중인 페어링을 멈추고 \(pending.host)에 페어링을 요청합니다.")
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
