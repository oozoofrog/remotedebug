import PhoneClientKit
import RDModels
import SwiftUI
import UIKit

@main
struct RemoteDebugPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
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
    let transfers = FileTransferActivities()
    /// 이 빌드를 처음 실행한 시각. 그 뒤에 게시된 같은 앱의 빌드를 업데이트로 보여 준다.
    let installedAt = SelfUpdate.installDate(of: .main)
    let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

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
            tunnel: tunnel,
            logBook: DeviceLogBook(fileURL: DeviceLogBook.defaultFileURL())
        )
        let transfers = self.transfers
        let model = self.model
        model.onFileTransfer = { transfers.handle($0) }
        // 페어링 링크(QR)에 Mac이 넣은 1회용 Tailscale 키가 있으면 로그인 없이 VPN을 켠다.
        // 앱이 링크로 처음 열릴 때도 쓰이도록 화면보다 먼저 연결한다.
        model.connectWithAuthKey = { [weak model] key in
            guard let model else { return }
            if tunnel.isTunnelActive {
                await model.disconnectTunnel()
                await tunnel.waitUntilStopped()
            }
            tunnel.setPendingAuthKey(key)
            await model.connectTunnel()
            tunnel.setPendingAuthKey("")
        }
        // iOS가 백그라운드에서 앱을 다시 띄운 경우에도 이어 가던 전송을 넘겨받는다(화면이 없어도 실행된다).
        Task { @MainActor in
            let active = await model.attachBackgroundTransfers()
            transfers.endStale(keeping: Set(active))
        }
    }
}

/// `ClientModel`·`TunnelController`를 화면 값과 동작으로 잇는다.
struct RootView: View {
    let services: AppServices
    @Environment(\.scenePhase) private var scenePhase

    private var model: ClientModel { services.model }
    private var tunnel: TunnelController { services.tunnel }

    private var state: PhoneViewState {
        PhoneViewState(model: model, tunnelAvailable: tunnel.isAvailable, tunnelActive: tunnel.isTunnelActive,
                       installedAt: services.installedAt, nodeFQDN: tunnel.lastReply?.status?.fqdn)
    }

    var body: some View {
        let state = self.state
        TabView {
            Tab("빌드", systemImage: "shippingbox") {
                buildsScreen(state)
            }
            Tab("파일", systemImage: "doc.on.doc") {
                FilesScreen(state: state, actions: actions)
            }
            .badge(state.fileDownloads.values.filter { $0 == .downloading }.count)
        }
        .tint(PhoneTheme.tint)
        .task {
            model.log(.info, "app", "앱 시작: 버전 \(services.appVersion), 처음 실행 \(Self.stamp(services.installedAt)), iOS \(UIDevice.current.systemVersion)")
            await tunnel.reload()
            await model.restore()
        }
        .onChange(of: tunnel.disconnectMessage) { _, message in
            if let message { model.log(.warning, "vpn", "터널 종료: \(message)") }
        }
        .onOpenURL { url in
            model.handle(url: url)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
    }

    private func buildsScreen(_ state: PhoneViewState) -> some View {
        PhoneScreen(
            state: state,
            actions: actions,
            settings: SettingsViewState(
                host: model.host,
                nodeHostname: tunnel.settings.hostname,
                vpnStatusLabel: tunnel.isAvailable ? TunnelStateMapping.label(tunnel.vpnStatus) : "사용할 수 없음",
                reply: tunnel.lastReply,
                disconnectMessage: tunnel.disconnectMessage,
                controlURL: tunnel.settings.controlURL,
                appVersion: services.appVersion,
                installedAt: services.installedAt,
                recentLogs: model.logBook.recent,
                unsentLogCount: model.logBook.unsentCount,
                logsSentAt: model.logsSentAt,
                logSendError: model.logSendError,
                isSendingLogs: model.isSendingLogs,
                canSendLogs: model.host != nil && model.tunnel == .connected
            ),
            settingsActions: SettingsActions(
                forgetHost: { await model.forgetHost() },
                saveControlURL: { text in
                    guard let normalized = TunnelSettingsStore.normalizedControlURL(text) else { return false }
                    tunnel.settings.controlURL = normalized
                    return true
                },
                sendLogs: { await model.sendLogs() },
                openInstallPage: openInstallPage
            )
        )
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            model.log(.debug, "app", "앱 활성")
            model.resumePolling()
            // 파일 앱에서 지우거나 바꾼 받은 파일을 다시 읽는다.
            model.reloadReceivedFiles()
            Task {
                await tunnel.reload()
                // 앱으로 돌아올 때 새 빌드(이 앱의 업데이트 포함)를 바로 보여 준다. VPN이 꺼져 있으면 안내를 다시 띄우지 않는다.
                if model.host != nil, model.tunnel == .connected { await model.refresh() }
            }
        case .background:
            model.log(.debug, "app", "앱 백그라운드")
            model.stopPolling()
        default:
            break
        }
    }

    /// 페어링한 Mac의 설치 웹 페이지를 Safari로 연다. 이 iPhone은 이미 허용된 기기라 페이지에 바로 빌드 목록이 나온다.
    private func openInstallPage() {
        guard let url = model.host?.updatePage else { return }
        model.log(.info, "update", "Safari로 업데이트 페이지 열기: \(url.absoluteString), 앱 VPN \(model.tunnel == .connected ? "연결됨" : "연결 안 됨")")
        Task {
            let opened = await services.opener.open(url)
            if !opened { model.log(.error, "update", "Safari를 열지 못함") }
            // Safari로 넘어가 앱이 닫히기 전에 기록을 Mac에 보낸다.
            await model.sendLogs()
        }
    }

    private static func stamp(_ date: Date?) -> String {
        date.map(RDTimestamp.string) ?? "알 수 없음"
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
            openInstallPage: openInstallPage,
            reloginTunnel: {
                model.log(.info, "vpn", "다른 계정으로 로그인: 저장된 Tailscale 로그인을 지우고 VPN을 다시 켭니다")
                if tunnel.isTunnelActive {
                    await model.disconnectTunnel()
                    await tunnel.waitUntilStopped()
                }
                tunnel.setPendingResetLogin()
                await model.connectTunnel()
            },
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
            clearError: { model.clearError() },
            downloadFile: { model.download($0) },
            cancelDownload: { model.cancelDownload($0) },
            deleteReceivedFile: { model.deleteReceivedFile($0) }
        )
    }
}
