#if DEBUG
import PhoneClientKit
import RDModels
import SwiftUI

// 상태별 미리보기. 이 파일의 값은 미리보기 전용이며 실제 화면에는 나오지 않는다.

@MainActor
enum PreviewFixtures {
    static let host = PairedHost(
        hostId: "h_preview",
        hostName: "미리보기 Mac",
        fqdn: "preview-mac.example.ts.net",
        pairedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    static func build(_ id: String, name: String, version: String, number: String, size: Int64, expires: Date = .now.addingTimeInterval(86_400 * 200)) -> BuildDescriptor {
        BuildDescriptor(
            id: id,
            bundleId: "com.example.preview.\(id)",
            displayName: name,
            version: version,
            buildNumber: number,
            minOS: "26.0",
            debug: true,
            configuration: "Debug",
            configurationEvidence: .path,
            signing: .init(teamId: "PREVIEW000", profileName: "Preview Development", profileExpires: expires, provisionedDeviceCount: 3, getTaskAllow: true),
            ipa: .init(size: size, sha256: String(repeating: "0", count: 64)),
            publishedAt: .now.addingTimeInterval(-3600)
        )
    }

    static let buildA = build("b_aaaa0001", name: "미리보기 앱 A", version: "1.4.0", number: "52", size: 48_300_000)
    static let buildB = build("b_bbbb0002", name: "미리보기 앱 B", version: "0.9.1", number: "7", size: 12_800_000)

    static let actions = PhoneActions(
        pair: { _, _ in },
        handleScanned: { _ in nil },
        cancelPairing: {},
        confirmReplacement: {},
        dismissReplacement: {},
        refresh: {},
        install: { _ in },
        clearInstall: { _ in },
        reopenInstaller: { _ in },
        cancelInstall: { _ in },
        connectTunnel: {},
        disconnectTunnel: {},
        restartTunnel: {},
        openLogin: { _ in },
        connectWithAuthKey: { _ in },
        clearError: {}
    )

    static let settings = SettingsViewState(
        host: host,
        nodeHostname: "rd-phone-0a1b2c3d",
        vpnStatusLabel: "연결됨",
        reply: TunnelStatusReply(
            phase: .running,
            status: CoreStatus(
                backendState: .running,
                hostname: "rd-phone-0a1b2c3d",
                fqdn: "rd-phone-0a1b2c3d.example.ts.net",
                tailscaleIPs: ["100.64.0.11", "fd7a:115c:a1e0::b"],
                rssMiB: 27.5,
                tunnel: TunnelStatus(addresses: ["100.64.0.11/32"], routes: ["100.64.0.10/32", "100.100.100.100/32"], mtu: 1280, peerCount: 1)
            ),
            physFootprintMiB: 33.2
        ),
        disconnectMessage: nil,
        controlURL: ""
    )

    static let settingsActions = SettingsActions(forgetHost: {}, saveControlURL: { _ in true })

    static func paired(_ tunnel: TunnelState = .connected, builds: [BuildDescriptor] = [], installs: [String: InstallState] = [:]) -> PhoneViewState {
        PhoneViewState(
            phase: .paired,
            host: host,
            builds: builds,
            buildsLoadedAt: .now.addingTimeInterval(-120),
            installs: installs,
            tunnel: tunnel
        )
    }
}

@MainActor
private func screen(_ state: PhoneViewState) -> some View {
    PhoneScreen(
        state: state,
        actions: PreviewFixtures.actions,
        settings: PreviewFixtures.settings,
        settingsActions: PreviewFixtures.settingsActions
    )
}

#Preview("① 미페어링") {
    screen(PhoneViewState(tunnel: .off))
}

#Preview("② 승인 대기") {
    screen(PhoneViewState(
        phase: .waitingApproval(deviceName: "iPhone"),
        pairingExpiresAt: .now.addingTimeInterval(272),
        tunnel: .connected
    ))
}

#Preview("②-1 페어링 요청 중") {
    screen(PhoneViewState(phase: .requestingPairing, tunnel: .connected))
}

#Preview("③ VPN 꺼짐") {
    var state = PreviewFixtures.paired(.off)
    state.buildsLoadedAt = nil
    state.needsTunnel = true
    return screen(state)
}

#Preview("④ VPN 연결 중") {
    var state = PreviewFixtures.paired(.connecting)
    state.buildsLoadedAt = nil
    return screen(state)
}

#Preview("⑤ VPN 로그인 필요") {
    var state = PreviewFixtures.paired(.needsLogin(authURL: URL(string: "https://login.example.com/a/preview")))
    state.buildsLoadedAt = nil
    return screen(state)
}

#Preview("⑥ 연결됨 · 빌드 없음") {
    screen(PreviewFixtures.paired())
}

#Preview("⑦ 연결됨 · 빌드 2개") {
    screen(PreviewFixtures.paired(builds: [PreviewFixtures.buildA, PreviewFixtures.buildB]))
}

#Preview("⑧ 설치 진행") {
    screen(PreviewFixtures.paired(
        builds: [PreviewFixtures.buildA, PreviewFixtures.buildB],
        installs: [
            PreviewFixtures.buildA.id: .transferring(bytesServed: 20_100_000, size: 48_300_000),
            PreviewFixtures.buildB.id: .waitingForInstaller,
        ]
    ))
}

#Preview("⑨ 설치 완료 · 개발자 모드 안내") {
    screen(PreviewFixtures.paired(
        builds: [PreviewFixtures.buildA],
        installs: [PreviewFixtures.buildA.id: .completed]
    ))
}

#Preview("⑩ 설치 실패 · 만료") {
    screen(PreviewFixtures.paired(
        builds: [PreviewFixtures.buildA, PreviewFixtures.buildB],
        installs: [
            PreviewFixtures.buildA.id: .failed(message: ClientModel.sessionFailedMessage),
            PreviewFixtures.buildB.id: .expired,
        ]
    ))
}

#Preview("⑪ 다른 Mac 교체 확인") {
    var state = PreviewFixtures.paired(builds: [PreviewFixtures.buildA])
    state.pendingReplacementHost = "other-mac.example.ts.net"
    return screen(state)
}

#Preview("⑫ 오류") {
    var state = PreviewFixtures.paired(builds: [PreviewFixtures.buildA])
    state.lastError = HostAPIError(status: 0, code: HostAPIError.connectionFailedCode, message: "").userMessage
    state.refreshError = state.lastError
    return screen(state)
}

#Preview("VPN 사용할 수 없음(시뮬레이터)") {
    screen(PhoneViewState(tunnel: .failed(message: TunnelStateMapping.simulatorUnavailableMessage), tunnelAvailable: false))
}

#Preview("VPN 끄는 중") {
    screen(PreviewFixtures.paired(.disconnecting, builds: [PreviewFixtures.buildA]))
}

#Preview("VPN 켜짐 · tailnet 오류") {
    var state = PreviewFixtures.paired(.failed(message: TunnelStateMapping.backendErrorMessage(cause: "unable to reach the control server")), builds: [PreviewFixtures.buildA])
    state.tunnelActive = true
    return screen(state)
}

#Preview("VPN 끊김 · 다시 연결 제안") {
    var state = PreviewFixtures.paired(.failed(message: TunnelEngineMessages.tunDeviceClosed + " 앱에서 VPN을 다시 켜세요."), builds: [PreviewFixtures.buildA])
    state.needsTunnel = true
    return screen(state)
}

#Preview("설정") {
    SettingsView(state: PreviewFixtures.settings, actions: PreviewFixtures.settingsActions)
}
#endif
