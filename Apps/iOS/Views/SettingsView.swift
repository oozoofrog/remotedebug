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
    @State private var updaterOpenFailed = false

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
                logSection
                CrashSection(state: state, actions: actions)
                advancedSection
                appSection
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

    // MARK: 진단 로그

    private var logSection: some View {
        Section {
            LabeledContent("보내지 않은 줄", value: "\(state.unsentLogCount)")
            if let sent = state.logsSentAt {
                LabeledContent("마지막으로 보냄", value: sent.formatted(date: .omitted, time: .standard))
            }
            if let error = state.logSendError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await actions.sendLogs() }
            } label: {
                HStack {
                    Text("Mac에 지금 보내기")
                    if state.isSendingLogs {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!state.canSendLogs || state.isSendingLogs)
            NavigationLink("최근 로그 \(state.recentLogs.count)줄") {
                LogListView(entries: state.recentLogs)
            }
            .disabled(state.recentLogs.isEmpty)
        } header: {
            Text("진단 로그")
        } footer: {
            Text(state.canSendLogs
                 ? "빌드 목록을 받을 때마다 자동으로 보냅니다. Mac 앱의 로그 화면에서 볼 수 있습니다."
                 : "VPN이 연결되고 Mac과 페어링되어 있어야 보낼 수 있습니다. 그 전까지는 이 iPhone에 남겨 둡니다.")
        }
    }

    // MARK: 이 앱

    private var appSection: some View {
        Section {
            LabeledContent("버전", value: state.appVersion)
            LabeledContent("처음 실행", value: state.installedAt?.formatted(date: .abbreviated, time: .standard) ?? "알 수 없음")
            Button {
                Task { updaterOpenFailed = await !actions.openUpdaterApp() }
            } label: {
                Label("업데이트 앱 열기", systemImage: "arrow.up.forward.app")
            }
            if updaterOpenFailed {
                Label("업데이트 앱을 열지 못했습니다. 빌드 목록에서 RD 업데이트를 설치하세요.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("이 앱")
        } footer: {
            Text("이 앱의 새 빌드는 업데이트 앱(RD 업데이트)에서 설치합니다. 업데이트 앱이 없으면 빌드 목록에서 RD 업데이트를 설치하세요.")
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

/// 이 iPhone에 남은 최근 로그(새 것부터).
struct LogListView: View {
    let entries: [DeviceLogEntry]

    var body: some View {
        List(entries.reversed()) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.at.formatted(date: .omitted, time: .standard))
                        .monospacedDigit()
                    Text(entry.source)
                        .fontWeight(.semibold)
                    if entry.level == .warning || entry.level == .error {
                        Image(systemName: entry.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(entry.level == .error ? .red : .orange)
                            .accessibilityLabel(entry.level == .error ? "오류" : "경고")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("최근 로그")
        .navigationBarTitleDisplayMode(.inline)
    }
}
