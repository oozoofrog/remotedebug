import PhoneClientKit
import SwiftUI
import UIKit

@main
struct RemoteDebugPhoneApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
        }
    }
}

/// 앱 수명 동안 하나만 있는 모델과 어댑터.
@MainActor
final class AppServices {
    let tunnel: TunnelController
    let opener: UIKitURLOpener
    let model: ClientModel

    init() {
        let settings = TunnelSettingsStore()
        let tunnel = TunnelController(settings: settings)
        let opener = UIKitURLOpener()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.tunnel = tunnel
        self.opener = opener
        self.model = ClientModel(
            deviceName: UIDevice.current.name,
            client: ClientInfo(osVersion: UIDevice.current.systemVersion, appVersion: appVersion),
            store: UserDefaultsPairedHostStore(),
            opener: opener,
            tunnel: tunnel
        )
    }
}

/// `ClientModel`·`TunnelController`를 화면 값과 동작으로 잇는다.
struct RootView: View {
    let services: AppServices
    @Environment(\.scenePhase) private var scenePhase

    private var model: ClientModel { services.model }
    private var tunnel: TunnelController { services.tunnel }

    var body: some View {
        PhoneScreen(
            state: PhoneViewState(model: model, tunnelAvailable: tunnel.isAvailable, tunnelActive: tunnel.isTunnelActive),
            actions: actions,
            settings: SettingsViewState(
                host: model.host,
                nodeHostname: tunnel.settings.hostname,
                vpnStatusLabel: tunnel.isAvailable ? TunnelStateMapping.label(tunnel.vpnStatus) : "사용할 수 없음",
                reply: tunnel.lastReply,
                disconnectMessage: tunnel.disconnectMessage,
                controlURL: tunnel.settings.controlURL
            ),
            settingsActions: SettingsActions(
                forgetHost: { await model.forgetHost() },
                saveControlURL: { text in
                    guard let normalized = TunnelSettingsStore.normalizedControlURL(text) else { return false }
                    tunnel.settings.controlURL = normalized
                    return true
                }
            )
        )
        .task {
            await tunnel.reload()
            await model.restore()
        }
        .onOpenURL { url in
            model.handle(url: url)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.resumePolling()
                Task { await tunnel.reload() }
            case .background:
                model.stopPolling()
            default:
                break
            }
        }
    }

    private var actions: PhoneActions {
        PhoneActions(
            pair: { host, code in model.pair(code: code, host: host) },
            handleScanned: { text in
                do throws(PairingLinkError) {
                    model.pair(link: try PairingLink.parse(text: text))
                    return nil
                } catch {
                    return error.userMessage
                }
            },
            cancelPairing: { model.cancelPairing() },
            confirmReplacement: { model.confirmReplacement() },
            dismissReplacement: { model.dismissReplacement() },
            refresh: { await model.refresh() },
            install: { model.install($0) },
            clearInstall: { model.clearInstall($0) },
            reopenInstaller: { await model.reopenInstaller($0) },
            cancelInstall: { model.cancelInstall($0) },
            connectTunnel: { await model.connectTunnel() },
            disconnectTunnel: { await model.disconnectTunnel() },
            restartTunnel: {
                // 돌고 있는 터널에 startVPNTunnel을 부르지 않는다. 끈 뒤 꺼질 때까지 기다렸다가 켠다.
                await model.disconnectTunnel()
                await tunnel.waitUntilStopped()
                await model.connectTunnel()
            },
            openLogin: { url in Task { _ = await services.opener.open(url) } },
            connectWithAuthKey: { key in
                // 시스템 VPN이 켜져 있거나 끄는 중이면(로그인 필요·오류 등) 다 꺼진 뒤 인증 키와 함께 다시 켠다.
                if tunnel.isTunnelActive {
                    await model.disconnectTunnel()
                    await tunnel.waitUntilStopped()
                }
                tunnel.setPendingAuthKey(key)
                await model.connectTunnel()
                // 시작 전에 실패했으면 키를 남기지 않는다.
                tunnel.setPendingAuthKey("")
            },
            clearError: { model.clearError() }
        )
    }
}
