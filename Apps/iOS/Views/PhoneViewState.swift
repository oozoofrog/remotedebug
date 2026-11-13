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
    /// Mac에 게시된 이 앱 자신의 새 빌드. 없으면 `nil`.
    var selfUpdate: BuildDescriptor?
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
    /// Mac이 보낸 파일.
    var resources: [ResourceDescriptor] = []
    /// 이 iPhone에 받아 둔 파일.
    var receivedFiles: [ReceivedFile] = []
    var fileDownloads: [String: FileDownloadState] = [:]
    var fileProgress: [String: FileTransferProgress] = [:]
    /// 게시된 빌드의 번들 ID별로 이 iPhone에 설치된 버전. 읽지 못한 앱은 없다.
    var installedApps: [String: InstalledApp] = [:]
    /// Mac의 에이전트 요청 상태. 아직 받지 못했으면 `nil`.
    var agentBoard: AgentBoard?
    var agentError: String?
    /// 이 iPhone 노드의 MagicDNS 이름(VPN이 연결됐을 때).
    var nodeFQDN: String?
    /// 진행 중이거나 VPN을 기다리는 페어링의 Mac 주소.
    var pairingHost: String?
}

extension PhoneViewState {
    @MainActor
    init(model: ClientModel, tunnelAvailable: Bool, tunnelActive: Bool, installedAt: Date? = nil, nodeFQDN: String? = nil) {
        self.init(
            phase: model.phase,
            host: model.host,
            pairingExpiresAt: model.pairingExpiresAt,
            queuedPairingHost: model.queuedPairing?.host,
            pendingReplacementHost: model.pendingReplacement?.host,
            builds: model.builds,
            selfUpdate: SelfUpdate.candidate(in: model.builds, bundleID: Bundle.main.bundleIdentifier, installedAt: installedAt),
            buildsLoadedAt: model.buildsLoadedAt,
            refreshError: model.refreshError,
            installs: model.installs,
            tunnel: model.tunnel,
            tunnelAvailable: tunnelAvailable,
            tunnelActive: tunnelActive,
            lastError: model.lastError,
            isRefreshing: model.isRefreshing,
            needsTunnel: model.needsTunnel,
            resources: model.resources,
            receivedFiles: model.receivedFiles,
            fileDownloads: model.fileDownloads,
            fileProgress: model.fileProgress
        )
        self.nodeFQDN = nodeFQDN
        self.pairingHost = model.pairingHost
        self.agentBoard = model.agentBoard
        self.agentError = model.agentError
    }

    /// iPhone이 Mac과 다른 tailnet에 로그인했으면 두 tailnet 이름. 같거나 모르면 `nil`.
    var tailnetMismatch: (phone: String, mac: String)? {
        let mac = host?.fqdn ?? pairingHost ?? queuedPairingHost
        guard TailnetMatch.isDifferent(phone: nodeFQDN, host: mac),
              let phoneNet = TailnetMatch.tailnet(of: nodeFQDN), let macNet = TailnetMatch.tailnet(of: mac)
        else { return nil }
        return (phoneNet, macNet)
    }

    /// Mac 목록의 이 파일과 같은 내용으로 받아 둔 파일.
    func receivedFile(for resource: ResourceDescriptor) -> ReceivedFile? {
        receivedFiles.first { $0.name == resource.name && $0.size == resource.size && $0.sha256 == resource.sha256.lowercased() }
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
    /// Mac이 알려 준 이 앱의 업데이트 페이지(공식 Tailscale 주소)를 Safari로 연다.
    var openInstallPage: () -> Void = {}
    /// 저장된 Tailscale 로그인을 지우고 VPN을 다시 켠다(다른 계정으로 로그인).
    var reloginTunnel: @MainActor @Sendable () async -> Void = {}
    var connectWithAuthKey: @MainActor @Sendable (_ key: String) async -> Void
    var clearError: () -> Void
    /// Mac이 보낸 파일을 받아 Documents에 저장한다.
    var downloadFile: (ResourceDescriptor) -> Void = { _ in }
    var cancelDownload: (_ resourceID: String) -> Void = { _ in }
    var deleteReceivedFile: (_ name: String) -> Void = { _ in }
    var refreshAgent: @MainActor @Sendable () async -> Void = {}
    /// 요청을 Mac의 에이전트에 보낸다. 실패하면 안내 문구를 돌려준다.
    var sendAgentRequest: @MainActor @Sendable (AgentSubmission) async -> String? = { _ in nil }
    var cancelAgentRequest: @MainActor @Sendable (_ id: String) async -> Void = { _ in }
}

/// 설정 화면이 그리는 값.
struct SettingsViewState {
    var host: PairedHost?
    var nodeHostname: String
    var vpnStatusLabel: String
    var reply: TunnelStatusReply?
    var disconnectMessage: String?
    var controlURL: String
    /// 이 앱의 버전 `0.1.0 (1)`.
    var appVersion: String = ""
    /// 이 빌드를 처음 실행한 시각(설치 직후).
    var installedAt: Date?
    /// 진단 로그.
    var recentLogs: [DeviceLogEntry] = []
    var unsentLogCount = 0
    var logsSentAt: Date?
    var logSendError: String?
    var isSendingLogs = false
    /// Mac에 보낼 수 있는지(페어링했고 VPN이 연결됨).
    var canSendLogs = false
    /// 모은 크래시 기록(최근 것이 앞).
    var crashes: [CrashBook.Item] = []
    var crashSendError: String?
}

@MainActor
struct SettingsActions {
    var forgetHost: @MainActor @Sendable () async -> Void
    /// 저장하면 `true`. 형식이 틀리면 `false`.
    var saveControlURL: (String) -> Bool
    var sendLogs: @MainActor @Sendable () async -> Void = {}
    var openInstallPage: () -> Void = {}
    /// iPhone 설정 앱을 연다(분석 데이터 화면을 먼저 시도한다).
    var openAnalyticsData: () -> Void = {}
    /// RemoteDebug 앱에 대한 피드백을 기록에 더하고 Mac에 보낸다. `includeLogs`면 최근 진단 로그를 붙인다.
    var sendFeedback: @MainActor @Sendable (_ message: String, _ includeLogs: Bool) async -> Void = { _, _ in }
    var crashText: (CrashBook.Item) -> String? = { _ in nil }
    var crashFile: (CrashBook.Item) -> URL? = { _ in nil }
    var deleteCrash: (_ id: String) -> Void = { _ in }
    /// 크래시 파일을 읽어 기록에 더한다. 실패하면 안내 문구를 돌려준다.
    var importCrash: @MainActor @Sendable (URL) async -> String? = { _ in nil }
}
