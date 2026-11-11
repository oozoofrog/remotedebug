import Foundation
import PhoneClientKit
import RDModels

/// 화면이 그리는 값. `ClientModel`과 `TunnelController`에서 만들고, 미리보기는 직접 만든다.
struct PhoneViewState {
    var phase: ClientModel.Phase = .unpaired
    var host: PairedHost?
    var pairingExpiresAt: Date?
    var queuedPairingHost: String?
    var pendingReplacementHost: String?
    var builds: [BuildDescriptor] = []
    var buildsLoadedAt: Date?
    var refreshError: String?
    var installs: [String: InstallState] = [:]
    var tunnel: TunnelState = .off
    /// `false`면 VPN 컨트롤을 비활성화한다(시뮬레이터).
    var tunnelAvailable = true
    /// 시스템 VPN이 켜져 있거나 켜지는 중이다. `tunnel`이 `failed`여도 VPN은 돌고 있을 수 있다(코어 오류).
    var tunnelActive = false
    var lastError: String?
    var isRefreshing = false
    var needsTunnel = false
}

extension PhoneViewState {
    @MainActor
    init(model: ClientModel, tunnelAvailable: Bool, tunnelActive: Bool) {
        self.init(
            phase: model.phase,
            host: model.host,
            pairingExpiresAt: model.pairingExpiresAt,
            queuedPairingHost: model.queuedPairing?.host,
            pendingReplacementHost: model.pendingReplacement?.host,
            builds: model.builds,
            buildsLoadedAt: model.buildsLoadedAt,
            refreshError: model.refreshError,
            installs: model.installs,
            tunnel: model.tunnel,
            tunnelAvailable: tunnelAvailable,
            tunnelActive: tunnelActive,
            lastError: model.lastError,
            isRefreshing: model.isRefreshing,
            needsTunnel: model.needsTunnel
        )
    }

    var isPairingInFlight: Bool {
        switch phase {
        case .requestingPairing, .waitingApproval: true
        case .unpaired, .paired: false
        }
    }
}

/// 화면의 의도. 실제 앱은 `ClientModel`·`TunnelController`에 연결한다.
@MainActor
struct PhoneActions {
    var pair: (_ host: String, _ code: String) -> Void
    /// QR로 읽은 글자. 페어링 링크가 아니면 안내 문구를 돌려준다.
    var handleScanned: (_ text: String) -> String?
    var cancelPairing: () -> Void
    var confirmReplacement: () -> Void
    var dismissReplacement: () -> Void
    var refresh: @MainActor @Sendable () async -> Void
    var install: (BuildDescriptor) -> Void
    var clearInstall: (_ buildID: String) -> Void
    /// 같은 설치 세션의 iOS 설치 창을 다시 연다.
    var reopenInstaller: @MainActor @Sendable (_ buildID: String) async -> Void
    /// iOS 설치기를 기다리는 설치를 그만둔다.
    var cancelInstall: (_ buildID: String) -> Void
    var connectTunnel: @MainActor @Sendable () async -> Void
    var disconnectTunnel: @MainActor @Sendable () async -> Void
    /// 켜져 있는 VPN을 끄고, 꺼질 때까지 기다린 뒤 다시 켠다.
    var restartTunnel: @MainActor @Sendable () async -> Void
    var openLogin: (URL) -> Void
    var connectWithAuthKey: @MainActor @Sendable (_ key: String) async -> Void
    var clearError: () -> Void
}

/// 설정 화면이 그리는 값.
struct SettingsViewState {
    var host: PairedHost?
    var nodeHostname: String
    var vpnStatusLabel: String
    var reply: TunnelStatusReply?
    var disconnectMessage: String?
    var controlURL: String
}

@MainActor
struct SettingsActions {
    var forgetHost: @MainActor @Sendable () async -> Void
    /// 저장하면 `true`. 형식이 틀리면 `false`.
    var saveControlURL: (String) -> Bool
}
