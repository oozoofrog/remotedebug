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
    private let directConnection = DirectConnection()
    /// 업데이트 앱을 설치하기 전에 필요하면 VPN을 이 앱으로 넘겨받는다.
    let installer: GuardedInstaller
    private var crashDiagnostics: CrashDiagnostics?
    /// 이 빌드를 처음 실행한 시각. 그 뒤에 게시된 같은 앱의 빌드가 있으면 업데이트 앱에서 설치하라고 알린다.
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
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        self.tunnel = tunnel
        self.opener = opener
        self.installer = GuardedInstaller(tunnel: tunnel, role: .store)
        self.model = ClientModel(
            deviceName: UIDevice.current.name,
            client: ClientInfo(osVersion: UIDevice.current.systemVersion, appVersion: appVersion),
            // 업데이트 앱이 같은 Mac을 보도록 공용 설정에 둔다. 예전 값은 처음 한 번 옮긴다.
            store: UserDefaultsPairedHostStore(defaults: SharedContainer.defaults, legacy: .standard),
            opener: opener,
            tunnel: tunnel,
            logBook: DeviceLogBook(fileURL: DeviceLogBook.defaultFileURL()),
            crashBook: CrashBook(directory: CrashBook.defaultDirectory()),
            direct: directConnection.route,
            // 알림 스위치와 등록 기록은 이 앱 전용 설정에 둔다(업데이트 앱은 알림을 쓰지 않는다).
            push: bundleID.isEmpty ? nil : PushSetup(store: UserDefaultsPushSettingsStore(), bundleId: bundleID)
        )
        directConnection.onNetworkChange = { [weak model] in model?.noteNetworkChange() }
        tunnel.onMemoryLog = { [weak model] line in model?.log(.info, "vpn", line) }
        let transfers = self.transfers
        let model = self.model
        model.onFileTransfer = { transfers.handle($0) }
        let push = PushNotifications.shared
        push.onLog = { [weak model] line in model?.log(.warning, "push", line) }
        push.onForeground = { [weak model] in
            // 앱이 앞에 있을 때 온 알림: 배너와 함께 목록도 새로 받는다. VPN을 켤 수 없으면 받지 않는다.
            guard let model, model.host != nil, model.canReachHost else { return }
            Task { await model.refresh() }
        }
        push.onToken = { [weak model] token in
            guard let model else { return }
            Task { await model.receivePushToken(token) }
        }
        let diagnostics = CrashDiagnostics { [weak model] report in await model?.addCrash(report) }
        diagnostics.start()
        crashDiagnostics = diagnostics
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

/// 아래 탭. 알림을 누르면 알림 종류에 맞는 탭으로 간다.
enum PhoneTab: Hashable {
    case builds, files, agent
}

/// `ClientModel`·`TunnelController`를 화면 값과 동작으로 잇는다.
struct RootView: View {
    let services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @State private var installedApps: [String: InstalledApp] = [:]
    @State private var loggedInstalledApps = false
    /// 이 iPhone에 설치된 업데이트 앱.
    @State private var updaterInstalled: InstalledApp?
    /// 업데이트 앱의 주소를 열 수 있는가. 설치된 버전을 읽지 못하는 iOS에서도 설치 여부는 이것으로 안다.
    @State private var updaterPresent = false
    @State private var mergingIdentity = false
    @State private var crashNotice: String?
    @State private var tab: PhoneTab = .builds

    private var model: ClientModel { services.model }
    private var tunnel: TunnelController { services.tunnel }

    private var state: PhoneViewState {
        var state = PhoneViewState(model: model, tunnelAvailable: tunnel.isAvailable, tunnelActive: tunnel.isTunnelActive,
                                   installedAt: services.installedAt, nodeFQDN: tunnel.lastReply?.status?.fqdn)
        state.installedApps = installedApps
        state.installPreparations = services.installer.preparations
        if model.isAutoStartingVPN {
            // 설치를 눌렀는데 VPN이 꺼져 있었다. 연결될 때까지 빌드 줄에 단계를 보여 준다.
            for (id, install) in model.installs where install == .preparing && state.installPreparations[id] == nil {
                state.installPreparations[id] = .working(VPNStatusText.autoStarting)
            }
        }
        state.vpnAutoStartReady = tunnel.autoStartConfiguration == .ready
        state.peerPath = tunnel.peerPath
        state.vpnPair.owner = tunnel.vpnHolder
        state.vpnPair.installed = updaterInstalled
        state.vpnPair.present = updaterPresent
        state.vpnPair.published = AppBuildFilter.only(AppPair.otherAppID, in: model.builds).first
        return state
    }

    /// 크래시 파일(.ips)을 읽어 기록에 더하고 Mac에 보낸다. 실패하면 안내 문구를 돌려준다.
    private func importCrash(_ url: URL) async -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return String(localized: "\(url.lastPathComponent) 파일을 읽을 수 없습니다.") }
        guard data.count <= CrashReport.maxTextBytes else { return String(localized: "\(url.lastPathComponent)은 너무 큽니다(1.5MB까지).") }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return String(localized: "\(url.lastPathComponent)은 글자로 된 크래시 파일이 아닙니다.") }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        await model.addCrash(CrashReport.ips(name: url.lastPathComponent, text: text, fallbackDate: modified))
        return nil
    }

    /// 게시된 빌드의 앱이 이 iPhone에 어떤 버전으로 설치돼 있는지 다시 읽는다. 결과가 바뀌면 진단 로그에 남긴다.
    private func reloadInstalledApps() {
        let updater = InstalledApps.lookup(AppPair.otherAppID).app
        if updater != updaterInstalled { updaterInstalled = updater }
        let present = AppPair.url(toOther: .open, returning: false).map { UIApplication.shared.canOpenURL($0) } ?? false
        if present != updaterPresent { updaterPresent = present }
        var found: [String: InstalledApp] = [:]
        var traces: [String] = []
        // 이 앱 자신의 빌드는 목록에 없다.
        for bundleID in Set(AppBuildFilter.hiding(Bundle.main.bundleIdentifier, in: model.builds).map(\.bundleId)).sorted() {
            let lookup = InstalledApps.lookup(bundleID)
            found[bundleID] = lookup.app
            traces.append("\(bundleID) [\(lookup.trace)]")
        }
        guard found != installedApps || (installedApps.isEmpty && !traces.isEmpty && !loggedInstalledApps) else { return }
        loggedInstalledApps = true
        installedApps = found
        model.log(.info, "installed", "설치된 앱 조회: \(traces.joined(separator: "; "))")
    }

    var body: some View {
        let state = self.state
        TabView(selection: $tab) {
            Tab("빌드", systemImage: "shippingbox", value: PhoneTab.builds) {
                buildsScreen(state)
            }
            Tab("파일", systemImage: "doc.on.doc", value: PhoneTab.files) {
                FilesScreen(state: state, actions: actions)
            }
            .badge(state.fileDownloads.values.filter { $0 == .downloading }.count)
            if AgentFeature.isEnabled {
                Tab("에이전트", systemImage: "terminal", value: PhoneTab.agent) {
                    AgentScreen(state: state, actions: actions)
                }
                .badge(state.agentBoard?.requests.count { !$0.state.isFinished } ?? 0)
            }
        }
        .tint(PhoneTheme.tint)
        .task {
            model.log(.info, "app", "앱 시작: 버전 \(services.appVersion), 처음 실행 \(Self.stamp(services.installedAt)), iOS \(UIDevice.current.systemVersion)")
            await tunnel.reload()
            // 알림을 켜 두었고 권한이 있으면 토큰을 다시 받는다(바뀔 수 있다). 여기서 권한을 묻지 않는다.
            if model.pushEnabled, await PushNotifications.shared.isAuthorized() {
                PushNotifications.shared.registerForRemoteNotifications()
            }
            await model.restore()
        }
        .onChange(of: PushNotifications.shared.pendingOpen, initial: true) { _, open in
            // 알림이나 동작 버튼을 눌렀다. 앱이 꺼져 있다 시작한 경우에도 화면이 뜬 뒤 여기서 처리한다.
            guard let open else { return }
            PushNotifications.shared.pendingOpen = nil
            switch open.target {
            case .builds: tab = .builds
            case .files: tab = .files
            case .unchanged: break
            }
            Task {
                switch await model.openNotification(open) {
                case .install(let build): services.installer.install(build, with: model)
                case .openLink(let url): _ = await services.opener.open(url)
                case .download(let resource): model.download(resource)
                case .none: break
                }
            }
        }
        .onChange(of: model.host?.fqdn, initial: true) { _, fqdn in
            // 터널이 이 Mac까지의 경로(직접·중계)를 알아보게 한다.
            tunnel.pathPeer = fqdn
        }
        .onChange(of: tunnel.disconnectMessage) { _, message in
            if let message { model.log(.warning, "vpn", "터널 종료: \(message)") }
        }
        .onOpenURL { url in
            // 공유 시트나 파일 앱에서 넘긴 크래시 파일.
            if url.isFileURL {
                Task {
                    let error = await importCrash(url)
                    crashNotice = error ?? (model.crashBook.unsent.isEmpty
                        ? String(localized: "크래시 기록을 Mac에 보냈습니다.")
                        : String(localized: "크래시 기록을 받았습니다. Mac과 연결되면 보냅니다."))
                }
            } else if let request = AppPair.request(from: url) {
                Task { await handleVPNRequest(request.action, returning: request.returning) }
            } else {
                model.handle(url: url)
            }
        }
        .alert("크래시 기록", isPresented: Binding(get: { crashNotice != nil }, set: { if !$0 { crashNotice = nil } })) {
            Button("확인") { crashNotice = nil }
        } message: {
            Text(crashNotice ?? "")
        }
        .onChange(of: model.builds.map(\.bundleId), initial: true) { _, _ in
            reloadInstalledApps()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
    }

    private func buildsScreen(_ state: PhoneViewState) -> some View {
        let settings = SettingsViewState(
                host: model.host,
                nodeHostname: tunnel.settings.hostname,
                vpnStatusLabel: tunnel.isAvailable ? TunnelStateMapping.label(tunnel.vpnStatus) : String(localized: "사용할 수 없음"),
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
                canSendLogs: model.host != nil && model.canReachHost,
                onDemand: tunnel.settings.onDemand,
                canSetOnDemand: tunnel.autoStartConfiguration != .missing,
                crashes: model.crashBook.items,
                crashSendError: model.crashSendError,
                pushEnabled: model.pushEnabled,
                pushStatus: model.isPushAvailable ? model.pushStatus : nil
            )
        let settingsActions = SettingsActions(
                forgetHost: { await model.forgetHost() },
                saveControlURL: { text in
                    guard let normalized = TunnelSettingsStore.normalizedControlURL(text) else { return false }
                    tunnel.settings.controlURL = normalized
                    return true
                },
                sendLogs: { await model.sendLogs() },
                setOnDemand: { enabled in
                    let previous = tunnel.settings.onDemand
                    tunnel.settings.onDemand = enabled
                    do {
                        try await tunnel.syncOnDemand()
                        model.log(.info, "vpn", "주문형 연결 \(enabled ? "켬" : "끔")")
                        return nil
                    } catch {
                        tunnel.settings.onDemand = previous
                        model.log(.warning, "vpn", "주문형 연결 설정 저장 실패: \(error.localizedDescription)")
                        return String(localized: "설정을 저장하지 못했습니다. \(error.localizedDescription)")
                    }
                },
                openUpdaterApp: { await openUpdater(.open, returning: false) },
                openAnalyticsData: openAnalyticsData,
                sendFeedback: { await sendFeedback($0, includeLogs: $1, image: $2) },
                crashText: { model.crashBook.text($0) },
                crashFile: { model.crashBook.fileURL($0) },
                deleteCrash: { model.crashBook.remove($0) },
                importCrash: { await importCrash($0) },
                setPushEnabled: { enabled in
                    let push = PushNotifications.shared
                    guard enabled else {
                        await model.setPushEnabled(false)
                        return true
                    }
                    // 스위치를 켤 때만 권한을 묻는다.
                    guard await push.requestAuthorization() else {
                        model.log(.info, "push", "알림 권한이 없어 알림을 켜지 않음")
                        return false
                    }
                    await model.setPushEnabled(true)
                    push.registerForRemoteNotifications()
                    return true
                },
                pushDenied: { await PushNotifications.shared.isDenied() },
                openNotificationSettings: {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            )
        return PhoneScreen(state: state, actions: actions, settings: settings, settingsActions: settingsActions)
            .environment(\.crashPanel, CrashPanel(state: settings, actions: settingsActions))
    }

    /// RemoteDebug 앱에 대한 피드백을 크래시·피드백 기록에 더한다. Mac과 연결돼 있으면 바로 보낸다.
    private func sendFeedback(_ message: String, includeLogs: Bool, image: Data?) async {
        var details = "iOS: \(UIDevice.current.systemVersion)\nVPN: \(TunnelStateMapping.label(tunnel.vpnStatus))"
        if includeLogs {
            let lines = model.logBook.recent.suffix(100).map(\.line)
            if !lines.isEmpty { details += "\n\n최근 진단 로그\n" + lines.joined(separator: "\n") }
        }
        await model.addCrash(CrashReport.feedback(
            message: message, bundleId: Bundle.main.bundleIdentifier ?? "", appVersion: services.appVersion, details: details, image: image, date: Date()))
    }

    /// 업데이트 앱을 열어 요청을 넘긴다. `returning`이면 업데이트 앱이 일을 마치고 이 앱으로 돌아온다. 열지 못하면 `false`.
    @discardableResult
    private func openUpdater(_ action: AppPair.Action, returning: Bool) async -> Bool {
        guard let url = AppPair.url(toOther: action, returning: returning) else { return false }
        // 업데이트 앱이 켜면 iOS가 이 앱의 터널을 끈다. 따로 끄지 않는다(끄면 그 사이 연결이 비는 시간이 길어진다).
        let opened = await services.opener.open(url)
        if !opened { model.log(.warning, "vpn", "업데이트 앱을 열지 못함(설치돼 있지 않을 수 있음)") }
        return opened
    }

    /// 업데이트 앱이 VPN을 켜 두었는데 이 앱의 페어링한 기기 정보가 아직 공용 저장소로 가지 않았다.
    /// 이대로면 업데이트 앱은 다른 기기로 연결돼 Mac이 받아 주지 않는다. 이 앱의 터널을 한 번 켜서 옮기고 업데이트 앱에 돌려준다.
    private func mergeIdentityIfNeeded() async {
        guard !mergingIdentity, tunnel.pairedAppOwnsVPN, !TunnelStateMapping.isActive(tunnel.vpnStatus),
              !SharedContainer.defaults.bool(forKey: SharedContainer.storeMigratedKey) else { return }
        mergingIdentity = true
        defer { mergingIdentity = false }
        model.log(.info, "vpn", "기기 정보 합치기: 이 앱의 터널을 한 번 켜 페어링한 기기 정보를 공용 저장소로 옮김")
        model.noteManualVPNChange()
        do { try await tunnel.connectOwn() } catch {
            model.log(.error, "vpn", "기기 정보 합치기 실패: \(error.localizedDescription)")
            return
        }
        await tunnel.waitUntilOwnTunnelSettles()
        guard tunnel.state == .connected else {
            model.log(.warning, "vpn", "기기 정보 합치기: 이 앱의 VPN이 연결되지 않아 업데이트 앱으로 돌려주지 않음")
            return
        }
        model.log(.info, "vpn", "기기 정보 합치기 끝. 업데이트 앱으로 VPN을 돌려줌")
        await openUpdater(.connect, returning: true)
    }

    /// 업데이트 앱이 보낸 요청: 이 앱의 터널로 VPN을 켜거나 끈다. `returning`이면 마친 뒤 업데이트 앱으로 돌아간다.
    private func handleVPNRequest(_ action: AppPair.Action, returning: Bool) async {
        switch action {
        case .open:
            return
        case .connect:
            model.log(.info, "vpn", "업데이트 앱의 요청으로 이 앱의 VPN을 켬")
            model.noteManualVPNChange()
            do { try await tunnel.connectOwn() } catch { model.log(.error, "vpn", "켜기 실패: \(error.localizedDescription)") }
            // 터널이 뜨면서 예전 기기 정보를 공용 저장소로 옮긴다. 다 뜬 뒤에 돌아간다.
            await tunnel.waitUntilOwnTunnelSettles()
            // 로그인이 필요하면 이 앱에 머문다.
            if case .needsLogin = tunnel.state { return }
            if returning {
                // 요청한 업데이트 앱이 같은 기기 정보로 다시 켜도록 넘긴다.
                await openUpdater(.connect, returning: true)
                return
            }
        case .disconnect:
            model.log(.info, "vpn", "업데이트 앱의 요청으로 이 앱의 VPN을 끔")
            await model.disconnectTunnel()
            await tunnel.waitUntilStopped()
        }
        if returning { await openUpdater(.open, returning: false) }
    }

    /// iPhone 설정 앱을 연다. 분석 데이터 화면 주소를 먼저 시도하고, 열지 못하면 이 앱의 설정 화면을 연다.
    private func openAnalyticsData() {
        model.log(.info, "crash", "iPhone 설정 열기(분석 데이터)")
        guard let deep = URL(string: "App-prefs:Privacy&path=PROBLEM_REPORTING/DIAGNOSTIC_USAGE_DATA") else { return }
        UIApplication.shared.open(deep) { opened in
            guard !opened, let fallback = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(fallback)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            model.log(.debug, "app", "앱 활성")
            model.resumePolling()
            // 파일 앱에서 지우거나 바꾼 받은 파일을 다시 읽는다.
            model.reloadReceivedFiles()
            // 설치가 끝났거나 홈 화면에서 앱을 지웠을 수 있다.
            reloadInstalledApps()
            Task {
                // 다른 앱의 VPN 여부를 읽은 뒤에 판단한다.
                try? await Task.sleep(for: .seconds(1))
                tunnel.refreshExternal()
                await mergeIdentityIfNeeded()
            }
            Task {
                await tunnel.reload()
                // 앱으로 돌아올 때 새 빌드를 바로 보여 준다. VPN이 꺼져 있으면 자동으로 켤 수 있을 때만 받는다
                // (켤 수 없으면 안내를 다시 띄우지 않는다).
                if model.host != nil, model.canReachHost { await model.refresh() }
            }
        case .background:
            model.log(.debug, "app", "앱 백그라운드")
            model.stopPolling()
        default:
            break
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
            install: { services.installer.install($0, with: model) },
            clearInstall: {
                services.installer.clear($0)
                model.clearInstall($0)
            },
            reopenInstaller: { await model.reopenInstaller($0) },
            cancelInstall: { model.cancelInstall($0) },
            connectTunnel: { await model.connectTunnel() },
            disconnectTunnel: {
                if !TunnelStateMapping.isActive(tunnel.vpnStatus), tunnel.pairedAppOwnsVPN {
                    // 업데이트 앱의 터널이다. 그 앱을 열어 끄고 돌아온다.
                    await openUpdater(.disconnect, returning: true)
                } else {
                    await model.disconnectTunnel()
                }
            },
            restartTunnel: {
                // 돌고 있는 터널에 startVPNTunnel을 부르지 않는다. 끈 뒤 꺼질 때까지 기다렸다가 켠다.
                await model.disconnectTunnel()
                await tunnel.waitUntilStopped()
                await model.connectTunnel()
            },
            openLogin: { url in Task { _ = await services.opener.open(url) } },
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
            moveVPNToUpdater: {
                model.log(.info, "vpn", "VPN을 업데이트 앱으로 옮김")
                await openUpdater(.connect, returning: true)
            },
            takeOverVPN: {
                model.log(.info, "vpn", "업데이트 앱의 VPN을 이 앱으로 넘겨받음")
                model.noteManualVPNChange()
                do { try await tunnel.connectOwn() } catch { model.log(.error, "vpn", "넘겨받기 실패: \(error.localizedDescription)") }
            },
            openUpdaterApp: { await openUpdater(.open, returning: false) },
            clearError: { model.clearError() },
            downloadFile: { model.download($0) },
            cancelDownload: { model.cancelDownload($0) },
            deleteReceivedFile: { model.deleteReceivedFile($0) },
            refreshAgent: { await model.refreshAgent() },
            sendAgentRequest: { await model.sendAgentRequest($0) },
            cancelAgentRequest: { await model.cancelAgentRequest($0) }
        )
    }
}
