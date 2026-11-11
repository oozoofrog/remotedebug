import PhoneClientKit
import RDModels
import SwiftUI

/// 페어링한 Mac 잊기, VPN 진단, 제어 서버 URL.
struct SettingsView: View {
    var state: SettingsViewState
    var actions: SettingsActions

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsForget = false
    @State private var controlURLDraft: String
    @State private var controlURLInvalid = false
    @State private var controlURLSaved = false

    init(state: SettingsViewState, actions: SettingsActions) {
        self.state = state
        self.actions = actions
        _controlURLDraft = State(initialValue: state.controlURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                macSection
                diagnosticsSection
                advancedSection
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .confirmationDialog(
                "이 Mac을 잊을까요?",
                isPresented: $confirmsForget,
                titleVisibility: .visible
            ) {
                Button("Mac 잊기", role: .destructive) {
                    Task {
                        await actions.forgetHost()
                        dismiss()
                    }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("페어링 정보를 지우고 VPN을 끕니다. 다시 쓰려면 Mac에서 새 코드로 페어링해야 합니다.")
            }
        }
    }

    // MARK: Mac

    @ViewBuilder
    private var macSection: some View {
        Section("페어링한 Mac") {
            if let host = state.host {
                LabeledContent("이름", value: host.hostName)
                LabeledContent("주소") {
                    Text(host.fqdn).textSelection(.enabled)
                }
                LabeledContent("페어링한 날", value: host.pairedAt.formatted(date: .abbreviated, time: .shortened))
                Button("이 Mac 잊기", role: .destructive) { confirmsForget = true }
            } else {
                Text("페어링한 Mac이 없습니다.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 진단

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            LabeledContent("이 기기의 tailnet 이름") {
                Text(state.nodeHostname).textSelection(.enabled)
            }
            LabeledContent("VPN", value: state.vpnStatusLabel)
            if let reply = state.reply {
                if let status = reply.status {
                    LabeledContent("tailnet 상태", value: status.backendState.rawValue)
                    if !status.tailscaleIPs.isEmpty {
                        LabeledContent("tailnet 주소") {
                            Text(status.tailscaleIPs.joined(separator: "\n"))
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                    if let tunnel = status.tunnel {
                        LabeledContent("피어", value: "\(tunnel.peerCount)개")
                        LabeledContent("경로", value: "\(tunnel.routes.count)개")
                        LabeledContent("MTU", value: "\(tunnel.mtu)")
                    }
                    LabeledContent("코어 메모리(RSS)", value: Self.mib(status.rssMiB))
                }
                if let footprint = reply.physFootprintMiB {
                    LabeledContent("확장 메모리(phys_footprint)", value: Self.mib(footprint))
                }
                LabeledContent("확장 단계", value: Self.phaseLabel(reply.phase))
            } else {
                Text("VPN이 켜져 있을 때 확장 상태를 표시합니다.")
                    .foregroundStyle(.secondary)
            }
            if let error = state.reply?.lastError ?? state.disconnectMessage {
                LabeledContent("마지막 오류") {
                    Text(error)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("VPN 진단")
        }
    }

    // MARK: 고급

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            TextField("비우면 Tailscale 기본 서버", text: $controlURLDraft)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveControlURL)
                .onChange(of: controlURLDraft) {
                    controlURLInvalid = false
                    controlURLSaved = false
                }
                .accessibilityLabel("제어 서버 URL")
            Button("저장", action: saveControlURL)
                .disabled(controlURLDraft == state.controlURL)
        } header: {
            Text("제어 서버 URL")
        } footer: {
            if controlURLInvalid {
                Text("https://로 시작하는 주소를 입력하세요.").foregroundStyle(.red)
            } else if controlURLSaved {
                Label("저장했습니다. 다음에 VPN을 켤 때 적용됩니다.", systemImage: "checkmark")
            } else {
                Text("다음에 VPN을 켤 때 적용됩니다.")
            }
        }
    }

    private func saveControlURL() {
        if actions.saveControlURL(controlURLDraft) {
            controlURLSaved = true
        } else {
            controlURLInvalid = true
        }
    }

    static func mib(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " MiB"
    }

    static func phaseLabel(_ phase: TunnelExtensionPhase) -> String {
        switch phase {
        case .starting: "시작 중"
        case .running: "실행 중"
        case .stopping: "멈추는 중"
        case .failed: "실패"
        }
    }
}
