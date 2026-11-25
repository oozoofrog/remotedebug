import AppKit
import Foundation
import Observation
import RDModels

/// Mac 앱의 화면 상태와 사용자 의도. SwiftUI 화면은 이 모델만 본다.
///
/// 공유 시작·중지·종료는 한 줄로 순서대로 처리한다. 시작하는 중에 중지·종료를 부르면 시작을 멈추고
/// 코어 중지·라이브러리 비활성화까지 끝난 상태(`isRunning == false`, `isStarting == false`)로 끝난다.
@MainActor
@Observable
public final class HostModel {
    public static let activityLimit = 200
    public static let logLimit = 200
    public static let pairingTTLSeconds = 300
    /// protocol §2: 같은 코드에 5번 틀리면 코어가 코드를 폐기한다.
    public static let pairingMaxFailures = 5

    /// 페어링 시트가 보여 줄 단계.
    public enum PairingState: Sendable, Hashable {
        /// 열린 코드·QR이 없다(쓰였거나, 만료됐거나, 폐기됐거나, 아직 열지 않았다).
        case idle
        /// 설치 페이지용 코드를 보여 주는 중(앱이 없는 iPhone).
        case open(PairingCode)
        /// 앱용 QR을 보여 주는 중(앱이 있는 iPhone). 값은 `pairingInvite`에 있다.
        case offerOpen(expiresAt: Date)
        /// 코드나 QR이 쓰여 요청이 왔다(한 번만 쓸 수 있어 더 보여 주지 않는다). 승인·거절을 기다린다.
        case requestReceived(requestId: String)
    }

    /// 페어링 동선. 사용자가 iPhone의 상황으로 고른다.
    public enum PairingRoute: String, Sendable, Hashable, CaseIterable {
        /// RemoteDebug 앱이 있는 iPhone: Mac의 QR을 앱으로 읽고 확인 숫자를 맞춘다.
        case app
        /// 앱이 아직 없는 iPhone: Safari로 설치 페이지를 열고 코드를 넣는다.
        case browser
    }

    // MARK: 상태

    /// 마지막으로 받은 코어 상태. 공유하지 않으면 nil.
    public private(set) var status: CoreStatus?
    public private(set) var isRunning = false
    /// 공유 시작을 눌러 코어가 뜨기를 기다리는 중.
    public var isStarting: Bool { startingGeneration != nil }
    public private(set) var builds: [LibraryBuild] = []
    public private(set) var rejected: [RejectedBuild] = []
    public private(set) var devices: [DeviceEntry] = []
    /// iPhone에 보내는 파일(최근 것부터).
    public private(set) var sharedFiles: [ResourceDescriptor] = []
    /// 보내려고 복사·게시 중인 파일 수.
    public private(set) var filesInProgress = 0
    /// 승인 대기 중인 페어링 요청(만료된 것 포함 가능, `pendingPairRequests`가 거른다).
    public private(set) var pairRequests: [PairRequestEvent] = []
    public private(set) var pairingState: PairingState = .idle
    /// 승인·거절을 코어에 보내는 중인 요청(버튼을 끄는 데 쓴다).
    public private(set) var decidingRequestIDs: Set<String> = []
    /// 마지막으로 끝난 페어링 요청의 결과.
    public private(set) var lastPairingOutcome: PairingOutcome?
    /// 코드를 만들거나 요청에 답하다 실패한 이유. 페어링 시트 안에 보여 준다(창의 오류 표시는 시트에 가린다).
    public private(set) var pairingError: String?
    /// 페어링 QR에 넣는 1회용 Tailscale 키.
    public enum PairingKeyState: Sendable, Hashable {
        /// Tailscale OAuth 클라이언트가 없다.
        case off
        case creating
        /// QR에 키가 들어 있다. 키는 이 시각에 끝난다.
        case ready(expires: Date)
        case failed(String)
    }

    /// Tailscale OAuth 클라이언트를 확인한 결과.
    public struct TokenCheck: Sendable, Hashable {
        public var ok: Bool
        public var message: String
    }

    public private(set) var pairingKeyState: PairingKeyState = .off
    /// 앱용 QR(제안). 열려 있을 때만 있다. 링크와 그림은 비밀이다.
    public private(set) var pairingInvite: PairingInvite?
    /// QR을 여는 중(키를 만드는 시간 포함).
    public private(set) var isOpeningInvite = false
    /// 코드·QR 열기의 세대. 새로 열 때마다 올린다. 앞 세대의 열기가 늦게 끝나면 결과를 버린다.
    @ObservationIgnored private var pairingGeneration = 0
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    /// 키체인에 Tailscale OAuth 클라이언트가 있다.
    public private(set) var hasTailscaleClient = false
    /// 저장된 클라이언트가 키에 붙이는 태그.
    public private(set) var tailscaleTags: [String] = []
    /// 마지막 토큰 저장·사용 결과.
    public private(set) var tokenCheck: TokenCheck?
    public private(set) var isCheckingToken = false

    /// 최신이 앞. 최대 `activityLimit`.
    public private(set) var activity: [ActivityItem] = []
    /// 최신이 뒤. 최대 `logLimit`.
    public private(set) var logs: [LogEvent] = []
    /// iPhone이 보낸 진단 로그.
    public let deviceLogs: DeviceLogStore
    public let crashLogs: CrashLogStore
    public private(set) var watchedFolder: URL?
    /// 감시 폴더가 사라졌거나 읽을 수 없거나, 저장한 폴더를 다시 열 수 없다. 폴더를 다시 골라야 한다.
    public private(set) var watchProblem: WatchProblem?
    public private(set) var importsInProgress = 0
    /// 사용자에게 보여 줄 마지막 오류.
    public var lastError: String?
    /// 고급 설정: 제어 서버 URL. 비면 Tailscale 기본 제어 서버.
    /// 바꾸면 다른 제어 서버에서 페어링한 기기는 코어에 보내지 않는다(`deviceScopeConflict`). 화면에서는 `applyControlURL`을 쓴다.
    public var controlURL: String = ""
    /// 저장된 기기(`devices`)를 페어링한 제어 서버(`normalizedControlURL`, 빈 문자열은 Tailscale 기본 제어 서버).
    /// 노드 StableID는 제어 서버가 정하므로 허용 목록은 그 서버에서만 뜻이 있다.
    public private(set) var deviceControlURL: String = ""
    /// 같은 네트워크의 iPhone이 VPN 없이 직접 연결하게 한다(docs/protocol-addenda.md O).
    /// 앱이 저장된 설정을 넣는다. 화면에서는 `setDirectEnabled`를 쓴다.
    public var directEnabled = false

    public let nodeName: String
    public let hostDisplayName: String

    // MARK: 의존성

    @ObservationIgnored private let core: any HostCore
    @ObservationIgnored private let paths: HostPaths
    @ObservationIgnored let library: BuildLibrary
    @ObservationIgnored let fileLibrary: ResourceLibrary
    @ObservationIgnored private let bookmarks: any FolderBookmarking
    @ObservationIgnored private let watcherOptions: FolderWatcher.Options
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let port: Int
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let deviceStore: JSONFile<StoredDeviceList>
    @ObservationIgnored private let tailscaleClients: any TailscaleClientStoring
    @ObservationIgnored private let feedbackKeys: any FeedbackKeyStoring
    @ObservationIgnored private let advertiser: (any DirectAdvertising)?

    public private(set) var diagnosticsImports = 0
    public private(set) var isMigratingFeedbackKeys = false
    public var diagnosticsImportErrors: [String] = []
    public var diagnosticsOpenRequested = false
    public var diagnosticsOpenedRecordID: String?

    /// 저장된 빌드 목록을 읽었다. 한 번 읽으면 다시 읽지 않는다(가져오는 중인 작업 폴더를 건드리지 않는다).
    @ObservationIgnored private var libraryLoaded = false
    /// 저장된 기기 목록을 읽었다.
    @ObservationIgnored private var devicesLoaded = false
    /// 저장된 빌드·기기 목록을 끝까지 읽었다. 읽는 중이거나 읽지 못했으면 false.
    private var loaded: Bool { libraryLoaded && devicesLoaded }
    /// 빌드 목록을 읽지 못한 이유(파일과 원인). 가져오기가 거절될 때 그대로 보여 준다.
    @ObservationIgnored private var libraryLoadFailure: String?
    /// 백업 제외를 적용하지 못했다는 안내. 불러오기가 끝날 때 한 번만 보여 준다.
    @ObservationIgnored private var pendingBackupWarning: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// `shutdown`을 불렀다. 이후에는 공유·폴더 감시·가져오기를 시작하지 않는다.
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var folderAccess: SecurityScopedAccess?
    @ObservationIgnored private var folderGeneration = 0
    @ObservationIgnored private var resumeTask: Task<Void, Never>?

    // 수명 주기
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var lifecycleTail: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var coreStarted = false
    /// 돌고 있는 코어가 시작할 때 쓴 제어 서버(`normalizedControlURL`). 코어가 없으면 nil.
    @ObservationIgnored private var coreControlURL: String?
    /// 돌고 있는 코어의 리스너가 TLS인지(시작 설정의 `listenTLS`). 코어가 없으면 nil.
    private var coreListensTLS: Bool?
    private var startingGeneration: Int?

    // 에이전트 요청(addenda K)
    /// 코어에 넘길 `GET /v1/agent` 본문. 코어가 뜰 때마다 다시 넘긴다.
    @ObservationIgnored private var agentBoard: Data?
    /// 페어링한 기기가 에이전트 요청을 보냈다.
    @ObservationIgnored public var onAgentRequest: (@MainActor (AgentRequestEvent) -> Void)?
    @ObservationIgnored public var onAgentCancel: (@MainActor (AgentCancelEvent) -> Void)?

    // 기기 목록(코어 호출은 순서대로 하나씩)
    @ObservationIgnored private var deviceTail: Task<Void, Never>?

    // 페어링
    @ObservationIgnored private var requestNames: [String: String] = [:]
    @ObservationIgnored private var decidedRequestIDs: [String] = []
    @ObservationIgnored private var pairingFailures = 0

    public init(
        core: any HostCore,
        paths: HostPaths,
        inspector: any BuildInspecting = KitBuildInspector(),
        packager: any BuildPackaging = KitBuildPackager(),
        bookmarks: any FolderBookmarking = UserDefaultsFolderBookmarks(),
        watcherOptions: FolderWatcher.Options = FolderWatcher.Options(),
        id8: String? = nil,
        hostDisplayName: String? = nil,
        appVersion: String? = nil,
        port: Int = 443,
        keepPerBundle: Int = 3,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        tailscaleClients: any TailscaleClientStoring = KeychainTailscaleClientStore(),
        feedbackKeys: any FeedbackKeyStoring = KeychainFeedbackKeyStore(),
        advertiser: (any DirectAdvertising)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.core = core
        self.paths = paths
        self.library = BuildLibrary(paths: paths, host: core, inspector: inspector, packager: packager, keepPerBundle: keepPerBundle, now: now)
        self.fileLibrary = ResourceLibrary(paths: paths, host: core, now: now)
        self.bookmarks = bookmarks
        self.watcherOptions = watcherOptions
        let id = id8 ?? (try? HostIdentity.loadOrCreate(at: paths.identityFile)) ?? HostIdentity.random()
        self.nodeName = HostIdentity.nodeName(id8: id)
        self.hostDisplayName = hostDisplayName ?? Host.current().localizedName ?? ""
        self.appVersion = appVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        self.port = port
        self.openURL = openURL
        self.now = now
        self.deviceStore = JSONFile(url: paths.devicesFile)
        self.tailscaleClients = tailscaleClients
        self.feedbackKeys = feedbackKeys
        self.advertiser = advertiser
        let client = tailscaleClients.load()
        self.hasTailscaleClient = client != nil
        self.tailscaleTags = client?.tags ?? []
        self.deviceLogs = DeviceLogStore(directory: paths.deviceLogsDir, now: now)
        self.crashLogs = CrashLogStore(directory: paths.crashLogsDir, now: now)
    }

    // MARK: 파생 상태

    public var guidance: StatusGuidance {
        if isStarting || (isRunning && status == nil) { return StatusGuidance.startingGuidance }
        // 루프백 테스트 제어 서버(평문 HTTP)에서는 인증서가 없어도 리스너가 열리면 준비된 것이다.
        if isRunning, let s = status, !usesTLS, s.backendState == .running, s.listening {
            return StatusGuidance.make(for: CoreStatus(backendState: .running, hostname: s.hostname, fqdn: s.fqdn,
                                                       certDomains: [s.fqdn], tlsReady: true, listening: true))
        }
        return StatusGuidance.make(for: isRunning ? status : nil)
    }

    /// 지금 설정으로 코어가 TLS로 서빙하는지(루프백 제어 서버면 평문).
    var usesTLS: Bool { !Self.isLoopbackHost(of: controlURL.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// 페어링 코드를 열 수 있는지. iPhone이 이 Mac에 닿을 수 있을 때(Running, MagicDNS 주소, 리스너 열림,
    /// TLS면 인증서 준비)만 연다. 아니면 그 이유와 다음 행동.
    public var pairingAvailability: PairingAvailability {
        guard isRunning else { return .unavailable(String(localized: "공유가 꺼져 있어 페어링할 수 없습니다. 공유를 시작하세요.")) }
        if let conflict = deviceScopeConflict { return .unavailable(conflict.message) }
        guard let s = status else { return .unavailable(StatusGuidance.startingGuidance.message) }
        let g = guidance
        if g.kind != .ready { return .unavailable("\(g.title): \(g.message)") }
        if s.fqdn.isEmpty {
            return .unavailable(String(localized: "이 Mac의 MagicDNS 주소를 아직 받지 못했습니다. Tailscale 관리 콘솔의 DNS 페이지에서 MagicDNS가 켜져 있는지 확인하세요."))
        }
        if !s.listening { return .unavailable(String(localized: "이 Mac의 설치 주소가 아직 열리지 않았습니다. 잠시 뒤 다시 시도하세요.")) }
        return .ready
    }

    /// 저장된 기기가 다른 제어 서버에서 페어링한 것이면 그 내용. 이 기기들은 코어에 보내지 않는다.
    public var deviceScopeConflict: DeviceScopeConflict? {
        guard !devices.isEmpty, deviceControlURL != Self.normalizedControlURL(controlURL) else { return nil }
        return DeviceScopeConflict(savedControlURL: deviceControlURL, deviceCount: devices.count)
    }

    /// 지금 제어 서버에서 쓸 수 있는 기기(코어에 보내는 허용 목록).
    var activeDevices: [DeviceEntry] { deviceScopeConflict == nil ? devices : [] }

    /// 아직 만료되지 않은 페어링 요청.
    public var pendingPairRequests: [PairRequestEvent] {
        let t = now()
        return pairRequests.filter { $0.expiresAt > t }
    }

    /// 보여 줄 페어링 코드. 열려 있고 만료되지 않았을 때만.
    public var pairingCode: PairingCode? {
        guard case .open(let code) = pairingState, code.expiresAt > now() else { return nil }
        return code
    }

    /// 앱용 QR의 링크(`remotedebug://pair#v=1&h=…` 또는 연결 도메인의 https 링크). 열려 있고 만료되지 않았을 때만.
    /// 사용자 지정 스킴이면 키를 싣지 않았을 때만 있다. 비밀이다(화면에만 쓴다).
    public var pairingLink: URL? { openInvite?.link }

    /// 열려 있고 만료되지 않은 앱용 QR.
    public var openInvite: PairingInvite? {
        guard case .offerOpen = pairingState, let invite = pairingInvite, invite.expiresAt > now() else { return nil }
        return invite
    }

    /// 설치 웹 페이지 주소(코드 없음). 코어의 `BaseURL`과 같은 규칙: TLS면 `https://<fqdn>/`(포트 443이 아니면 포트를 붙인다),
    /// 루프백 테스트 제어 서버면 `http://<fqdn>:<port>/`. 페어링할 수 있을 때(`pairingAvailability == .ready`)만 있다.
    public var installPageURL: URL? {
        guard pairingAvailability == .ready, let tls = coreListensTLS, let fqdn = status?.fqdn else { return nil }
        return Self.installPageURL(fqdn: fqdn, tls: tls, port: port, code: nil)
    }

    /// 지금 열린 코드를 넣은 설치 페이지 링크(`…/#code=<코드>`). 만료·사용·폐기됐거나 지금 코드가 아니면 nil.
    public func installPageURL(code: PairingCode) -> URL? {
        guard code == pairingCode, let tls = coreListensTLS, let fqdn = status?.fqdn,
              pairingAvailability == .ready else { return nil }
        return Self.installPageURL(fqdn: fqdn, tls: tls, port: port, code: code.code)
    }

    /// 페어링 시트의 설치 페이지 QR·복사에 쓰는 링크(지금 열린 코드 포함).
    public var installPageLink: URL? {
        pairingCode.flatMap { installPageURL(code: $0) }
    }

    nonisolated static func installPageURL(fqdn: String, tls: Bool, port: Int, code: String?) -> URL? {
        let host = fqdn.hasSuffix(".") ? String(fqdn.dropLast()) : fqdn
        guard !host.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = tls ? "https" : "http"
        c.host = host
        if !tls || port != 443 { c.port = port }
        c.path = "/"
        if let code { c.fragment = "code=\(code)" }
        return c.url
    }

    // MARK: 불러오기

    /// 저장된 빌드 목록·기기를 읽고, 저장된 감시 폴더 감시를 백그라운드에서 다시 시작한다.
    /// 감시 폴더의 첫 검사·가져오기는 기다리지 않는다(가져오는 대로 목록에 나타난다).
    /// 읽는 중에 부르면 그 읽기가 끝날 때까지 기다린다. 읽지 못했으면 다음 호출이 다시 시도한다.
    public func load() async {
        guard !loaded, !isShutDown else { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await self?.performLoad()
            self?.loadTask = nil
        }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        let generation = folderGeneration
        // 읽지 못한 쪽만 다시 읽는다.
        if !libraryLoaded { await loadLibrary() }
        if !devicesLoaded { loadDevices() }
        await refreshLibrary()
        guard loaded else { return }
        if let warning = pendingBackupWarning {
            pendingBackupWarning = nil
            lastError = warning
        }
        resumeTask = Task { [weak self] in
            await self?.resumeSavedFolder(generation: generation)
        }
    }

    private func loadLibrary() async {
        do {
            let unprotected = try paths.prepare()
            // 시도마다 결과로 정한다(권한을 고친 뒤 다시 읽을 때 지난 시도의 경고가 남지 않게).
            if unprotected.isEmpty {
                pendingBackupWarning = nil
            } else {
                let names = unprotected.map(\.path).joined(separator: ", ")
                pendingBackupWarning = String(localized: "백업에서 빼지 못했습니다(\(names)). 공유와 가져오기는 그대로 쓸 수 있지만, 이 Mac의 tailnet 노드 키가 Time Machine 백업에 들어갈 수 있습니다. 권한을 확인한 뒤 앱을 다시 실행하세요.")
            }
        } catch {
            noteLibraryLoadFailure(String(localized: "저장 폴더를 준비하지 못했습니다: \(Self.message(for: error)) 게시한 빌드는 그대로 두었습니다. 폴더 권한을 확인한 뒤 공유를 시작하거나 빌드를 다시 가져오세요."))
            return
        }
        do {
            try await fileLibrary.load()
        } catch {
            lastError = String(localized: "보낼 파일 목록(\(paths.resourcesFile.path))을 읽지 못했습니다: \(Self.message(for: error))")
        }
        do {
            try await library.load()
            libraryLoaded = true
            libraryLoadFailure = nil
        } catch {
            noteLibraryLoadFailure(String(localized: "저장된 빌드 목록(\(paths.buildsFile.path))을 읽지 못했습니다: \(Self.message(for: error)) 게시한 빌드는 그대로 두었습니다. 파일을 복구한 뒤 공유를 시작하거나 빌드를 다시 가져오세요."))
        }
    }

    private func noteLibraryLoadFailure(_ message: String) {
        libraryLoadFailure = message
        lastError = message
    }

    private func loadDevices() {
        do {
            let stored = try deviceStore.load()
            devices = stored?.devices ?? []
            // controlURL이 없는 예전 파일은 기본 제어 서버에서 페어링한 것으로 본다.
            deviceControlURL = Self.normalizedControlURL(stored?.controlURL ?? "")
            devicesLoaded = true
        } catch {
            lastError = String(localized: "저장된 기기 목록(\(paths.devicesFile.path))을 읽지 못했습니다: \(Self.message(for: error)) 파일을 복구한 뒤 공유를 시작하세요.")
        }
    }

    /// 백그라운드 폴더 다시 감시(첫 검사 포함)가 끝날 때까지 기다린다(테스트·미리보기용).
    public func waitForFolderResume() async {
        await resumeTask?.value
    }

    // MARK: 시작·정지

    /// 공유를 시작한다. `authKey`는 이 호출의 설정에만 쓰고 저장하지 않는다.
    /// 이미 시작하는 중이면 그 시작이 끝날 때까지 기다린다.
    public func start(authKey: String = "") async {
        guard !isShutDown else { return }
        if startingGeneration != nil, let startTask {
            await startTask.value
            return
        }
        guard !isRunning else { return }
        let generation = runGeneration
        startingGeneration = generation
        lastError = nil
        let task = enqueueLifecycle { [weak self] in
            await self?.performStart(authKey: authKey, generation: generation)
        }
        startTask = task
        await task.value
    }

    /// 공유를 멈춘다. 시작하는 중이면 시작을 멈춘다. 폴더 감시는 계속한다.
    public func stop() async {
        runGeneration += 1
        pairingGeneration += 1
        pairingTask?.cancel()
        isOpeningInvite = false
        startTask?.cancel()
        startTask = nil
        startingGeneration = nil
        isRunning = false
        let task = enqueueLifecycle { [weak self] in await self?.performStop() }
        await task.value
    }

    /// 이 Mac의 tailnet 로그인이 저장돼 있는가(노드 상태 폴더에 파일이 있다).
    public var hasSavedLogin: Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: paths.stateDir.path)) ?? []).isEmpty
    }

    /// tailnet에서 로그아웃한다: 공유를 멈추고(노드가 끝나기를 기다린다), 제어 서버에 로그아웃을 알리고, 노드 상태 폴더와
    /// 직접 연결 신원을 비우고 페어링한 기기 목록을 지운다. 서버에 알리지 못해도 폴더는 지운다.
    /// 다음 공유 시작은 새 기기로 로그인한다.
    @discardableResult
    public func logout() async -> Bool {
        await stop()
        await core.logOut(makeConfig(authKey: ""))
        do {
            let fm = FileManager.default
            for folder in [paths.stateDir, paths.directDir] where fm.fileExists(atPath: folder.path) {
                try fm.removeItem(at: folder)
            }
            try paths.prepare()
        } catch {
            lastError = String(localized: "로그인 정보를 지우지 못했습니다. \(error.localizedDescription)")
            return false
        }
        devices = []
        saveDevices()
        lastError = nil
        return true
    }

    /// 앱 종료 때 부른다. 공유와 폴더 감시를 멈춘다. 이 모델은 다시 시작할 수 없다.
    public func shutdown() async {
        isShutDown = true
        await stopWatching()
        await stop()
        await loadTask?.value
    }

    private func enqueueLifecycle(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lifecycleTail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycleTail = task
        return task
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == runGeneration && !Task.isCancelled
    }

    private func performStart(authKey: String, generation: Int) async {
        defer { if startingGeneration == generation { startingGeneration = nil } }
        guard isCurrent(generation) else { return }
        await load()
        guard isCurrent(generation) else { return }
        // 저장된 목록을 읽지 못한 채 시작하면 빈 목록으로 IPA를 지우거나 기기 파일을 덮어쓴다. `load`가 남긴 오류를 그대로 보여 준다.
        guard loaded else { return }
        let config = makeConfig(authKey: authKey)
        do {
            try await core.start(config)
        } catch {
            if isCurrent(generation) { lastError = String(localized: "공유를 시작하지 못했습니다: \(Self.message(for: error))") }
            return
        }
        coreStarted = true
        coreControlURL = Self.normalizedControlURL(config.controlURL)
        coreListensTLS = config.listenTLS
        guard isCurrent(generation) else { return await rollBackStart() }
        isRunning = true
        startEventLoop()
        do {
            try await pushDevices()
        } catch {
            if isCurrent(generation) { lastError = String(localized: "기기 목록을 적용하지 못했습니다: \(Self.message(for: error))") }
        }
        if let agentBoard { try? await core.setAgentBoard(agentBoard) }
        guard isCurrent(generation) else { return await rollBackStart() }
        // 코어가 떴다. 저장된 빌드 재게시는 감시 폴더 가져오기 뒤에 줄을 설 수 있으므로 시작 중 표시를 붙잡지 않는다.
        startingGeneration = nil
        await refreshStatus()
        let report = await library.activate()
        if report.notLoaded { lastError = BuildLibraryError.notLoaded.localizedDescription }
        guard isCurrent(generation), !report.interrupted else { return await rollBackStart() }
        if !report.failed.isEmpty {
            lastError = String(localized: "빌드 \(String(report.failed.count))개를 다시 게시하지 못했습니다(다음 시작 때 다시 시도합니다): \(report.failed[0].message)")
        }
        let failedFiles = await fileLibrary.activate()
        if !failedFiles.isEmpty {
            lastError = String(localized: "파일 \(String(failedFiles.count))개를 iPhone에 다시 보내지 못했습니다(다음 시작 때 다시 시도합니다): \(failedFiles.joined(separator: ", "))")
        }
        await refreshLibrary()
        await refreshStatus()
    }

    /// 시작 도중 중지됐다: 코어·라이브러리를 멈춘 상태로 되돌린다.
    private func rollBackStart() async {
        await library.deactivate()
        await fileLibrary.deactivate()
        await stopCoreIfStarted()
        isRunning = false
        setStatus(nil)
        await refreshLibrary()
    }

    private func performStop() async {
        await library.deactivate()
        await fileLibrary.deactivate()
        await stopCoreIfStarted()
        eventTask?.cancel()
        eventTask = nil
        isRunning = false
        setStatus(nil)
        pairingState = .idle
        pairingInvite = nil
        pairRequests = []
        decidingRequestIDs = []
        pairingError = nil
        await refreshLibrary()
    }

    /// `core.stop()`이 내보내는 세션 `failed` 이벤트(addenda C.3)를 적용한 뒤 이벤트 처리를 끝낸다.
    private func stopCoreIfStarted() async {
        guard coreStarted else { return }
        coreStarted = false
        await core.stop()
        await drainEvents()
        failOpenSessions()
        coreControlURL = nil
        coreListensTLS = nil
    }

    /// 이벤트 스트림이 끝날 때까지(최대 `timeout`) 남은 이벤트를 처리하고 루프를 끝낸다.
    private func drainEvents(timeout: Duration = .seconds(1)) async {
        guard let task = eventTask else { return }
        eventTask = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            task.cancel()
            group.cancelAll()
        }
    }

    /// 이 Mac이 마지막으로 그 기기의 연락을 받은 시각: iPhone 로그를 받았거나 설치 세션이 바뀐 때. 모르면 nil.
    public func lastContact(with device: DeviceEntry) -> Date? {
        let log = deviceLogs.device(id: device.id)?.lastReceived
        let session = activity.first { item in
            if case .session(let e) = item.kind { return e.nodeName == device.nodeName }
            return false
        }?.date
        return [log, session].compactMap(\.self).max()
    }

    /// iPhone이 받고 있는 설치(시작했지만 끝나지 않은 세션). 공유를 멈추면 끊긴다.
    public var installsInProgress: [SessionEvent] {
        activity.compactMap {
            guard case .session(let e) = $0.kind else { return nil }
            switch e.state {
            case .created, .manifestServed, .downloading: return e
            case .completed, .expired, .failed: return nil
            }
        }
    }

    /// 공유를 멈추면 열린 설치 세션은 모두 실패한다(addenda C.3). 이벤트가 오지 않은 세션도 실패로 바꾼다.
    private func failOpenSessions() {
        for var e in installsInProgress {
            e.state = .failed
            handle(.session(e))
        }
    }

    public func refreshStatus() async {
        guard isRunning else { return }
        do {
            let s = try await core.status()
            if isRunning { setStatus(s) }
        } catch {
            lastError = String(localized: "공유 상태를 읽지 못했습니다: \(Self.message(for: error))")
        }
    }

    /// 로그인 페이지(`authURL`)를 기본 브라우저로 연다. https만 연다(루프백 테스트 제어 서버일 때만 http).
    public func openLoginPage() {
        guard let raw = status?.authURL, let url = Self.loginURL(raw, controlURL: controlURL) else {
            lastError = String(localized: "열 수 있는 로그인 주소가 아직 없습니다.")
            return
        }
        openURL(url)
    }

    nonisolated static func loginURL(_ raw: String, controlURL: String) -> URL? {
        guard !raw.isEmpty, let comps = URLComponents(string: raw), let host = comps.host, !host.isEmpty,
              let scheme = comps.scheme?.lowercased(), let url = comps.url else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", isLoopbackHost(of: controlURL.trimmingCharacters(in: .whitespacesAndNewlines)), isLoopbackHost(of: raw) {
            return url
        }
        return nil
    }

    func makeConfig(authKey: String) -> CoreConfig {
        let control = controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoreConfig(
            mode: .host,
            stateDir: paths.stateDir.path,
            hostname: nodeName,
            authKey: authKey,
            controlURL: control,
            ephemeral: false,
            listenTLS: !Self.isLoopbackHost(of: control),
            port: port,
            publishDir: paths.publishedDir.path,
            allowedTargets: [],
            goMemLimitMiB: 0,
            logPath: paths.coreLogFile.path,
            hostDisplayName: hostDisplayName,
            appVersion: appVersion,
            directListen: directEnabled
        )
    }

    /// 제어 서버 URL의 호스트가 루프백인지. 예전 Go 코어(`node.IsLoopbackHost`: `localhost` 또는 `net.ParseIP` + `IsLoopback`)와
    /// 같게 판정한다: `localhost`(대소문자 무시), IPv4 `127.0.0.0/8`(앞자리 0 금지), IPv6 `::1`, IPv4 대응 주소 `::ffff:127.x.x.x`.
    public nonisolated static func isLoopbackHost(of controlURL: String) -> Bool {
        guard !controlURL.isEmpty, var host = URLComponents(string: controlURL)?.host, !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        if let octets = strictIPv4(host) { return octets[0] == 127 }
        // IPv6. 끝에 붙은 IPv4 부분도 Go처럼 앞자리 0을 거부한다.
        if host.contains("."), let last = host.split(separator: ":").last, strictIPv4(String(last)) == nil { return false }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return b[12] == 127 }
        }
        return false
    }

    /// 점 4개로 나눈 10진수 IPv4(각 0...255, 앞자리 0 금지). Go `net.ParseIP`와 같은 규칙.
    nonisolated static func strictIPv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for p in parts {
            guard (1...3).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(p.count > 1 && p.first == "0"), let v = Int(p), v <= 255 else { return nil }
            octets.append(v)
        }
        return octets
    }

    // MARK: 에이전트 요청

    /// 페어링한 기기가 읽는 에이전트 상태를 바꾼다. 공유가 꺼져 있으면 다음에 켤 때 넘긴다.
    public func setAgentBoard(_ board: Data) async {
        agentBoard = board
        guard coreStarted else { return }
        try? await core.setAgentBoard(board)
    }

    // MARK: 이벤트

    private func startEventLoop() {
        eventTask?.cancel()
        let stream = core.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self else { return }
                self.handle(event)
            }
        }
    }

    func handle(_ event: CoreEvent) {
        switch event {
        case .state(let s):
            if isRunning { setStatus(s) }
        case .pairRequest(let e):
            pruneExpiredPairRequests()
            pairRequests.removeAll { $0.requestId == e.requestId }
            rememberName(e.deviceName, for: e.requestId)
            if e.expiresAt > now() { pairRequests.append(e) }
            // 코드·QR은 한 번만 쓸 수 있다(코어가 이미 닫았다). 더 보여 주지 않고 승인 단계로 넘어간다.
            pairingState = .requestReceived(requestId: e.requestId)
            pairingInvite = nil
        case .pairDecided(let e):
            let name = requestNames[e.requestId] ?? pairRequests.first { $0.requestId == e.requestId }?.deviceName
            pairRequests.removeAll { $0.requestId == e.requestId }
            markDecided(e.requestId)
            if case .requestReceived(let id) = pairingState, id == e.requestId { pairingState = .idle }
            noteOutcome(of: e)
            appendActivity(.pairDecided(e), ActivityText.pairDecided(e, deviceName: name))
        case .deviceAdded(let d):
            guard storeApprovedDevice(d, approvedBy: coreControlURL) else { break }
            appendActivity(.deviceAdded(d), String(localized: "\(d.name) 기기를 허용 목록에 추가했습니다."))
        case .deviceUpdated(let d):
            storeDeviceUpdate(d)
        case .denied(let e):
            appendActivity(.denied(e), ActivityText.denied(e))
            notePairingDenial(e)
        case .session(let e):
            activity.removeAll { $0.sessionID == e.sessionId }
            let name = builds.first { $0.id == e.buildId }?.descriptor.displayName
            appendActivity(.session(e), ActivityText.session(e, buildName: name))
        case .log(let e):
            logs.append(e)
            if logs.count > Self.logLimit { logs.removeFirst(logs.count - Self.logLimit) }
        case .deviceLog(let e):
            deviceLogs.receive(e)
        case .deviceCrash(let e):
            crashLogs.receive(e)
        case .agentRequest(let e):
            onAgentRequest?(e)
        case .agentCancel(let e):
            onAgentCancel?(e)
        case .networkSettings, .unknown:
            break
        }
    }

    /// 틀린 코드 시도가 쌓여 코어가 코드를 폐기했으면(protocol §2, addenda B.3) 코드를 내린다.
    private func notePairingDenial(_ e: DeniedEvent) {
        guard case .open = pairingState else { return }
        switch e.reason {
        case "too_many_attempts":
            pairingState = .idle
        case "pair_code_invalid":
            pairingFailures += 1 + max(0, e.suppressed ?? 0)
            if pairingFailures >= Self.pairingMaxFailures { pairingState = .idle }
        default:
            break
        }
    }

    /// 코어가 알린 결정. 이 Mac의 `decide`가 이미 결과를 남겼으면 그대로 둔다.
    private func noteOutcome(of e: PairDecidedEvent) {
        guard lastPairingOutcome?.requestId != e.requestId else { return }
        switch e.state {
        case .approved: lastPairingOutcome = PairingOutcome(requestId: e.requestId, kind: .allowed)
        case .denied: lastPairingOutcome = PairingOutcome(requestId: e.requestId, kind: .denied)
        case .expired: lastPairingOutcome = PairingOutcome(requestId: e.requestId, kind: .expired)
        case .pending: break
        }
    }

    private func appendActivity(_ kind: ActivityItem.Kind, _ text: String) {
        activity.insert(ActivityItem(date: now(), kind: kind, text: text), at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }

    public func pruneExpiredPairRequests() {
        let t = now()
        pairRequests.removeAll { $0.expiresAt <= t }
        switch pairingState {
        case .open(let code) where code.expiresAt <= t:
            pairingState = .idle
        case .offerOpen(let expiresAt) where expiresAt <= t:
            pairingState = .idle
            pairingInvite = nil
        case .requestReceived(let id) where !pairRequests.contains(where: { $0.requestId == id }) && !decidingRequestIDs.contains(id):
            pairingState = .idle
        default:
            break
        }
    }

    private func rememberName(_ name: String, for requestID: String) {
        requestNames[requestID] = name
        if requestNames.count > 100, let any = requestNames.keys.first(where: { id in !pairRequests.contains { $0.requestId == id } }) {
            requestNames[any] = nil
        }
    }

    private func markDecided(_ requestID: String) {
        guard !decidedRequestIDs.contains(requestID) else { return }
        decidedRequestIDs.append(requestID)
        if decidedRequestIDs.count > 100 { decidedRequestIDs.removeFirst(decidedRequestIDs.count - 100) }
    }

    // MARK: 페어링·기기

    /// 고른 동선으로 페어링을 연다. 앱이 있는 iPhone은 QR, 앱이 없는 iPhone은 설치 페이지용 코드. 하나를 열면 다른 하나는
    /// 닫는다: 페어링은 한 번에 하나다. 열기는 한 번에 하나씩 한다: 새로 열면 진행 중인 열기를 취소하고, 그것이 끝난 뒤에 연다.
    /// 늦게 끝난 앞의 열기는 화면 상태를 바꾸지 않는다(연 QR은 닫는다).
    public func beginPairing(_ route: PairingRoute) async {
        pairingGeneration += 1
        let generation = pairingGeneration
        let previous = pairingTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.isCurrentPairing(generation) else { return }
            switch route {
            case .app: await self.openAppPairing(generation)
            case .browser: await self.openBrowserPairing(generation)
            }
        }
        pairingTask = task
        await task.value
    }

    /// 설치 페이지용 코드를 연다(5분, 앱이 아직 없는 iPhone). 이미 열린 코드는 코어가 새 코드로 바꾸고, 열린 QR은 닫는다.
    public func beginPairing() async {
        await beginPairing(.browser)
    }

    /// 앱용 QR을 연다(5분, RemoteDebug 앱이 있는 iPhone). OAuth 클라이언트가 있으면 코어가 1회용 Tailscale 키를 만들어
    /// QR에 싣는다. 키를 만들지 못하면 키 없는 QR을 낸다. 열린 설치 페이지 코드는 닫는다.
    public func beginAppPairing() async {
        await beginPairing(.app)
    }

    private func isCurrentPairing(_ generation: Int) -> Bool {
        generation == pairingGeneration && !Task.isCancelled
    }

    private func openBrowserPairing(_ generation: Int) async {
        guard canOpenPairing() else { return }
        await closeInviteIfOpen()
        do {
            let code = try await core.openPairing(ttlSeconds: Self.pairingTTLSeconds)
            guard isCurrentPairing(generation), isRunning else { return }
            pairingFailures = 0
            pairingState = .open(code)
        } catch {
            guard isCurrentPairing(generation) else { return }
            notePairingFailure(String(localized: "페어링 코드를 만들지 못했습니다: \(Self.message(for: error))"))
        }
    }

    private func openAppPairing(_ generation: Int) async {
        guard canOpenPairing() else { return }
        isOpeningInvite = true
        defer { isOpeningInvite = false }
        if case .open = pairingState { pairingState = .idle }
        pairingInvite = nil
        let client = tailscaleClients.load()
        pairingKeyState = client == nil ? .off : .creating
        do {
            let invite = try await core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: Self.pairingTTLSeconds, oauthClient: client))
            guard isCurrentPairing(generation), isRunning else {
                // 그사이 다른 동선을 골랐거나 공유를 멈췄다: 이 QR은 쓰지 않는다.
                await core.closePairingOffer()
                return
            }
            pairingInvite = invite
            pairingState = .offerOpen(expiresAt: invite.expiresAt)
            switch invite.authKey {
            case .none: pairingKeyState = .off
            case .included(let expires): pairingKeyState = .ready(expires: expires)
            case .failed(let failure):
                pairingKeyState = .failed(failure.message)
                if failure != .network && failure != .cancelled { tokenCheck = TokenCheck(ok: false, message: failure.message) }
            }
        } catch {
            guard isCurrentPairing(generation) else { return }
            pairingKeyState = .off
            notePairingFailure(String(localized: "페어링 QR을 만들지 못했습니다: \(Self.message(for: error))"))
        }
    }

    /// 공유 중이고 iPhone이 이 Mac에 닿을 수 있을 때만 연다. 아니면 그 이유를 남긴다.
    private func canOpenPairing() -> Bool {
        guard isRunning else {
            lastError = String(localized: "공유를 시작해야 페어링할 수 있습니다.")
            return false
        }
        if case .unavailable(let reason) = pairingAvailability {
            lastError = reason
            return false
        }
        pairingError = nil
        return true
    }

    private func closeInviteIfOpen() async {
        guard pairingInvite != nil || pairingState.isOfferOpen else { return }
        pairingInvite = nil
        if pairingState.isOfferOpen { pairingState = .idle }
        await core.closePairingOffer()
    }

    /// OAuth 클라이언트의 형식을 확인하고 키체인에 저장한다. 관리 API에는 보내지 않는다: 클라이언트가 실제로 받아들여지는지는
    /// 다음 QR을 열 때 키를 만들며 안다(실패하면 QR 옆과 이 설정에 그 까닭이 나온다).
    public func saveTailscaleClient(id: String, secret: String, tags tagText: String) async {
        guard let tags = TailscaleAPI.parseTags(tagText) else {
            tokenCheck = TokenCheck(ok: false, message: TailscaleAPI.Failure.badTags.message)
            return
        }
        let client = TailscaleAPI.OAuthClient(id: id.trimmingCharacters(in: .whitespacesAndNewlines),
                                              secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), tags: tags)
        if let failure = core.checkOAuthClient(client) {
            tokenCheck = TokenCheck(ok: false, message: failure.message)
            return
        }
        do {
            try tailscaleClients.save(client)
        } catch {
            tokenCheck = TokenCheck(ok: false, message: String(localized: "OAuth 클라이언트를 키체인에 저장하지 못했습니다: \(Self.message(for: error))"))
            return
        }
        hasTailscaleClient = true
        tailscaleTags = tags
        tokenCheck = TokenCheck(ok: true, message: String(localized: "저장했습니다. 다음 페어링 QR부터 1회용 Tailscale 키(\(tags.joined(separator: ", ")))가 들어갑니다."))
    }

    public func clearTailscaleClient() {
        tailscaleClients.clear()
        hasTailscaleClient = false
        tailscaleTags = []
        tokenCheck = nil
        pairingKeyState = .off
    }

    /// 에이전트용: 앱이 아직 없는 iPhone의 설치 페이지에 넣을 코드를 연다. 허용은 Mac 화면에서 한다.
    /// 앱용 QR(제안의 링크·비밀)·Tailscale 키는 만들지도 돌려주지도 않는다(에이전트 응답은 대화 기록에 남는다).
    public func openPairingForAgent() async -> Result<ProjectsModel.PairingInfo, ProjectsModel.PairingFailure> {
        await beginPairing()
        guard let code = pairingCode else {
            return .failure(.init(pairingError ?? lastError ?? String(localized: "페어링 코드를 만들지 못했습니다.")))
        }
        return .success(.init(code: code.displayCode, installPage: installPageLink?.absoluteString, expiresAt: code.expiresAt))
    }

    /// 에이전트용: 허용을 기다리는 요청.
    public var pairRequestsForAgent: [ProjectsModel.PairRequestInfo] {
        pendingPairRequests.map {
            .init(requestId: $0.requestId, deviceName: $0.deviceName, nodeName: $0.nodeName, loginName: $0.loginName, expiresAt: $0.expiresAt)
        }
    }

    /// 에이전트용: 요청을 거부한다. 실패하면 안내를 돌려준다. 에이전트 경로에는 허용이 없다(허용은 `approve`, Mac 앱 화면).
    public func denyForAgent(_ requestId: String) async -> String? {
        await deny(requestId)
        if let error = pairingError { return error }
        if pendingPairRequests.contains(where: { $0.requestId == requestId }) { return String(localized: "요청에 답하지 못했습니다.") }
        return nil
    }

    /// 페어링 시트를 새로 열 때 지난 실패를 지운다.
    public func clearPairingError() {
        pairingError = nil
    }

    private func notePairingFailure(_ message: String) {
        pairingError = message
        lastError = message
    }

    /// 페어링 요청을 허용한다. Mac 앱 화면의 허용 버튼이 부른다. 에이전트 경로(명령 파일·MCP)의 통로
    /// (`ProjectsModel.PairingRequests`)에는 허용이 없어 이 함수에 닿지 않는다.
    public func approve(_ requestId: String) async {
        await decide(requestId, allow: true)
    }

    public func deny(_ requestId: String) async {
        await decide(requestId, allow: false)
    }

    /// 같은 요청에 대한 두 번째 호출(더블 클릭, 승인 뒤 거절)은 아무것도 하지 않는다.
    private func decide(_ requestId: String, allow: Bool) async {
        if decidingRequestIDs.contains(requestId) || decidedRequestIDs.contains(requestId) { return }
        pairingError = nil
        if allow, let conflict = deviceScopeConflict {
            notePairingFailure(conflict.message)
            return
        }
        guard let request = pairRequests.first(where: { $0.requestId == requestId }) else {
            notePairingFailure(String(localized: "처리할 페어링 요청이 없습니다."))
            return
        }
        guard request.expiresAt > now() else {
            pairRequests.removeAll { $0.requestId == requestId }
            pruneExpiredPairRequests()
            notePairingFailure(String(localized: "페어링 요청이 만료됐습니다. iPhone에서 다시 요청하세요."))
            return
        }
        decidingRequestIDs.insert(requestId)
        defer { decidingRequestIDs.remove(requestId) }
        // 이 결정을 처리하는 코어의 제어 서버. 답이 돌아오는 사이에 서버가 바뀌어도 이 값으로 판단한다.
        let approvingControlURL = coreControlURL
        do {
            // 승인하면 코어가 허용 목록에 직접 넣는다(따로 setDevices를 보내지 않는다).
            let device = try await serialDevices { [core] in try await core.decidePairing(requestID: requestId, allow: allow) }
            markDecided(requestId)
            pairRequests.removeAll { $0.requestId == requestId }
            if case .requestReceived(let id) = pairingState, id == requestId { pairingState = .idle }
            var kind: PairingOutcome.Kind = allow ? .allowed : .denied
            if allow, let device, !storeApprovedDevice(device, approvedBy: approvingControlURL) { kind = .notAdded }
            lastPairingOutcome = PairingOutcome(requestId: requestId, kind: kind)
        } catch {
            notePairingFailure(String(localized: "페어링 요청을 처리하지 못했습니다: \(Self.message(for: error))"))
        }
    }

    /// 제어 서버를 바꾸면 허용 목록에서 빠지는 기기 수(0이면 확인 없이 바꿔도 된다).
    public func devicesDroppedByControlURL(_ raw: String) -> Int {
        guard !devices.isEmpty, Self.normalizedControlURL(raw) != deviceControlURL else { return 0 }
        return devices.count
    }

    /// 사용자가 고급 설정에서 제어 서버를 바꿨다. 다른 서버에서 페어링한 기기가 있으면 화면이 먼저 확인을 받고
    /// `forgetOtherServerDevices: true`로 부른다(그 기기들을 지우고 새로 페어링해야 한다). 공유 중에는 바꾸지 않는다.
    @discardableResult
    public func applyControlURL(_ raw: String, forgetOtherServerDevices: Bool) -> Bool {
        guard !isRunning, !isStarting else {
            lastError = String(localized: "공유를 중지해야 제어 서버를 바꿀 수 있습니다.")
            return false
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if devicesDroppedByControlURL(value) > 0 && !forgetOtherServerDevices { return false }
        controlURL = value
        if deviceScopeConflict != nil { forgetDevicesFromOtherServer() }
        return true
    }

    /// 다른 제어 서버에서 페어링한 기기를 지운다(사용자가 확인했을 때만). 이후 지금 서버에서 새로 페어링한다.
    public func forgetDevicesFromOtherServer() {
        guard deviceScopeConflict != nil else { return }
        devices = []
        deviceControlURL = Self.normalizedControlURL(controlURL)
        saveDevices()
    }

    /// 비교용 제어 서버 URL: 앞뒤 공백 제거, 스킴·호스트 소문자, 끝 `/` 제거. 빈 값과 Tailscale 기본 제어 서버는 빈 문자열.
    public nonisolated static func normalizedControlURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard var c = URLComponents(string: trimmed), let scheme = c.scheme, let host = c.host, !host.isEmpty else { return trimmed }
        c.scheme = scheme.lowercased()
        c.host = host.lowercased()
        while c.path.hasSuffix("/") { c.path.removeLast() }
        let value = c.string ?? trimmed
        return value == "https://controlplane.tailscale.com" ? "" : value
    }

    /// 허용 목록에서 기기를 뺀다. 공유 중이면 코어에 먼저 적용하고, 성공했을 때만 목록·파일에서 지운다.
    /// 그 기기의 열린 설치 세션은 코어가 실패 처리한다.
    public func removeDevice(_ id: String) async {
        guard devices.contains(where: { $0.id == id }) else { return }
        do {
            try await serialDevices { [weak self] in
                guard let self else { return }
                let next = self.activeDevices.filter { $0.id != id }
                if self.coreStarted { try await self.core.setDevices(next) }
                self.devices.removeAll { $0.id == id }
                self.saveDevices()
            }
        } catch {
            lastError = String(localized: "기기를 허용 목록에서 빼지 못했습니다. 다시 시도하세요: \(Self.message(for: error))")
        }
    }

    /// 지금 목록을 코어에 보낸다(공유 시작 때).
    private func pushDevices() async throws {
        try await serialDevices { [weak self] in
            guard let self, self.coreStarted else { return }
            // 다른 제어 서버에서 페어링한 기기는 보내지 않는다(그 서버의 StableID가 이 서버의 다른 노드일 수 있다).
            try await self.core.setDevices(self.activeDevices)
        }
    }

    /// 허용 목록을 바꾸는 코어 호출을 한 줄로 세운다. 각 작업은 앞 작업이 끝난 뒤 그때의 목록으로 돈다.
    private func serialDevices<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = deviceTail
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        deviceTail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// 코어가 허용한 기기를 저장한다. 그 코어의 제어 서버가 지금 설정이나 저장된 기기의 서버와 다르면
    /// 저장하지 않는다(노드 StableID는 그 서버에서만 뜻이 있다).
    private func storeApprovedDevice(_ device: DeviceEntry, approvedBy approving: String?) -> Bool {
        guard let approving, approving == Self.normalizedControlURL(controlURL),
              devices.isEmpty || approving == deviceControlURL else {
            lastError = String(localized: "제어 서버가 바뀌어 \(device.name) 기기를 허용 목록에 넣지 않았습니다. 지금 서버에서 다시 페어링하세요.")
            return false
        }
        deviceControlURL = approving
        upsertDevice(device)
        return true
    }

    /// 기기가 직접 연결(addenda O)이나 알림(addenda P)에 등록했거나, 처음 케이블 설치를 해서 그 iPhone에 묶였거나(addenda R),
    /// 다른 tailnet 노드를 묶었다(addenda S). 이미 허용한 기기의 직접 연결 토큰 해시, 알림 기기 토큰, 케이블로 묶인 iPhone,
    /// 묶인 노드만 바꿔 저장한다(하나라도 바뀌었을 때). 그사이 목록에서 지운 기기는 다시 넣지 않는다.
    /// 기기를 목록에서 빼면 이 값들도 항목과 함께 사라진다.
    private func storeDeviceUpdate(_ device: DeviceEntry) {
        guard coreControlURL == deviceControlURL,
              let i = devices.firstIndex(where: { $0.id == device.id && $0.nodeStableId == device.nodeStableId }),
              devices[i].directTokenHash != device.directTokenHash || devices[i].push != device.push
                || devices[i].cableUDID != device.cableUDID || devices[i].linkedNodes != device.linkedNodes else { return }
        let added = Self.newlyLinkedNodes(old: devices[i].linkedNodes, new: device.linkedNodes)
        devices[i].directTokenHash = device.directTokenHash
        devices[i].push = device.push
        devices[i].cableUDID = device.cableUDID
        devices[i].linkedNodes = device.linkedNodes
        saveDevices()
        for node in added {
            appendActivity(.nodeLinked(devices[i]),
                           String(localized: "\(device.name)(\(device.nodeName)) 기기에 tailnet 노드를 묶었습니다: \(node.nodeName). 이 노드로 온 요청을 이 기기의 요청으로 처리합니다."))
        }
        removeSuperseded(by: devices[i])
    }

    /// `new`에만 있는 노드(새로 묶었거나 이름이 바뀐 노드).
    nonisolated static func newlyLinkedNodes(old: [LinkedNode], new: [LinkedNode]) -> [LinkedNode] {
        new.filter { node in !old.contains { $0.nodeStableId == node.nodeStableId && $0.nodeName == node.nodeName } }
    }

    /// 방금 알림을 등록한 기기와 같은 전화기의 예전 항목을 허용 목록에서 뺀다(코어에도 적용한다).
    private func removeSuperseded(by device: DeviceEntry) {
        for old in Self.supersededDevices(by: device, in: devices) {
            appendActivity(.deviceReplaced(old), String(localized: "\(old.name)(\(old.nodeName)) 기기를 허용 목록에서 뺐습니다. 같은 iPhone을 다시 페어링했습니다."))
            Task { await removeDevice(old.id) }
        }
    }

    /// `device`가 대신하게 된 예전 항목: 같은 알림 등록(토큰·앱·환경)과 같은 로그인 계정을 가졌고 더 먼저 페어링한 것.
    /// APNs 토큰은 한 전화기의 한 앱에 하나이므로, 같은 토큰을 든 더 오래된 항목은 다시 페어링하기 전의 같은 전화기다.
    nonisolated static func supersededDevices(by device: DeviceEntry, in devices: [DeviceEntry]) -> [DeviceEntry] {
        guard let push = device.push, device.isPushRegistered else { return [] }
        return devices.filter {
            $0.id != device.id && $0.push == push && $0.loginName == device.loginName && $0.pairedAt < device.pairedAt
        }
    }

    /// 기기의 알림 등록을 지운다(APNs가 토큰을 더는 받지 않을 때). 그사이 기기가 다른 토큰으로 다시 등록했으면
    /// 그대로 둔다. 공유 중이면 코어의 허용 목록에도 적용한다.
    public func removePush(deviceID: String, token: String) async {
        guard let i = devices.firstIndex(where: { $0.id == deviceID }), devices[i].push?.token == token else { return }
        devices[i].push = nil
        saveDevices()
        do {
            try await serialDevices { [weak self] in
                guard let self, self.coreStarted else { return }
                try await self.core.setDevices(self.activeDevices)
            }
        } catch {
            lastError = String(localized: "알림 등록을 지운 기기 목록을 적용하지 못했습니다: \(Self.message(for: error))")
        }
    }

    /// 알림을 보낼 수 있는 기기: 지금 제어 서버의 기기 중 개발 환경 토큰을 등록한 것.
    public var pushRecipients: [DeviceEntry] {
        Self.uniquePushRecipients(activeDevices.filter { $0.isPushRegistered && $0.push?.environment == "development" })
    }

    /// 같은 알림 등록(토큰·앱·환경)을 가진 항목은 가장 최근에 페어링한 하나만 남긴다. 순서는 그대로 둔다.
    /// iPhone을 다시 페어링하면 기기 id와 노드가 바뀌어 예전 항목이 같은 토큰을 든 채 남을 수 있다.
    nonisolated static func uniquePushRecipients(_ devices: [DeviceEntry]) -> [DeviceEntry] {
        var newest: [PushRegistration: DeviceEntry] = [:]
        for device in devices {
            guard let push = device.push else { continue }
            if let held = newest[push], held.pairedAt >= device.pairedAt { continue }
            newest[push] = device
        }
        return devices.filter { device in device.push.map { newest[$0]?.id == device.id } ?? false }
    }

    // MARK: 같은 네트워크 직접 연결

    /// 직접 연결 리스너를 켜거나 끈다. 공유 중이면 바로 적용하고, 끄면 Bonjour 광고도 멈춘다.
    public func setDirectEnabled(_ on: Bool) async {
        directEnabled = on
        guard coreStarted else { return syncAdvertisement() }
        do {
            try await core.setDirect(on)
        } catch {
            let reason = Self.message(for: error)
            lastError = on ? String(localized: "직접 연결을 켜지 못했습니다: \(reason)") : String(localized: "직접 연결을 끄지 못했습니다: \(reason)")
        }
        await refreshStatus()
        syncAdvertisement()
    }

    private func setStatus(_ new: CoreStatus?) {
        status = new
        syncAdvertisement()
    }

    /// 리스너가 열려 있고 설정이 켜져 있을 때만 광고한다.
    private func syncAdvertisement() {
        guard let advertiser else { return }
        if directEnabled, isRunning, let direct = status?.direct, direct.listening, direct.port > 0 {
            advertiser.advertise(id: direct.id, port: direct.port)
        } else {
            advertiser.stop()
        }
    }

    private func upsertDevice(_ device: DeviceEntry) {
        if let i = devices.firstIndex(where: { $0.id == device.id || $0.nodeStableId == device.nodeStableId }) {
            devices[i] = device
        } else {
            devices.append(device)
        }
        saveDevices()
    }

    private func saveDevices() {
        do {
            try deviceStore.save(StoredDeviceList(controlURL: deviceControlURL, devices: devices))
        } catch {
            lastError = String(localized: "기기 목록을 저장하지 못했습니다: \(Self.message(for: error))")
        }
    }

    // MARK: 빌드

    /// `.app` 폴더나 `.ipa` 파일을 가져온다. `.confirmed`는 사용자가 그 내용을 Debug 빌드로 직접 확인했을 때만 쓴다.
    @discardableResult
    public func importBuild(_ url: URL, mode: ImportMode = .automatic, releaseNotes: String? = nil) async -> ImportOutcome? {
        guard !isShutDown else { return nil }
        importsInProgress += 1
        defer { importsInProgress -= 1 }
        await load()
        do {
            let outcome = try await library.importBuild(at: url, mode: mode, releaseNotes: releaseNotes)
            await refreshLibrary()
            return outcome
        } catch {
            // 목록을 읽지 못해 거절됐으면 어떤 파일을 왜 읽지 못했는지 보여 준다.
            lastError = (error as? BuildLibraryError) == .notLoaded ? libraryLoadFailure ?? Self.message(for: error) : Self.message(for: error)
            await refreshLibrary()
            return nil
        }
    }

    public func unpublish(_ id: String) async {
        do {
            try await library.unpublish(id: id)
        } catch {
            lastError = String(localized: "게시를 취소하지 못했습니다: \(Self.message(for: error))")
        }
        await refreshLibrary()
    }

    public func clearRejected() async {
        await library.clearRejected()
        await refreshLibrary()
    }

    /// 빌드 목록을 새로 읽을 때마다 부른다(iPhone 앱 업데이트 페이지).
    @ObservationIgnored public var onBuildsChanged: (@MainActor ([LibraryBuild]) async -> Void)?
    /// 저장된 빌드 목록을 읽은 뒤 빌드·보낸 파일 목록을 새로 읽을 때마다 부른다(iPhone 알림).
    @ObservationIgnored public var onLibraryChanged: (@MainActor ([LibraryBuild], [ResourceDescriptor]) -> Void)?

    /// 게시한 빌드의 IPA 위치.
    public func publishedIPA(forBuildID id: String) -> URL { paths.ipaURL(forBuildID: id) }

    private func refreshLibrary() async {
        let before = builds
        defer { if builds != before, let onBuildsChanged { Task { await onBuildsChanged(builds) } } }
        builds = await library.builds
        rejected = await library.rejected
        sharedFiles = await fileLibrary.resources
        // 저장된 목록을 읽기 전의 빈 목록은 넘기지 않는다(읽은 뒤 기존 항목이 새 항목처럼 보인다).
        if libraryLoaded { onLibraryChanged?(builds, sharedFiles) }
    }

    // MARK: 보내는 파일

    /// 파일을 iPhone에 보낼 목록에 넣는다. 실패한 파일은 `lastError`에 남긴다.
    public func shareFiles(_ urls: [URL], project: ResourceProject? = nil) async {
        var failures: [String] = []
        for url in urls {
            if case .failure(let failure) = await shareFile(url, project: project) { failures.append(failure.message) }
        }
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
    }

    /// 파일 하나를 보낸다. 에이전트 명령도 이것을 쓴다.
    /// `project`가 nil이면 공통 구역이다.
    public func shareFile(_ url: URL, project: ResourceProject? = nil) async -> Result<ResourceDescriptor, ShareFileFailure> {
        guard !isShutDown else { return .failure(ShareFileFailure(String(localized: "RemoteDebug가 종료 중입니다."))) }
        await load()
        filesInProgress += 1
        defer { filesInProgress -= 1 }
        do {
            let descriptor = try await fileLibrary.add(url, project: project)
            await refreshLibrary()
            return .success(descriptor)
        } catch {
            await refreshLibrary()
            return .failure(ShareFileFailure(String(localized: "\(url.lastPathComponent)을(를) 보내지 못했습니다: \(Self.message(for: error))")))
        }
    }

    /// 링크를 보낸다. 에이전트 명령도 이것을 쓴다.
    public func shareLink(_ url: URL, title: String? = nil, project: ResourceProject? = nil) async -> Result<ResourceDescriptor, ShareFileFailure> {
        guard !isShutDown else { return .failure(ShareFileFailure(String(localized: "RemoteDebug가 종료 중입니다."))) }
        await load()
        do {
            let descriptor = try await fileLibrary.addLink(url, title: title, project: project)
            await refreshLibrary()
            return .success(descriptor)
        } catch {
            await refreshLibrary()
            return .failure(ShareFileFailure(String(localized: "링크를 보내지 못했습니다: \(Self.message(for: error))")))
        }
    }

    /// 보낸 항목을 다른 구역으로 옮긴다(nil이면 공통).
    public func moveSharedFile(_ id: String, to project: ResourceProject?) async {
        do {
            try await fileLibrary.move(id: id, to: project)
        } catch {
            lastError = String(localized: "구역을 옮기지 못했습니다: \(Self.message(for: error))")
        }
        await refreshLibrary()
    }

    public func unshareFile(_ id: String) async {
        do {
            try await fileLibrary.remove(id: id)
        } catch {
            lastError = String(localized: "파일을 지우지 못했습니다: \(Self.message(for: error))")
        }
        await refreshLibrary()
    }

    // MARK: 감시 폴더

    /// 사용자가 고른 폴더를 저장하고 감시를 시작한다. 첫 검사(가져오기 포함)가 끝날 때 돌아온다.
    public func chooseFolder(_ url: URL) async {
        guard !isShutDown else { return }
        do {
            try bookmarks.save(url)
        } catch {
            lastError = String(localized: "폴더 접근 권한을 저장하지 못했습니다. 다음 실행 때 폴더를 다시 골라야 합니다.")
        }
        await beginWatching(url)
    }

    /// 감시 폴더를 지금 다시 훑는다. 폴더를 읽을 수 없으면 `watchProblem`에 남는다.
    public func rescan() async {
        guard let watcher else {
            lastError = String(localized: "감시할 폴더를 먼저 고르세요.")
            return
        }
        await watcher.rescan()
    }

    public func forgetFolder() async {
        await stopWatching()
        bookmarks.clear()
    }

    private func resumeSavedFolder(generation: Int) async {
        guard generation == folderGeneration, watcher == nil else { return }
        switch bookmarks.savedFolder() {
        case .none:
            return
        case .folder(let url):
            await beginWatching(url)
        case .unresolvable(let path):
            guard generation == folderGeneration, watcher == nil else { return }
            watchProblem = WatchProblem(path: path ?? "", message: WatchProblem.unresolvableMessage)
        }
    }

    private func noteRootStatus(_ status: FolderWatcher.RootStatus, path: String, generation: Int) {
        guard generation == folderGeneration else { return }
        switch status {
        case .readable: watchProblem = nil
        case .missing: watchProblem = WatchProblem(path: path, message: WatchProblem.missingMessage)
        case .unreadable: watchProblem = WatchProblem(path: path, message: WatchProblem.unreadableMessage)
        }
    }

    private func beginWatching(_ url: URL) async {
        await stopWatching()
        guard !isShutDown else { return }
        folderGeneration += 1
        let generation = folderGeneration
        folderAccess = SecurityScopedAccess(url)
        watchedFolder = url
        let path = url.path
        let watcher = FolderWatcher(
            root: url, options: watcherOptions, stateFile: paths.watchStateFile,
            onRootStatus: { [weak self] status in
                await self?.noteRootStatus(status, path: path, generation: generation)
            }
        ) { [weak self] app in
            await self?.importFromWatcher(app, generation: generation) ?? false
        }
        let previous = self.watcher
        self.watcher = watcher
        if let previous { await previous.stop() }
        guard generation == folderGeneration else { return }
        await watcher.start()
    }

    private func stopWatching() async {
        folderGeneration += 1
        let old = watcher
        watcher = nil
        folderAccess?.stop()
        folderAccess = nil
        watchedFolder = nil
        watchProblem = nil
        if let old { await old.stop() }
    }

    /// 감시가 찾은 빌드. 정책 거부도 처리한 것으로 본다(같은 지문은 다시 검사하지 않는다).
    /// 그사이 감시를 멈췄거나 다른 폴더로 바꿨으면 가져오지 않는다(처리하지 않은 것으로 남는다).
    private func importFromWatcher(_ app: URL, generation: Int) async -> Bool {
        guard generation == folderGeneration else { return false }
        return await importBuild(app) != nil
    }

    // MARK: 오류 문장

    nonisolated static func message(for error: any Error) -> String {
        HostErrorText.message(for: error)
    }
}

/// `devices.json`: 허용 목록과 그 목록을 페어링한 제어 서버. 예전 형식(`{"devices":[…]}`)도 읽는다.
struct StoredDeviceList: Codable, Sendable {
    var controlURL: String?
    var devices: [DeviceEntry]
}

/// 다른 제어 서버에서 페어링한 기기가 저장돼 있다.
public struct DeviceScopeConflict: Sendable, Hashable {
    /// 그 기기들을 페어링한 제어 서버(빈 문자열은 Tailscale 기본 제어 서버).
    public var savedControlURL: String
    public var deviceCount: Int

    public var savedServerName: String { savedControlURL.isEmpty ? String(localized: "Tailscale 기본 제어 서버") : savedControlURL }

    public var message: String {
        String(localized: "저장된 기기 \(String(deviceCount))대는 다른 제어 서버(\(savedServerName))에서 페어링해 지금 서버에서는 허용하지 않습니다. 기기 목록을 지우고 새로 페어링하거나, 제어 서버를 원래대로 되돌리세요.")
    }
}

/// 끝난 페어링 요청의 결과.
public struct PairingOutcome: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case allowed
        case denied
        case expired
        /// 코어는 허용했지만 그사이 제어 서버가 바뀌어 저장하지 않았다.
        case notAdded
    }

    public var requestId: String
    public var kind: Kind
}

public enum PairingAvailability: Sendable, Hashable {
    case ready
    /// 페어링 코드를 열어도 iPhone이 이 Mac에 닿지 못한다. 이유와 다음 행동.
    case unavailable(String)
}

/// 감시 폴더 문제와 다음 행동.
public struct WatchProblem: Sendable, Hashable {
    /// 문제가 난 폴더 경로(모르면 빈 문자열).
    public var path: String
    public var message: String

    static let missingMessage = String(localized: "감시 폴더를 찾을 수 없습니다. 폴더를 지웠거나 옮겼다면 폴더를 다시 고르세요.")
    static let unreadableMessage = String(localized: "감시 폴더를 읽을 수 없습니다. 폴더를 다시 골라 접근 권한을 주세요.")
    static let unresolvableMessage = String(localized: "저장한 감시 폴더를 열 수 없습니다. 폴더를 다시 고르세요.")
}

public struct ShareFileFailure: Error, Sendable, Hashable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

// MARK: 피드백 메일의 암호화된 진단

extension HostModel {
    /// 프로젝트의 진단 암호화 공개키(base64). 키가 없으면 만들어 이 Mac의 키체인에 둔다.
    public func feedbackPublicKey(for project: ConnectedProject) async throws -> String {
        let keys = feedbackKeys
        let account = "\(project.name) v1"
        do {
            return try await Task.detached {
                try keys.makeKey(account: account).publicKey.rawRepresentation.base64EncodedString()
            }.value
        } catch {
            throw DiagnosticsFailure.keyError(error)
        }
    }

    public func migrateFeedbackKeys() async -> Result<Int, DiagnosticsFailure> {
        guard !isMigratingFeedbackKeys else {
            return .failure(DiagnosticsFailure(String(localized: "기존 진단 키를 이전하고 있습니다.")))
        }
        isMigratingFeedbackKeys = true
        defer { isMigratingFeedbackKeys = false }
        let keys = feedbackKeys
        do {
            return .success(try await Task.detached { try keys.migrateLegacyKeys() }.value)
        } catch {
            return .failure(DiagnosticsFailure.keyError(error))
        }
    }

    /// Imports the attachment and returns the saved record ID.
    public func importDiagnostics(_ url: URL) async -> Result<String, DiagnosticsFailure> {
        diagnosticsImports += 1
        defer { diagnosticsImports -= 1 }
        let keys = feedbackKeys
        let result = await Task.detached { () -> Result<Data, DiagnosticsFailure> in
            guard DiagnosticsFile.matches(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let sealed = try? Data(contentsOf: url) else {
                return .failure(DiagnosticsFailure(String(localized: "암호화된 진단 파일을 읽지 못했습니다.")))
            }
            do {
                return .success(try FeedbackEnvelope.open(sealed, keys: keys))
            } catch let failure as FeedbackEnvelope.Failure {
                return .failure(DiagnosticsFailure(failure.message))
            } catch {
                return .failure(DiagnosticsFailure.keyError(error))
            }
        }.value
        switch result {
        case .success(let plain):
            if let id = saveDiagnostics(plain, from: url) { return .success(id) }
            return .failure(DiagnosticsFailure(String(localized: "복호화한 진단 기록을 저장하지 못했습니다.")))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Shows file-specific errors in the Mac window. The MCP response uses the error without the filename.
    public func openDiagnostics(_ urls: [URL]) async {
        for url in urls {
            switch await importDiagnostics(url) {
            case .success(let id): diagnosticsOpenedRecordID = id
            case .failure(let failure):
                diagnosticsImportErrors.append("\(url.lastPathComponent) — \(failure.message)")
            }
        }
    }

    private func saveDiagnostics(_ plain: Data, from url: URL) -> String? {
        var image: Data?
        var text = String(decoding: plain, as: UTF8.self)
        var bundleId = "", appVersion = ""
        if var object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] {
            // 옛 패키지가 진단 파일에 넣던 사진은 따로 저장하고 글에서는 뺀다. 지금은 사진과 파일이 메일에 그대로 붙어 온다.
            if var diagnostics = object["diagnostics"] as? [String: Any] {
                image = (diagnostics.removeValue(forKey: "screenshotBase64") as? String).flatMap { Data(base64Encoded: $0) }
                object["diagnostics"] = diagnostics
                // 새 패키지는 어느 앱의 어느 빌드에서 온 것인지 함께 넣는다. 목록에 그대로 보인다.
                (bundleId, appVersion) = Self.diagnosticsApp(diagnostics["app"])
            }
            if let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                text = String(decoding: pretty, as: UTF8.self)
            }
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let name = url.deletingPathExtension().lastPathComponent + ".json"
        return crashLogs.receive(DeviceCrashEvent(deviceId: "", deviceName: String(localized: "메일 첨부"), nodeName: "",
                                           report: CrashReport(kind: .feedback, name: name, bundleId: bundleId, appVersion: appVersion, crashedAt: modified, text: text, image: image)))
    }

    /// 진단 파일의 `app`(`bundleId`, `version`, `build`)에서 번들 ID와 `1.2 (7)` 모양의 버전을 읽는다. 없거나 모양이 다르면 빈 글자.
    nonisolated static func diagnosticsApp(_ value: Any?) -> (bundleId: String, appVersion: String) {
        guard let app = value as? [String: Any] else { return ("", "") }
        func text(_ key: String) -> String { String((app[key] as? String ?? "").prefix(200)) }
        let version = text("version"), build = text("build")
        return (text("bundleId"), build.isEmpty ? version : "\(version) (\(build))")
    }
}

public struct DiagnosticsFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) { self.message = message }

    static func keyError(_ error: any Error) -> Self {
        Self((error as? FeedbackKeyFailure)?.message ?? String(localized: "진단 키를 읽지 못했습니다."))
    }
}

public enum DiagnosticsFile {
    public static let typeIdentifier = "com.oozoofrog.app.remotedebug.diagnostics"

    public static func matches(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "afdiag"
    }

    static func localURL(_ path: String) -> URL? {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return nil }
        let url = URL(fileURLWithPath: path)
        return matches(url) ? url : nil
    }

    static let pathRequired = "file_path에 .afdiag 파일의 절대 경로가 필요합니다."
}

extension HostModel.PairingState {
    var isOfferOpen: Bool {
        if case .offerOpen = self { return true }
        return false
    }
}
