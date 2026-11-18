import Foundation
import Observation
import RDModels

/// 설치 전송 진행(`InstallState.transferring`).
public struct InstallProgress: Equatable, Sendable {
    /// Mac이 지금까지 보낸 서로 다른 IPA 바이트 수(`size`를 넘지 않는다, docs/protocol-addenda.md C.2).
    public var bytesServed: Int64
    /// IPA 크기(바이트). 모르면 0.
    public var size: Int64

    public init(bytesServed: Int64, size: Int64) {
        self.bytesServed = bytesServed
        self.size = size
    }

    /// 0...1 진행률. 크기를 모르면 `nil`.
    public var fraction: Double? {
        guard size > 0 else { return nil }
        return min(1, max(0, Double(bytesServed) / Double(size)))
    }
}

/// 빌드 하나의 설치 진행 상태.
public enum InstallState: Equatable, Sendable {
    /// 설치 세션을 만드는 중(Mac이 IPA를 다시 확인하느라 최대 1분쯤 걸릴 수 있다).
    case preparing
    /// 설치 창을 열었고 iOS 설치기가 받기 시작하기 전.
    case waitingForInstaller
    /// iOS 설치기가 매니페스트·IPA를 받는 중.
    case transferring(bytesServed: Int64, size: Int64)
    /// Mac이 IPA를 끝까지 보냈다. iOS가 실제로 설치를 마쳤는지는 알 수 없다(홈 화면에서 진행된다).
    case completed
    /// 설치 세션이 만료되었다. 다시 설치하면 새 세션을 연다.
    case expired
    case failed(message: String)

    /// 앱이 실행되지 않을 때 보여 줄 개발자 모드 안내.
    public static let developerModeHint =
        String(localized: "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요.")
    public static let completedMessage =
        String(localized: "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요. \(developerModeHint)")
    public static let expiredMessage = String(localized: "설치 세션이 만료되었습니다. 다시 설치하세요.")

    public var isInProgress: Bool {
        switch self {
        case .preparing, .waitingForInstaller, .transferring: true
        case .completed, .expired, .failed: false
        }
    }

    /// 전송 중일 때의 진행. 그 밖에는 `nil`.
    public var progress: InstallProgress? {
        guard case let .transferring(served, size) = self else { return nil }
        return InstallProgress(bytesServed: served, size: size)
    }

    /// 0...1 진행률. 전송 중이 아니거나 크기를 모르면 `nil`.
    public var fraction: Double? { progress?.fraction }

    /// 개발자 모드 안내를 함께 보여 줄 상태인지(`completed`).
    public var showsDeveloperModeHint: Bool { self == .completed }

    /// 화면에 보여 줄 안내(완료·만료·실패일 때).
    public var message: String? {
        switch self {
        case .completed: Self.completedMessage
        case .expired: Self.expiredMessage
        case .failed(let message): message
        default: nil
        }
    }
}

/// iPhone 앱의 상태와 동작. UI는 이 값을 그리고 의도 메서드만 부른다.
///
/// 화면 상태와 읽을 값:
/// - 페어링 안 됨: `phase == .unpaired`.
/// - Mac에 연결하는 중(짝 맺기와 마무리): `phase == .requestingPairing`.
/// - Mac 승인 대기: `phase == .waitingApproval(deviceName:)`. Mac 화면의 숫자와 견줄 `confirmationCode`,
///   남은 시간은 `pairingExpiresAt`. 취소는 `cancelPairing()`.
/// - VPN이 켜지면 이어 할 페어링: `queuedPairing`(취소는 `cancelPairing()`).
/// - 시작하기 전에 사용자에게 물을 페어링(열린 링크, 다른 Mac으로 바꿈): `pendingConfirmation`
///   (`confirmPending()` / `dismissPending()`).
/// - VPN: `tunnel`(`.off`, `.connecting`, `.disconnecting`, `.needsLogin(authURL:)`, `.failed`, `.connected`). 동작이 VPN 때문에 멈췄으면 `needsTunnel`.
/// - 빌드 목록: `builds`. 한 번이라도 받았으면 `buildsLoadedAt`이 있다(받았는데 비어 있으면 게시된 빌드가 없는 것).
///   새로고침 중이면 `isRefreshing`, 마지막 새로고침이 실패했으면 `refreshError`.
/// - 설치: `installs[buildID]`(`InstallState`). 전송 진행은 `installProgress(for:)`, 끝난 상태 지우기는 `clearInstall(_:)`.
///   설치기를 기다리는 동안 설치 창 다시 열기는 `reopenInstaller(_:)`, 그만두기는 `cancelInstall(_:)`.
/// - 마지막 실패 안내: `lastError`(지우기는 `clearError()`).
/// Mac이 보낸 파일 하나를 받는 상태.
public enum FileDownloadState: Equatable, Sendable {
    case downloading
    case failed(String)
}

/// 받는 중인 파일의 진행.
public struct FileTransferProgress: Equatable, Sendable {
    public var received: Int64
    public var total: Int64
    /// 받기 시작한 시각(속도·남은 시간 계산).
    public var startedAt: Date?

    public init(received: Int64, total: Int64, startedAt: Date? = nil) {
        self.received = received
        self.total = total
        self.startedAt = startedAt
    }

    /// 초당 바이트. 시작한 지 1초가 안 됐으면 nil.
    public func bytesPerSecond(now: Date) -> Double? {
        guard let startedAt, now.timeIntervalSince(startedAt) >= 1, received > 0 else { return nil }
        return Double(received) / now.timeIntervalSince(startedAt)
    }

    /// 남은 시간(초).
    public func remainingSeconds(now: Date) -> Double? {
        guard let speed = bytesPerSecond(now: now), speed > 0 else { return nil }
        return Double(max(0, total - received)) / speed
    }

    public var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

/// 파일 받기의 시작·진행·끝. 앱은 이것으로 라이브 액티비티(Dynamic Island)를 갱신한다.
public struct FileTransferUpdate: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case receiving
        case received
        case failed(String)
        case cancelled
    }

    public var resourceID: String
    public var name: String
    public var progress: FileTransferProgress
    public var phase: Phase
}

/// 진행 알림을 1% 단위로 줄인다(전송 중에는 수천 번 불린다).
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep = -1

    func shouldReport(_ received: Int64, _ total: Int64) -> Bool {
        let step = total > 0 ? Int(Double(received) / Double(total) * 100) : 0
        return lock.withLock {
            guard step != lastStep else { return false }
            lastStep = step
            return true
        }
    }
}

@MainActor
@Observable
public final class ClientModel {
    public enum Phase: Equatable, Sendable {
        case unpaired
        case requestingPairing
        /// Mac에서 승인을 기다린다. `deviceName`은 Mac에 표시되는 이 iPhone의 이름.
        case waitingApproval(deviceName: String)
        case paired
    }

    public struct Timing: Sendable {
        /// 짝을 맺은 직후 Mac 정보(`GET /v1/info`)를 받지 못했을 때 다시 묻는 간격(최대 3번 묻는다).
        public var pairingInfoRetryInterval: Duration
        /// 승인 대기 화면에 보이는 남은 시간(Mac의 승인 제한과 같게 둔다).
        public var pairingTimeout: TimeInterval
        public var sessionPollInterval: Duration
        public var sessionTimeout: TimeInterval
        /// 호스트 요청의 제한 시간.
        public var requestTimeouts: HostAPI.Timeouts
        /// 자동으로 켠 VPN이 연결되기를 기다리는 시간과 확인 간격.
        public var autoStartTimeout: TimeInterval
        public var autoStartPollInterval: Duration
        /// 자동으로 켠 VPN을 쓸 일이 없어진 뒤 끄기까지의 시간과 확인 간격.
        public var autoOffDelay: TimeInterval
        public var autoOffCheckInterval: Duration

        public init(
            pairingInfoRetryInterval: Duration = .seconds(1),
            pairingTimeout: TimeInterval = 120,
            sessionPollInterval: Duration = .seconds(1),
            sessionTimeout: TimeInterval = 600,
            requestTimeouts: HostAPI.Timeouts = .standard,
            autoStartTimeout: TimeInterval = 15,
            autoStartPollInterval: Duration = .milliseconds(250),
            autoOffDelay: TimeInterval = 30,
            autoOffCheckInterval: Duration = .seconds(1)
        ) {
            self.pairingInfoRetryInterval = pairingInfoRetryInterval
            self.pairingTimeout = pairingTimeout
            self.sessionPollInterval = sessionPollInterval
            self.sessionTimeout = sessionTimeout
            self.requestTimeouts = requestTimeouts
            self.autoStartTimeout = autoStartTimeout
            self.autoStartPollInterval = autoStartPollInterval
            self.autoOffDelay = autoOffDelay
            self.autoOffCheckInterval = autoOffCheckInterval
        }

        public static let standard = Timing()
    }

    // MARK: 상태

    public private(set) var phase: Phase = .unpaired
    public private(set) var host: PairedHost?
    /// 승인 대기의 마감 시각. 승인 대기가 아니면 `nil`.
    public private(set) var pairingExpiresAt: Date?
    /// 승인 대기 중 Mac 화면의 숫자와 견줄 확인 숫자(6자리). 승인 대기가 아니면 `nil`. 로그·저장에 남기지 않는다.
    public private(set) var confirmationCode: String?
    /// VPN이 연결되면 이어 할 페어링. VPN이 꺼진 채 링크를 열었을 때 생긴다.
    public private(set) var queuedPairing: PairingProposal?
    /// 사용자가 확인해야 시작하는 페어링: 앱 밖에서 열린 링크, 이미 페어링한 Mac이나 진행 중인 페어링과 다른 Mac.
    public private(set) var pendingConfirmation: PairingConfirmation?
    public private(set) var builds: [BuildDescriptor] = []
    /// 빌드 목록을 마지막으로 받은 시각. 아직 받지 못했으면 `nil`.
    public private(set) var buildsLoadedAt: Date?
    /// 마지막 새로고침의 실패 안내. 성공하면 `nil`.
    public private(set) var refreshError: String?
    /// 빌드 id → 설치 상태.
    public private(set) var installs: [String: InstallState] = [:]
    public private(set) var tunnel: TunnelState
    /// 마지막 실패 안내(한국어).
    public private(set) var lastError: String?
    public private(set) var isRefreshing = false
    /// Mac이 보낸 파일 목록(docs/protocol-addenda.md H). Mac 앱이 이 기능을 모르면 빈 목록.
    public private(set) var resources: [ResourceDescriptor] = []
    /// Mac의 에이전트 요청 상태(docs/protocol-addenda.md K). 아직 받지 못했으면 `nil`.
    public private(set) var agentBoard: AgentBoard?
    /// 에이전트 상태를 받지 못했거나 요청을 보내지 못한 이유.
    public private(set) var agentError: String?
    /// 이 iPhone에 받아 둔 파일.
    public private(set) var receivedFiles: [ReceivedFile] = []
    /// 받는 중이거나 받지 못한 파일(`ResourceDescriptor.id` 기준).
    public private(set) var fileDownloads: [String: FileDownloadState] = [:]
    /// 받는 중인 파일의 진행(1% 단위로 갱신).
    public private(set) var fileProgress: [String: FileTransferProgress] = [:]
    /// 파일 받기의 시작·진행·끝을 알린다. 앱이 라이브 액티비티를 갱신한다.
    @ObservationIgnored public var onFileTransfer: (@MainActor (FileTransferUpdate) -> Void)?
    /// 마지막 동작이 VPN이 연결되지 않아 멈췄다. VPN이 연결되면 멈춘 페어링·새로고침을 이어 간다.
    public private(set) var needsTunnel = false
    /// Mac이 필요한 동작 때문에 앱이 VPN을 켜고 연결을 기다리는 중이다. 화면은 "VPN 켜는 중…"을 보여 준다.
    public private(set) var isAutoStartingVPN = false
    /// 지금 VPN은 앱이 자동으로 켠 것이다. 쓸 일이 없어지면 `Timing.autoOffDelay` 뒤에 끈다.
    /// 사용자가 켜거나 끈 VPN, 다른 앱의 VPN에는 `false`다.
    public private(set) var vpnAutoStarted = false
    /// 같은 네트워크의 Mac에 VPN 없이 직접 연결해 쓰고 있다(docs/protocol-addenda.md O).
    public private(set) var isDirectConnected = false
    /// 진단 로그. 화면과 앱(시작·VPN)도 여기에 남긴다.
    public let logBook: DeviceLogBook
    public let crashBook: CrashBook
    public private(set) var isSendingCrashes = false
    public private(set) var crashSendError: String?
    /// 로그를 보내는 중.
    public private(set) var isSendingLogs = false
    /// 마지막으로 로그를 모두 보낸 시각.
    public private(set) var logsSentAt: Date?
    /// 마지막 로그 보내기의 실패 안내. 성공하면 `nil`.
    public private(set) var logSendError: String?
    /// 페어링 링크에 Tailscale 키가 있을 때 그 키로 VPN을 켜는 동작. 앱이 연결한다(키를 저장하지 않는다).
    @ObservationIgnored public var connectWithAuthKey: (@MainActor (String) async -> Void)?
    /// 새 빌드·파일 알림 스위치. 알림을 쓰지 않는 앱(`push` 없이 만든 모델)은 항상 `false`.
    public private(set) var pushEnabled = false
    /// 이번 실행에서 iOS에게 받은 기기 토큰(소문자 16진수). 아직 받지 못했으면 `nil`.
    public private(set) var pushToken: String?
    /// 마지막으로 Mac에 등록하는 데 성공한 값(저장소와 같다).
    public private(set) var pushRecord: PushRecord?
    /// 이번 실행에서 알림 등록을 모른다고 답한 Mac(`404 not_found`). 다음 실행 전까지 다시 시도하지 않는다.
    private var pushUnsupportedHosts: Set<String> = []

    // MARK: 의존성

    private let deviceName: String
    private let client: ClientInfo
    private let transport: any HTTPTransport
    private let store: any PairedHostStoring
    private let opener: any URLOpening
    private let tunnelController: any TunnelControlling
    private let clock: any PollingClock
    private let policy: HostPolicy
    /// 페어링 링크의 연결 도메인 주소(Info.plist `RDPairLinkBase`). nil이면 사용자 지정 스킴 링크만 받는다.
    private let pairingLinkBase: PairingLinkBase?
    private let pairingService: any PairingService
    private let timing: Timing
    private let receivedStore: ReceivedFileStore
    /// 같은 네트워크 직접 연결. 없으면 모든 요청이 VPN(tailnet) 경로로 간다.
    private let direct: DirectRoute?
    /// 새 빌드·파일 알림. 없으면 기기 토큰을 등록하지 않는다(업데이트 앱).
    private let push: PushSetup?

    // MARK: 내부 상태

    private struct ActiveSession { var sessionID: String; var installURL: URL; var deadline: Date }
    private struct Running { var token: UUID; var task: Task<Void, Never> }
    private struct VPNNotConnected: Error {}
    private struct PairingRun { var token: UUID; var proposal: PairingProposal; var task: Task<Void, Never> }

    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var pairing: PairingRun?
    /// 페어링이 기다리는 VPN을 준비하는 작업(인증 키로 켜기, 자동으로 켜기). 페어링을 그만두면 함께 취소한다.
    @ObservationIgnored private var pairingPrep: Task<Void, Never>?
    /// 확인 숫자를 받을 수 있는 짝 맺기의 토큰. 짝 맺기가 끝나면 비운다(늦게 온 숫자를 버리는 데 쓴다).
    @ObservationIgnored private var approvalToken: UUID?
    /// 마지막으로 승인된 제안의 지문. 같은 QR이 다시 들어오면(1회용이라 다시 보내면 거절된다) 무시한다.
    @ObservationIgnored private var lastApprovedFingerprint: Data?
    @ObservationIgnored private var installTasks: [String: Running] = [:]
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeSessions: [String: ActiveSession] = [:]
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var tunnelObserver: Task<Void, Never>?
    @ObservationIgnored private var refreshesInFlight = 0
    /// 앱이 백그라운드에 있다(`stopPolling`과 `resumePolling` 사이). 이때 끝난 새로고침 실패는 화면에 올리지 않는다.
    @ObservationIgnored private var isBackgrounded = false
    /// 백그라운드로 간 횟수. 새로고침 도중에 다녀왔는지 가린다.
    @ObservationIgnored private var backgroundCount = 0
    /// 호스트가 바뀔 때(복원·다른 호스트 승인·잊기)마다 늘어난다. 기다리는 동안 값이 바뀐 작업은 결과를 쓰지 않는다.
    @ObservationIgnored private var hostGeneration = 0
    @ObservationIgnored private var autoStartTask: Task<Bool, Never>?
    @ObservationIgnored private var idle = AutoVPNIdle()
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var idleToken: UUID?
    /// 직접 경로로 받는 중인 파일. VPN이 필요한 일로 세지 않는다.
    @ObservationIgnored private var directDownloads: Set<String> = []
    /// 이번 실행에서 Mac에 등록을 확인한 값.
    @ObservationIgnored private var pushConfirmed: PushRecord?
    @ObservationIgnored private var isSyncingPush = false
    /// Mac을 잊는 중이다. 이 사이에는 등록을 새로 보내지 않는다.
    @ObservationIgnored private var isForgettingPush = false
    @ObservationIgnored private var pushSyncWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        deviceName: String,
        client: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        store: any PairedHostStoring,
        opener: any URLOpening,
        tunnel: any TunnelControlling,
        clock: any PollingClock = SystemPollingClock(),
        hostPolicy: HostPolicy = .tailnetOnly,
        pairingService: any PairingService = UnavailablePairingService(),
        pairingLinkBase: PairingLinkBase? = nil,
        timing: Timing = .standard,
        logBook: DeviceLogBook? = nil,
        crashBook: CrashBook? = nil,
        receivedFiles: ReceivedFileStore? = nil,
        direct: DirectRoute? = nil,
        push: PushSetup? = nil
    ) {
        self.push = push
        self.pushEnabled = push?.store.enabled ?? false
        self.pushRecord = push?.store.record
        self.deviceName = deviceName
        self.client = client
        self.transport = transport
        self.store = store
        self.opener = opener
        self.tunnelController = tunnel
        self.clock = clock
        self.policy = hostPolicy
        self.pairingService = pairingService
        self.pairingLinkBase = pairingLinkBase
        self.timing = timing
        self.direct = direct
        self.logBook = logBook ?? DeviceLogBook()
        self.crashBook = crashBook ?? CrashBook()
        #if os(iOS)
        self.receivedStore = receivedFiles ?? .standard()
        #else
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("rd-received-\(UUID().uuidString)", isDirectory: true)
        self.receivedStore = receivedFiles ?? ReceivedFileStore(directory: temp, indexURL: temp.appendingPathComponent(".index.json"))
        #endif
        self.receivedFiles = self.receivedStore.list()
        self.tunnel = tunnel.currentState()

        let updates = tunnel.stateUpdates()
        tunnelObserver = Task { [weak self] in
            for await state in updates {
                guard let self else { return }
                self.tunnelDidChange(state)
            }
        }
    }

    isolated deinit {
        tunnelObserver?.cancel()
        resumeTask?.cancel()
        autoStartTask?.cancel()
        idleTask?.cancel()
        pairing?.task.cancel()
        pairingPrep?.cancel()
        for running in installTasks.values { running.task.cancel() }
        for task in downloadTasks.values { task.cancel() }
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: 복원

    /// 저장된 호스트를 불러오고 빌드 목록을 받는다. 앱이 시작할 때 부른다.
    /// VPN 구성은 건드리지 않는다(`prepare`는 사용자가 VPN을 켤 때만 부른다). VPN이 꺼져 있으면 켜질 때 받는다.
    public func restore() async {
        tunnel = tunnelController.currentState()
        guard host == nil, let saved = store.load() else { return }
        guard let fqdn = policy.validatedHost(saved.fqdn), fqdn == saved.fqdn else {
            store.clear()
            return
        }
        hostGeneration &+= 1
        let generation = hostGeneration
        host = saved
        log(.info, "pairing", "저장된 Mac 불러옴: \(saved.hostName) (\(saved.fqdn))")
        if phase == .unpaired { phase = .paired }
        guard generation == hostGeneration else { return }
        await refresh()
    }

    // MARK: 페어링

    /// 앱이 받은 URL을 처리한다. 페어링 링크(`remotedebug://pair#…`, 연결 도메인 주소가 있으면 그 https 링크)가 아니면 `false`.
    /// 링크는 어디서든 올 수 있으므로 시작하기 전에 Mac 주소를 보이고 사용자에게 묻는다(`pendingConfirmation`).
    /// 읽지 못한 링크와 다른 https 주소에 실린 제안은 `lastError`에 안내를 남긴다.
    @discardableResult
    public func handle(url: URL) -> Bool {
        let text = url.absoluteString
        let isPairingAddress = PairingInput.isPairingAddress(text, linkBase: pairingLinkBase)
        guard isPairingAddress || PairingInput.isHTTPSAddress(text) else { return false }
        do throws(PairingOfferIssue) {
            request(try PairingInput.read(text, with: pairingService, policy: policy, linkBase: pairingLinkBase), source: .openedLink)
        } catch {
            // 페어링과 상관없는 https 주소는 이 앱이 다루지 않는다.
            if !isPairingAddress, error == .notAnOffer { return false }
            lastError = error.userMessage
        }
        return true
    }

    /// 앱 안의 카메라로 읽은 QR 글자로 페어링한다. 앱 안에서 읽은 글자는 OS의 링크 배달을 거치지 않으므로 묻지 않고
    /// 시작한다(다른 Mac으로 바뀌는 경우만 `handle(url:)`처럼 묻는다).
    /// 페어링 QR이 아니면 안내 문구를 돌려주고 아무것도 시작하지 않는다.
    public func pair(scanned text: String) -> String? {
        do throws(PairingOfferIssue) {
            request(try PairingInput.read(text, with: pairingService, policy: policy, linkBase: pairingLinkBase), source: .scanned)
            return nil
        } catch {
            return error.userMessage
        }
    }

    /// `pendingConfirmation`의 제안으로 페어링을 시작한다. 진행 중이던 페어링은 그만둔다.
    /// 지금 페어링한 Mac은 새 Mac이 승인할 때까지 그대로 남는다.
    public func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        startPairing(pending.proposal)
    }

    /// `pendingConfirmation`을 버린다. 아무 상태도 바꾸지 않는다.
    public func dismissPending() {
        pendingConfirmation = nil
    }

    /// 진행 중이거나 VPN을 기다리는 페어링을 그만둔다. 페어링한 Mac과 VPN은 그대로 둔다.
    public func cancelPairing() {
        pairing?.task.cancel()
        pairing = nil
        pairingPrep?.cancel()
        pairingPrep = nil
        approvalToken = nil
        pairingExpiresAt = nil
        confirmationCode = nil
        queuedPairing = nil
        if phase == .requestingPairing || isWaitingApproval { phase = settledPhase }
    }

    private enum PairingSource { case openedLink, scanned }

    private func request(_ proposal: PairingProposal, source: PairingSource) {
        // 제안이 다른 정책으로 읽혔을 수 있으므로 이 모델의 정책으로 다시 확인한다.
        guard let validHost = policy.validatedHost(proposal.host), validHost == proposal.host else {
            lastError = PairingOfferIssue.hostNotAllowed.userMessage
            return
        }
        // 같은 링크가 다시 들어왔다(QR을 다시 찍음, URL 중복 전달). 1회용 제안을 다시 보내지 않는다.
        if proposal == inFlightProposal { return }
        if proposal.fingerprint == lastApprovedFingerprint, host?.fqdn == proposal.host { return }
        if let reason = confirmationReason(for: proposal, source: source) {
            pendingConfirmation = PairingConfirmation(proposal: proposal, reason: reason)
            return
        }
        pendingConfirmation = nil
        startPairing(proposal)
    }

    private func confirmationReason(for proposal: PairingProposal, source: PairingSource) -> PairingConfirmation.Reason? {
        if source == .openedLink { return .openedLink }
        if let host, host.fqdn != proposal.host { return .replacement }
        if let other = inFlightProposal, other != proposal { return .replacement }
        return nil
    }

    /// 진행 중이거나 VPN을 기다리는 페어링의 Mac 주소.
    public var pairingHost: String? { inFlightProposal?.host }

    /// 진행 중(연결·승인 대기)이거나 VPN을 기다리는 페어링의 제안.
    private var inFlightProposal: PairingProposal? {
        pairing?.proposal ?? queuedPairing
    }

    private func startPairing(_ proposal: PairingProposal) {
        cancelPairing()
        lastError = nil
        log(.info, "pairing", "페어링 시작: \(proposal.host)")
        tunnel = tunnelController.currentState()
        guard ownTunnelConnected else {
            // 이 앱의 터널이 연결되면 이어 간다. 바깥 VPN(공식 Tailscale 앱 등)이 연결돼 있어도 같다.
            needsTunnel = true
            queuedPairing = proposal
            lastError = Self.pairingTunnelMessage(for: tunnel)
            // 제안에 Tailscale 키가 있으면 로그인 없이 이 앱의 VPN을 켠다.
            if let key = proposal.authKey, let connect = connectWithAuthKey {
                log(.info, "vpn", "페어링 제안의 Tailscale 키로 VPN 켜는 중")
                lastError = nil
                pairingPrep = Task { await connect(key) }
            } else {
                pairingPrep = autoStartForQueuedWork()
            }
            return
        }
        needsTunnel = false
        idle.noteNeed()
        let token = UUID()
        pairing = PairingRun(token: token, proposal: proposal, task: Task { [weak self] in
            await self?.runPairing(proposal, token: token)
        })
    }

    /// 앱용 페어링이 지나갈 수 있는 터널이 연결돼 있다: 이 앱의 터널만이다.
    /// 짝 맺기는 이 기기의 tailnet 주소를 터널 확장에게서 받아 연결의 이쪽 끝과 견준다. 짝 앱이 VPN을 쥐고 있으면
    /// 같은 노드여도 이 앱은 그 확장에게 주소를 물을 수 없다. 바깥 tailnet VPN(공식 Tailscale 앱 등)은 다른 노드다.
    private var ownTunnelConnected: Bool {
        guard tunnelController.currentState() == .connected else { return false }
        switch tunnelController.vpnHolder {
        case .thisApp: return true
        case .pairedApp, .none, .other: return false
        }
    }

    private var isWaitingApproval: Bool {
        if case .waitingApproval = phase { return true }
        return false
    }

    private var settledPhase: Phase { host == nil ? .unpaired : .paired }

    /// 이 페어링 시도가 아직 유효한지(취소·교체되지 않았는지).
    private func ownsPairing(_ token: UUID) -> Bool {
        pairing?.token == token && !Task.isCancelled
    }

    private func runPairing(_ proposal: PairingProposal, token: UUID) async {
        defer {
            if pairing?.token == token { pairing = nil }
            endApproval(token)
        }
        phase = .requestingPairing
        confirmationCode = nil
        approvalToken = token

        let joined: JoinedHost
        do throws(PairingFailure) {
            joined = try await pairingService.join(proposal, deviceName: PairingDeviceName.sanitized(deviceName)) { [weak self] code in
                Task { @MainActor in self?.receiveConfirmationCode(code, token: token) }
            }
        } catch {
            endApproval(token)
            guard ownsPairing(token) else { return }
            if let message = error.userMessage { failPairing(message) } else { endPairingQuietly() }
            return
        }
        endApproval(token)
        guard ownsPairing(token) else { return }
        // 짝을 맺은 주소는 제안의 주소와 같아야 한다.
        guard joined.host == proposal.host else {
            failPairing(Self.pairedAddressMismatchMessage)
            return
        }
        phase = .requestingPairing
        confirmationCode = nil
        pairingExpiresAt = nil
        log(.info, "pairing", "짝 맺기 승인됨: \(joined.host)")
        await finishPairing(joined, proposal: proposal, token: token)
    }

    /// 이 시도의 확인 숫자 수신을 끝낸다. 그사이 다른 시도가 시작됐으면 그 시도의 토큰은 건드리지 않는다.
    private func endApproval(_ token: UUID) {
        if approvalToken == token { approvalToken = nil }
    }

    /// Mac이 확인된 뒤 받은 확인 숫자를 화면에 올린다.
    private func receiveConfirmationCode(_ code: String, token: UUID) {
        guard approvalToken == token, pairing?.token == token else { return }
        confirmationCode = code
        pairingExpiresAt = clock.now.addingTimeInterval(timing.pairingTimeout)
        phase = .waitingApproval(deviceName: PairingDeviceName.sanitized(deviceName))
        log(.info, "pairing", "Mac의 승인을 기다리는 중")
    }

    /// 짝을 맺은 뒤 `GET /v1/info`로 Mac 정보를 받아 이 iPhone의 페어링 기록(공용 설정)으로 둔다.
    private func finishPairing(_ joined: JoinedHost, proposal: PairingProposal, token: UUID) async {
        guard let api = makeAPI(joined.host) else {
            failPairing(PairingOfferIssue.hostNotAllowed.userMessage)
            return
        }
        var received: InfoResponse?
        for attempt in 0..<Self.pairingInfoAttempts {
            do {
                received = try await api.info()
                break
            } catch {
                guard ownsPairing(token), !(error is CancellationError) else { return }
                if attempt + 1 < Self.pairingInfoAttempts {
                    do { try await clock.sleep(for: timing.pairingInfoRetryInterval) } catch { return }
                    guard ownsPairing(token) else { return }
                }
            }
        }
        guard ownsPairing(token) else { return }
        guard let info = received else {
            failPairing(Self.pairingInfoFailedMessage)
            return
        }
        // 정보를 준 주소는 짝을 맺은 주소와 같아야 한다. 저장하는 주소는 실제로 페어링한 주소다.
        // 테스트 정책의 루프백만 예외다(가짜 호스트의 fqdn은 루프백이 아니다).
        let isLoopbackTest = policy.allowsLoopback && HostPolicy.loopbackHost(joined.host) != nil
        if !isLoopbackTest, HostPolicy.normalizedName(info.fqdn) != joined.host {
            failPairing(Self.pairedAddressMismatchMessage)
            return
        }
        let paired = PairedHost(hostId: info.hostId, hostName: info.hostName, fqdn: joined.host, pairedAt: clock.now,
                                updatePage: PairedHost.validUpdatePage(info.updatePage))
        pairingExpiresAt = nil
        if host?.fqdn != paired.fqdn || host?.hostId != paired.hostId {
            resetHostScopedState()
        }
        host = paired
        phase = .paired
        // 같은 Mac과 다시 짝이 되면 Mac의 기기 항목이 새로 만들어져 알림 등록이 비어 있다. 이번 실행의 확인을 내려 다시 등록한다.
        pushConfirmed = nil
        log(.info, "pairing", "페어링 승인: \(paired.hostName) (\(paired.fqdn))")
        lastApprovedFingerprint = proposal.fingerprint
        do {
            try store.save(paired)
            lastError = nil
        } catch {
            lastError = Self.saveFailedMessage
        }
        await refresh()
    }

    private func failPairing(_ message: String) {
        log(.warning, "pairing", "페어링 실패: \(message)")
        endPairingQuietly()
        lastError = message
    }

    private func endPairingQuietly() {
        pairingExpiresAt = nil
        confirmationCode = nil
        phase = settledPhase
    }

    /// 짝을 맺은 직후 `GET /v1/info`를 묻는 횟수.
    private static let pairingInfoAttempts = 3

    // MARK: 빌드 목록

    public func refresh() async {
        guard let current = host, makeAPI(current.fqdn) != nil else { return }
        let generation = hostGeneration
        let backgroundsAtStart = backgroundCount
        refreshesInFlight += 1
        isRefreshing = true
        defer {
            refreshesInFlight -= 1
            isRefreshing = refreshesInFlight > 0
        }
        // 같은 네트워크면 직접 받는다. 아니면 VPN으로: 꺼져 있고 자동으로 켤 수 있으면 켜고 연결을 기다린다.
        // 그러지 못하면 연결될 때 이어 한다.
        let api: HostAPI
        do {
            let (info, list, used) = try await viaHost(current, tunnel: { [self] in
                await connectedTunnel(queue: .refresh) && generation == hostGeneration
            }) { api -> (InfoResponse, [BuildDescriptor]?, HostAPI) in
                let info = try await api.info()
                // 다른 Mac이거나 규약이 다르면 빌드 목록을 받지 않는다.
                guard info.hostId == current.hostId, info.protocolVersion == 1 else { return (info, nil, api) }
                return (info, try await api.builds(), api)
            }
            api = used
            guard generation == hostGeneration else { return }
            guard info.hostId == current.hostId else {
                failRefresh(Self.hostChangedMessage)
                return
            }
            guard info.protocolVersion == 1, let list else {
                failRefresh(HostAPIError.protocolMismatch("info.protocol").userMessage)
                return
            }
            if builds.map(\.id) != list.map(\.id) {
                log(.info, "builds", "빌드 목록 \(list.count)개: " + list.map { "\($0.displayName) \($0.id) 게시 \(RDTimestamp.string($0.publishedAt))" }.joined(separator: ", "))
            }
            builds = list
            buildsLoadedAt = clock.now
            if let previous = refreshError, lastError == previous { lastError = nil }
            refreshError = nil
            let updatePage = PairedHost.validUpdatePage(info.updatePage)
            if var updated = host, info.hostName != updated.hostName || updatePage != updated.updatePage {
                if updatePage != updated.updatePage { log(.info, "update", "업데이트 페이지: \(updatePage?.absoluteString ?? "없음")") }
                updated.hostName = info.hostName
                updated.updatePage = updatePage
                host = updated
                try? store.save(updated)
            }
        } catch is VPNNotConnected {
            return
        } catch {
            guard !(error is CancellationError), generation == hostGeneration else { return }
            // 백그라운드에서는 iOS가 앱을 멈춰 요청이 끊긴다. 앱으로 돌아오면 다시 받으므로 오류로 올리지 않는다.
            guard !isBackgrounded, backgroundCount == backgroundsAtStart else {
                log(.debug, "builds", "백그라운드에서 끊긴 목록 받기: \(Self.message(for: error))")
                return
            }
            failRefresh(Self.message(for: error))
            return
        }
        await refreshResources(api: api, generation: generation)
        // 목록을 받은 경로로 알림 등록을 맞춘다. 실패해도 화면 오류는 띄우지 않고 다음 새로고침 때 다시 한다.
        await syncPush(host: current, generation: generation)
        await sendLogs()
        await sendCrashes()
    }

    // MARK: 파일

    /// 파일 목록은 빌드 목록과 따로 받는다. 받지 못해도 빌드 목록은 그대로 쓴다.
    private func refreshResources(api: HostAPI, generation: Int) async {
        do {
            let list = try await api.resources()
            guard generation == hostGeneration else { return }
            if resources.map(\.id) != list.map(\.id) {
                log(.info, "files", "파일 목록 \(list.count)개: " + list.map { "\($0.name) \($0.id)" }.joined(separator: ", "))
            }
            resources = list
        } catch let error as HostAPIError where error.code == "not_found" {
            // 파일 보내기를 모르는 이전 Mac 앱.
            if generation == hostGeneration { resources = [] }
        } catch {
            guard !(error is CancellationError) else { return }
            log(.warning, "files", "파일 목록 받기 실패: \(Self.message(for: error))")
        }
        reloadReceivedFiles()
    }

    /// 받아 둔 파일 중 Mac 목록의 같은 내용이 있는지.
    public func isReceived(_ resource: ResourceDescriptor) -> Bool {
        receivedFiles.contains { $0.name == resource.name && $0.size == resource.size && $0.sha256 == resource.sha256.lowercased() }
    }

    /// 파일을 받아 Documents에 저장한다(같은 이름은 바꾼다). 이미 받는 중이면 아무것도 하지 않는다.
    public func download(_ resource: ResourceDescriptor) {
        guard !resource.isLink, downloadTasks[resource.id] == nil, let current = host, makeAPI(current.fqdn) != nil else { return }
        guard direct?.mayReach(current) == true || tunnelUsable() else { return }
        let generation = hostGeneration
        fileDownloads[resource.id] = .downloading
        fileProgress[resource.id] = FileTransferProgress(received: 0, total: resource.size, startedAt: clock.now)
        log(.info, "files", "파일 받기 시작: \(resource.name) \(resource.size)바이트")
        notifyTransfer(resource, .receiving)
        let throttle = ProgressThrottle()
        let report: FileDownloader.Progress = { [weak self] received, expected in
            guard throttle.shouldReport(received, expected) else { return }
            Task { @MainActor in self?.noteProgress(resource, received: received, generation: generation) }
        }
        downloadTasks[resource.id] = Task { [weak self] in
            let result: Result<URL, any Error>
            do {
                guard let self else { throw CancellationError() }
                result = .success(try await self.viaHost(current, tunnel: { await self.connectedForTransfer() }, route: { direct in
                    if direct { self.directDownloads.insert(resource.id) } else { self.directDownloads.remove(resource.id) }
                }) { try await $0.download(resource, progress: report) })
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.directDownloads.remove(resource.id)
            self.downloadTasks[resource.id] = nil
            defer { self.fileProgress[resource.id] = nil }
            guard generation == self.hostGeneration else {
                if case .success(let temp) = result { try? FileManager.default.removeItem(at: temp) }
                return
            }
            switch result {
            case .success(let temp):
                do {
                    try self.receivedStore.save(temp, as: resource)
                    self.fileDownloads[resource.id] = nil
                    self.log(.info, "files", "파일 받음: \(resource.name)")
                    self.notifyTransfer(resource, .received, received: resource.size)
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    let message = String(localized: "iPhone에 저장하지 못했습니다. 저장 공간을 확인하세요.")
                    self.fileDownloads[resource.id] = .failed(message)
                    self.log(.error, "files", "파일 저장 실패: \(resource.name) \(error)")
                    self.notifyTransfer(resource, .failed(message))
                }
                self.reloadReceivedFiles()
            case .failure(let error) where error is CancellationError:
                self.fileDownloads[resource.id] = nil
                self.notifyTransfer(resource, .cancelled)
            case .failure(let error):
                let message = error is VPNNotConnected ? Self.vpnNotConnectedMessage(for: self.tunnel) : Self.message(for: error)
                self.fileDownloads[resource.id] = .failed(message)
                self.log(.warning, "files", "파일 받기 실패: \(resource.name) \(message) [\((error as? HostAPIError)?.message ?? String(describing: error))]")
                self.notifyTransfer(resource, .failed(message))
            }
        }
    }

    /// 앱을 다시 띄운 뒤 iOS가 이어 가던 전송을 넘겨받는다. 진행 중인 파일 id를 돌려준다.
    /// 앱이 시작할 때 한 번 부른다(시험은 부르지 않는다: 실제 백그라운드 세션을 만든다).
    @discardableResult
    public func attachBackgroundTransfers(_ downloader: FileDownloader = .shared) async -> [String] {
        let transfers = await downloader.attach { [weak self] event in
            Task { @MainActor in self?.handleOrphan(event) }
        }
        var active: [String] = []
        for t in transfers {
            guard let resource = Self.resource(from: t.context), downloadTasks[resource.id] == nil else { continue }
            active.append(resource.id)
            fileDownloads[resource.id] = .downloading
            fileProgress[resource.id] = FileTransferProgress(received: t.received, total: resource.size, startedAt: clock.now)
            log(.info, "files", "백그라운드 전송 이어받음: \(resource.name) \(t.received)/\(resource.size)바이트")
            notifyTransfer(resource, .receiving, received: t.received)
        }
        return active
    }

    @ObservationIgnored private var orphanThrottles: [String: ProgressThrottle] = [:]

    private func handleOrphan(_ event: FileDownloader.OrphanEvent) {
        switch event {
        case .progress(_, let context, let received, let expected):
            guard let resource = Self.resource(from: context), downloadTasks[resource.id] == nil else { return }
            let throttle = orphanThrottles[resource.id] ?? ProgressThrottle()
            orphanThrottles[resource.id] = throttle
            guard throttle.shouldReport(received, expected) else { return }
            fileDownloads[resource.id] = .downloading
            fileProgress[resource.id] = FileTransferProgress(received: received, total: resource.size,
                                                             startedAt: fileProgress[resource.id]?.startedAt ?? clock.now)
            notifyTransfer(resource, .receiving, received: received)
        case .finished(_, let context, let result):
            guard let resource = Self.resource(from: context) else {
                if case .success(let (file, _)) = result { try? FileManager.default.removeItem(at: file) }
                return
            }
            orphanThrottles[resource.id] = nil
            fileProgress[resource.id] = nil
            switch result {
            case .success(let (file, response)):
                do {
                    try HostAPI.checkDownloaded(file: file, response: response, resource: resource)
                    try receivedStore.save(file, as: resource)
                    fileDownloads[resource.id] = nil
                    log(.info, "files", "파일 받음(백그라운드): \(resource.name)")
                    notifyTransfer(resource, .received, received: resource.size)
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    let message = Self.message(for: error)
                    fileDownloads[resource.id] = .failed(message)
                    log(.warning, "files", "백그라운드 파일 확인·저장 실패: \(resource.name) \(message)")
                    notifyTransfer(resource, .failed(message))
                }
                reloadReceivedFiles()
            case .failure(let error) where error is CancellationError:
                fileDownloads[resource.id] = nil
                notifyTransfer(resource, .cancelled)
            case .failure(let error):
                let message = HostAPIError.connectionFailed("\(error)").userMessage
                fileDownloads[resource.id] = .failed(message)
                log(.warning, "files", "백그라운드 파일 받기 실패: \(resource.name) \(error)")
                notifyTransfer(resource, .failed(message))
            }
        }
    }

    nonisolated static func resource(from context: Data?) -> ResourceDescriptor? {
        context.flatMap { try? RDJSON.decoder().decode(ResourceDescriptor.self, from: $0) }
    }

    private func noteProgress(_ resource: ResourceDescriptor, received: Int64, generation: Int) {
        guard generation == hostGeneration, fileDownloads[resource.id] == .downloading else { return }
        fileProgress[resource.id] = FileTransferProgress(received: received, total: resource.size, startedAt: fileProgress[resource.id]?.startedAt)
        notifyTransfer(resource, .receiving, received: received)
    }

    private func notifyTransfer(_ resource: ResourceDescriptor, _ phase: FileTransferUpdate.Phase, received: Int64? = nil) {
        let progress = FileTransferProgress(received: received ?? fileProgress[resource.id]?.received ?? 0, total: resource.size)
        onFileTransfer?(FileTransferUpdate(resourceID: resource.id, name: resource.name, progress: progress, phase: phase))
    }

    public func cancelDownload(_ resourceID: String) {
        downloadTasks[resourceID]?.cancel()
    }

    public func deleteReceivedFile(_ name: String) {
        do {
            try receivedStore.delete(name)
        } catch {
            lastError = String(localized: "파일을 지우지 못했습니다.")
        }
        reloadReceivedFiles()
    }

    /// 파일 앱에서 바꾼 내용을 다시 읽는다.
    public func reloadReceivedFiles() {
        receivedFiles = receivedStore.list()
    }

    private func failRefresh(_ message: String) {
        log(.warning, "builds", "목록 받기 실패: \(message)")
        refreshError = message
        lastError = message
    }

    // MARK: 설치

    /// 설치 세션을 만들고 설치 창을 연 뒤 진행을 확인한다. 같은 빌드의 설치가 진행 중이면 아무것도 하지 않는다.
    public func install(_ build: BuildDescriptor) {
        let id = build.id
        guard installTasks[id] == nil else { return }
        guard let current = host, let api = makeAPI(current.fqdn) else { return }
        if let active = activeSessions[id] {
            // 멈춘 확인을 이어 간다(새 세션을 만들지 않는다).
            startSessionPolling(buildID: id, api: api, active: active)
            return
        }
        guard tunnelUsable() else { return }
        log(.info, "install", "설치 요청: \(build.displayName) \(build.version) (\(build.buildNumber)) \(id)")
        installs[id] = .preparing
        let token = UUID()
        let generation = hostGeneration
        installTasks[id] = Running(token: token, task: Task { [weak self] in
            await self?.runInstall(buildID: id, api: api, token: token, generation: generation)
        })
    }

    /// 전송 중인 빌드의 진행. 전송 중이 아니면 `nil`.
    public func installProgress(for buildID: String) -> InstallProgress? {
        installs[buildID]?.progress
    }

    /// 끝난(완료·만료·실패) 설치 상태를 지운다. 진행 중이면 아무것도 하지 않는다.
    public func clearInstall(_ buildID: String) {
        guard installTasks[buildID] == nil, activeSessions[buildID] == nil,
              let state = installs[buildID], !state.isInProgress
        else { return }
        installs[buildID] = nil
    }

    /// 설치 창을 닫았거나 취소했을 때 같은 세션의 설치 창을 다시 연다. iOS 설치기를 기다릴 때만 동작한다.
    /// 호스트는 같은 세션의 매니페스트를 여러 번 내준다(docs/protocol.md 설치 세션).
    public func reopenInstaller(_ buildID: String) async {
        guard installs[buildID] == .waitingForInstaller, let active = activeSessions[buildID] else { return }
        let generation = hostGeneration
        let opened = await opener.open(active.installURL)
        guard generation == hostGeneration else { return }
        if !opened { lastError = Self.reopenFailedMessage }
    }

    /// iOS 설치기를 기다리는 설치를 그만둔다. 진행 확인을 멈추고 상태를 지운다.
    /// Mac의 세션은 그대로 두며 제한 시간이 지나면 만료된다. 다시 설치하면 새 세션을 연다.
    public func cancelInstall(_ buildID: String) {
        guard installs[buildID] == .waitingForInstaller else { return }
        installTasks[buildID]?.task.cancel()
        installTasks[buildID] = nil
        activeSessions[buildID] = nil
        installs[buildID] = nil
    }

    private func runInstall(buildID id: String, api: HostAPI, token: UUID, generation: Int) async {
        defer { finishInstallTask(id, token: token) }
        // 설치 세션을 만들기 전에 VPN이 연결돼 있게 한다(꺼져 있으면 자동으로 켠다).
        guard await connectedForTransfer() else {
            guard generation == hostGeneration, installs[id] == .preparing else { return }
            installs[id] = Task.isCancelled ? nil : .failed(message: Self.vpnNotConnectedMessage(for: tunnel))
            return
        }
        guard generation == hostGeneration else { return }
        let session: SessionResponse
        do {
            session = try await api.createSession(buildID: id)
        } catch {
            guard generation == hostGeneration else { return }
            if Task.isCancelled || error is CancellationError {
                if installs[id] == .preparing { installs[id] = nil }
                return
            }
            installs[id] = Self.installState(for: error, creatingSession: true)
            return
        }
        guard generation == hostGeneration else { return }
        guard !Task.isCancelled else {
            if installs[id] == .preparing { installs[id] = nil }
            return
        }
        guard Self.isTrustedInstallURL(session.installUrl, manifestURL: session.manifestUrl, host: api.host, policy: policy) else {
            installs[id] = .failed(message: Self.untrustedInstallURLMessage)
            return
        }
        log(.info, "install", "세션 \(session.sessionId) 만듦, 설치 창 여는 중: \(id)")
        let opened = await opener.open(session.installUrl)
        // 설치 창을 여는 동안 호스트를 잊었거나 바꿨으면 아무것도 쓰지 않는다.
        guard generation == hostGeneration else { return }
        guard opened else {
            installs[id] = .failed(message: Self.openFailedMessage)
            return
        }
        let active = ActiveSession(sessionID: session.sessionId, installURL: session.installUrl, deadline: clock.now.addingTimeInterval(timing.sessionTimeout))
        activeSessions[id] = active
        installs[id] = .waitingForInstaller
        // 확인이 멈췄으면(stopPolling) 세션을 남겨 두고 resumePolling에서 이어 간다.
        guard !Task.isCancelled else { return }
        await pollSession(buildID: id, api: api, active: active, generation: generation)
    }

    private func startSessionPolling(buildID id: String, api: HostAPI, active: ActiveSession) {
        let token = UUID()
        let generation = hostGeneration
        installTasks[id] = Running(token: token, task: Task { [weak self] in
            guard let self else { return }
            defer { self.finishInstallTask(id, token: token) }
            await self.pollSession(buildID: id, api: api, active: active, generation: generation)
        })
    }

    private func pollSession(buildID id: String, api: HostAPI, active: ActiveSession, generation: Int) async {
        func current() -> Bool { !Task.isCancelled && generation == hostGeneration }
        while true {
            if clock.now >= active.deadline {
                await finishSessionAfterDeadline(buildID: id, api: api, active: active, generation: generation)
                return
            }
            do { try await clock.sleep(for: timing.sessionPollInterval) } catch { return }
            guard current() else { return }
            let status: SessionStatus
            do {
                status = try await api.sessionStatus(sessionID: active.sessionID)
            } catch let error as HostAPIError where error.isConnectionFailure {
                guard current() else { return }
                continue
            } catch {
                guard current(), !(error is CancellationError) else { return }
                conclude(id, Self.installState(for: error, creatingSession: false))
                return
            }
            guard current() else { return }
            if let terminal = Self.terminalState(status.state) {
                log(.info, "install", "세션 \(active.sessionID) \(status.state.rawValue): \(status.bytesServed)/\(status.size)바이트")
                conclude(id, terminal)
                return
            }
            let next = Self.progressState(status)
            if case .transferring = next, installs[id]?.progress == nil {
                log(.info, "install", "전송 시작: 세션 \(active.sessionID) \(status.state.rawValue)")
            }
            installs[id] = next
        }
    }

    /// 로컬 마감이 지나면 호스트에 한 번 더 묻고 끝난 상태(완료·만료·실패)면 그것을 따른다.
    /// 답을 못 받거나 아직 진행 중이면 시간 초과로 끝낸다.
    private func finishSessionAfterDeadline(buildID id: String, api: HostAPI, active: ActiveSession, generation: Int) async {
        let status = try? await api.sessionStatus(sessionID: active.sessionID)
        guard !Task.isCancelled, generation == hostGeneration else { return }
        if let status, let terminal = Self.terminalState(status.state) {
            conclude(id, terminal)
        } else {
            conclude(id, .failed(message: Self.installTimeoutMessage))
        }
    }

    nonisolated private static func terminalState(_ state: SessionState) -> InstallState? {
        switch state {
        case .completed: .completed
        case .expired: .expired
        case .failed: .failed(message: sessionFailedMessage)
        case .created, .manifestServed, .downloading: nil
        }
    }

    /// iOS는 설치 창에 앱 이름을 보여 주려고 매니페스트를 먼저 받는다(`manifest_served`). 사용자가 창을 닫거나 취소하면
    /// 세션은 거기서 멈추므로, IPA 전송(`downloading`)이 시작되기 전까지는 설치 창을 기다리는 상태로 둔다.
    /// 그래야 ‘다시 열기’와 ‘취소’가 마감까지 남는다.
    nonisolated private static func progressState(_ status: SessionStatus) -> InstallState {
        switch status.state {
        case .created, .manifestServed: .waitingForInstaller
        default: .transferring(bytesServed: status.bytesServed, size: status.size)
        }
    }

    nonisolated private static func installState(for error: any Error, creatingSession: Bool) -> InstallState {
        if let api = error as? HostAPIError {
            if api.code == "session_expired" { return .expired }
            if creatingSession, api.code == HostAPIError.timedOutCode {
                return .failed(message: createSessionTimeoutMessage)
            }
        }
        return .failed(message: message(for: error))
    }

    private func conclude(_ id: String, _ state: InstallState) {
        switch state {
        case .completed: log(.info, "install", "전송 완료: \(id)")
        case .expired: log(.warning, "install", "세션 만료: \(id)")
        case .failed(let message): log(.error, "install", "설치 실패: \(id): \(message)")
        default: break
        }
        installs[id] = state
        activeSessions[id] = nil
    }

    private func finishInstallTask(_ id: String, token: UUID) {
        if installTasks[id]?.token == token { installTasks[id] = nil }
    }

    /// 호스트가 만드는 설치 주소(sessions.go)와 정확히 같은 꼴인지 확인한다.
    ///
    /// - `itms-services://?action=download-manifest&url=<매니페스트>`: authority·경로·조각이 없고, 쿼리는 `action`과 `url` 하나씩뿐.
    /// - 매니페스트: `https`, 사용자 정보 없음, 포트 없음 또는 443, 쿼리·조각 없음, 호스트가 페어링한 주소와 같음,
    ///   경로가 `/i/<43자 base64url 토큰>/manifest.plist`, 같은 응답의 `manifestUrl`과 같음.
    /// - 테스트 정책(`allowsLoopback`)은 루프백 호스트에 한해 `http`와 다른 포트를 허용한다.
    nonisolated static func isTrustedInstallURL(_ url: URL, manifestURL: URL?, host: String, policy: HostPolicy) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme == "itms-services",
              comps.percentEncodedHost?.isEmpty ?? true,
              comps.user == nil, comps.password == nil, comps.port == nil,
              comps.percentEncodedPath.isEmpty,
              comps.fragment == nil,
              let items = comps.queryItems, items.count == 2,
              items.filter({ $0.name == "action" }).count == 1,
              items.filter({ $0.name == "url" }).count == 1,
              items.first(where: { $0.name == "action" })?.value == "download-manifest",
              let manifestText = items.first(where: { $0.name == "url" })?.value,
              let manifest = URLComponents(string: manifestText),
              manifest.user == nil, manifest.password == nil,
              manifest.query == nil, manifest.fragment == nil,
              let manifestHost = manifest.percentEncodedHost?.lowercased(),
              manifestHost == host
        else { return false }

        let loopbackTest = policy.allowsLoopback && HostPolicy.loopbackHost(host) != nil
        if loopbackTest {
            guard manifest.scheme == "https" || manifest.scheme == "http" else { return false }
        } else {
            guard manifest.scheme == "https", manifest.port == nil || manifest.port == 443 else { return false }
        }
        guard isManifestPath(manifest.percentEncodedPath) else { return false }
        if let manifestURL, manifestURL.absoluteString != manifestText { return false }
        return true
    }

    nonisolated private static func isManifestPath(_ path: String) -> Bool {
        let prefix = "/i/", suffix = "/manifest.plist"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return false }
        let token = path.dropFirst(prefix.count).dropLast(suffix.count)
        return token.count == 43 && token.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    // MARK: 폴링 중단·재개

    /// 진행 확인(설치 진행)을 멈추고 진행 중인 짝 맺기를 그만둔다. 앱이 백그라운드로 가거나 화면이 사라질 때 부른다.
    /// 설치 상태는 그대로 두고 `resumePolling()`으로 이어 간다. 짝 맺기는 연결과 1회용 제안이 걸려 있어 이어 갈 수 없다.
    public func stopPolling() {
        isBackgrounded = true
        backgroundCount += 1
        // 진행 중인 짝 맺기뿐 아니라 VPN을 기다리는 제안도 그만둔다(1회용 비밀이라 쥐고 있지 않는다).
        if pairing != nil || queuedPairing != nil {
            cancelPairing()
            lastError = Self.pairingInterruptedMessage
        }
        for running in installTasks.values { running.task.cancel() }
        installTasks = [:]
        resumeTask?.cancel()
        resumeTask = nil
    }

    /// 멈춘 설치 진행 확인을 다시 시작한다.
    public func resumePolling() {
        // 앱이 다시 활성이 됐다. 네트워크가 바뀌었을 수 있으니 직접 경로를 다시 찾는다.
        noteNetworkChange()
        isBackgrounded = false
        if let current = host, let api = makeAPI(current.fqdn) {
            for (id, active) in activeSessions where installTasks[id] == nil {
                startSessionPolling(buildID: id, api: api, active: active)
            }
        }
    }

    // MARK: 호스트 잊기

    /// 페어링한 Mac을 잊고 VPN을 끈다.
    public func forgetHost() async {
        await forgetPushRegistration()
        stopPolling()
        cancelPairing()
        pendingConfirmation = nil
        refreshQueued = false
        lastApprovedFingerprint = nil
        resetHostScopedState()
        store.clear()
        direct?.forget()
        isDirectConnected = false
        host = nil
        phase = .unpaired
        needsTunnel = false
        lastError = nil
        vpnAutoStarted = false
        await tunnelController.disconnect()
        tunnel = tunnelController.currentState()
    }

    private func resetHostScopedState() {
        hostGeneration &+= 1
        for running in installTasks.values { running.task.cancel() }
        installTasks = [:]
        activeSessions = [:]
        installs = [:]
        for task in downloadTasks.values { task.cancel() }
        downloadTasks = [:]
        fileDownloads = [:]
        fileProgress = [:]
        resources = []
        agentBoard = nil
        agentError = nil
        builds = []
        buildsLoadedAt = nil
        refreshError = nil
        resumeTask?.cancel()
        resumeTask = nil
    }

    // MARK: 경로 선택 (docs/protocol-addenda.md O)

    /// 네트워크 경로가 바뀌었다(Wi-Fi ↔ 셀룰러, 다른 Wi-Fi). 다음 요청에서 직접 경로를 다시 찾는다.
    public func noteNetworkChange() {
        guard let direct else { return }
        direct.invalidate()
        isDirectConnected = false
    }

    /// 직접 경로가 있거나 VPN이 연결돼 있다(꺼져 있으면 자동으로 켠다).
    private func reachable(_ current: PairedHost) async -> Bool {
        if await direct?.api(for: current, client: client, timeouts: timing.requestTimeouts) != nil {
            isDirectConnected = true
            return true
        }
        isDirectConnected = false
        return await connectedForTransfer()
    }

    /// `work`를 Mac에 보낸다. 같은 네트워크면 직접 경로로 보내고, 연결 오류면 한 번 다시 찾아 보낸 뒤
    /// VPN(tailnet) 경로로 넘어간다. 직접 경로가 토큰을 거절하면 VPN 경로로 보내고 다시 등록한다.
    /// VPN 경로는 `ensure`가 `true`일 때만 쓴다(아니면 `VPNNotConnected`).
    /// 설치는 이 함수를 거치지 않는다: 설치 주소는 tailnet 이름이어야 iOS가 받는다.
    private func viaHost<T>(
        _ current: PairedHost,
        tunnel ensure: () async -> Bool,
        route: (Bool) -> Void = { _ in },
        _ work: (HostAPI) async throws -> T
    ) async throws -> T {
        if let direct {
            for attempt in 0..<2 {
                guard let api = await direct.api(for: current, client: client, timeouts: timing.requestTimeouts) else { break }
                if !isDirectConnected { log(.info, "direct", "같은 네트워크의 Mac에 직접 연결") }
                isDirectConnected = true
                route(true)
                do {
                    return try await work(api)
                } catch let error as HostAPIError where error.isConnectionFailure {
                    log(.info, "direct", "직접 연결 실패(\(error.code)), \(attempt == 0 ? "다시 찾음" : "VPN 경로로 넘어감")")
                    direct.connectionFailed(final: attempt == 1)
                } catch let error as HostAPIError where error.code == "not_paired" || error.code == "too_many_attempts" {
                    log(.info, "direct", "직접 연결 토큰을 Mac이 받지 않음(\(error.code)), VPN 경로로 다시 등록")
                    direct.rejected()
                    break
                }
            }
            isDirectConnected = false
        }
        route(false)
        guard await ensure(), let api = makeAPI(current.fqdn) else { throw VPNNotConnected() }
        let result = try await work(api)
        // VPN 경로가 살아 있을 때 직접 연결 등록을 해 둔다(같은 Wi-Fi에 오면 VPN 없이 쓴다).
        if let direct, host?.hostId == current.hostId { await direct.enrollIfNeeded(using: api, host: current) }
        return result
    }

    // MARK: VPN

    /// VPN 구성을 확인(`prepare`)한 뒤 VPN을 켠다.
    public func connectTunnel() async {
        guard !Task.isCancelled else { return }
        vpnAutoStarted = false
        do {
            try await tunnelController.prepare()
        } catch {
            guard !(error is CancellationError) else { return }
            tunnel = tunnelController.currentState()
            lastError = Self.tunnelPrepareFailedMessage
            return
        }
        // 구성을 저장하는 동안 이 동작이 취소됐으면 VPN을 켜지 않는다.
        guard !Task.isCancelled else { return }
        do {
            try await tunnelController.connect()
        } catch {
            guard !(error is CancellationError) else { return }
            tunnel = tunnelController.currentState()
            lastError = Self.tunnelConnectFailedMessage
            return
        }
        tunnelDidChange(tunnelController.currentState())
    }

    public func disconnectTunnel() async {
        vpnAutoStarted = false
        await tunnelController.disconnect()
        tunnel = tunnelController.currentState()
    }

    /// 사용자가 모델을 거치지 않고 VPN을 켜거나 껐다(이 앱으로 넘겨받기, 짝 앱의 요청).
    /// 그 VPN은 자동으로 켠 것이 아니므로 자동으로 끄지 않는다.
    public func noteManualVPNChange() {
        vpnAutoStarted = false
    }

    /// 모델을 거치지 않고 켠 이 앱의 VPN을 자동으로 켠 것으로 본다(어느 VPN도 꺼져 있을 때 설치 때문에 켠 경우).
    /// Mac이 필요한 일이 없어지면 자동으로 켠 VPN과 같은 규칙으로 끈다.
    public func noteAutoStartedVPN() {
        vpnAutoStarted = true
        startIdleWatch()
    }

    // MARK: VPN 자동 켜기·끄기 (docs/protocol-addenda.md N)

    /// 같은 네트워크에서 직접 닿을 수 있거나, VPN이 연결돼 있거나, 꺼져 있어도 Mac이 필요할 때 자동으로 켤 수 있다.
    public var canReachHost: Bool {
        if let host, direct?.mayReach(host) == true { return true }
        let state = tunnelController.currentState()
        return state == .connected || autoStartTask != nil || autoStartDecision(state) == .start
    }

    private func autoStartDecision(_ state: TunnelState) -> AutoVPNPolicy.Start {
        AutoVPNPolicy.start(state: state, holder: tunnelController.vpnHolder, configuration: tunnelController.autoStartConfiguration)
    }

    /// VPN이 연결돼 있으면 `true`. 꺼져 있고 자동으로 켤 수 있으면 켜고, 연결되거나 실패할 때까지 기다린다.
    /// 이미 자동으로 켜는 중이면 그 결과를 함께 기다린다.
    private func autoStartTunnel() async -> Bool {
        let state = tunnelController.currentState()
        if state == .connected { return true }
        if let running = autoStartTask { return await running.value }
        guard autoStartDecision(state) == .start else { return false }
        let task = Task { [weak self] in await self?.performAutoStart() ?? false }
        autoStartTask = task
        return await task.value
    }

    private func performAutoStart() async -> Bool {
        isAutoStartingVPN = true
        defer {
            isAutoStartingVPN = false
            autoStartTask = nil
        }
        if let message = lastError, Self.tunnelMessages.contains(message) { lastError = nil }
        log(.info, "vpn", "Mac 연결이 필요해 VPN을 자동으로 켬")
        do {
            try await tunnelController.connectAutomatically()
        } catch {
            log(.warning, "vpn", "VPN 자동 켜기 실패: \(error.localizedDescription)")
            tunnel = tunnelController.currentState()
            return false
        }
        idle.noteNeed()
        let connected = await waitForAutoStart()
        // 켠 직후에는 iOS가 아직 상태를 알려 주지 않아 누가 켰는지 알 수 없다. 기다린 뒤에 본다.
        // 그사이 다른 앱의 VPN이 켜졌으면 그것을 쓴다. 그 VPN은 끄지 않는다.
        vpnAutoStarted = tunnelController.vpnHolder == .thisApp
        if vpnAutoStarted { startIdleWatch() }
        if !connected { log(.warning, "vpn", "자동으로 켠 VPN이 연결되지 않음: \(tunnelController.currentState().logText)") }
        // 연결됐으면 VPN을 기다리던 페어링·새로고침을 이어 간다.
        tunnelDidChange(tunnelController.currentState())
        return connected
    }

    /// 자동으로 켠 VPN이 연결될 때까지 기다린다. 로그인이 필요하거나 오류면 바로 `false`.
    private func waitForAutoStart() async -> Bool {
        let interval = timing.autoStartPollInterval
        let step = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        let steps = max(1, Int((timing.autoStartTimeout / max(step, 0.001)).rounded(.up)))
        // 켜기를 부른 직후에는 iOS가 아직 꺼짐으로 알려 줄 수 있다. 잠깐은 꺼짐도 기다린다.
        let offGrace = max(1, Int((3 / max(step, 0.001)).rounded(.up)))
        var sawActive = false
        for index in 0..<steps {
            switch tunnelController.currentState() {
            case .connected: return true
            case .needsLogin, .failed: return false
            case .off:
                if sawActive || index >= offGrace { return false }
            case .connecting, .disconnecting:
                sawActive = true
            }
            do { try await clock.sleep(for: interval) } catch { return false }
        }
        return tunnelController.currentState() == .connected
    }

    /// VPN을 기다리게 된 페어링을 위해 VPN을 자동으로 켠다. 켤 수 없으면 아무것도 하지 않는다.
    /// 돌려주는 작업은 페어링을 그만두면 취소된다.
    private func autoStartForQueuedWork() -> Task<Void, Never>? {
        guard autoStartTask != nil || autoStartDecision(tunnelController.currentState()) == .start else { return nil }
        return Task { [weak self] in
            guard let self, !(await self.autoStartTunnel()) else { return }
            if self.queuedPairing != nil || self.refreshQueued { self.lastError = Self.tunnelMessage(for: self.tunnel) }
        }
    }

    /// 설치·파일 받기를 시작해도 되는가. VPN이 연결돼 있거나 자동으로 켤 수 있으면 `true`,
    /// 아니면 VPN 안내를 띄운다. 실제 연결은 작업 안에서 `connectedForTransfer()`가 기다린다.
    private func tunnelUsable() -> Bool {
        let state = tunnelController.currentState()
        if state != .connected, autoStartTask != nil || autoStartDecision(state) == .start {
            idle.noteNeed()
            return true
        }
        return ensureTunnel(queue: nil)
    }

    /// 설치·파일 받기·보내기 바로 앞에서 VPN 연결을 확인한다. 안내 문구는 바꾸지 않는다.
    private func connectedForTransfer() async -> Bool {
        let connected = await autoStartTunnel()
        tunnel = tunnelController.currentState()
        if connected { idle.noteNeed() }
        return connected
    }

    /// 새로고침처럼 VPN이 연결되면 이어 할 수 있는 동작. 자동으로 켜지 못했으면 `ensureTunnel`과 같이 안내하고 기억한다.
    private func connectedTunnel(queue action: Deferred?) async -> Bool {
        if tunnelController.currentState() != .connected { _ = await autoStartTunnel() }
        return ensureTunnel(queue: action)
    }

    /// Mac이 필요한 일이 남았는가. 남아 있으면 자동으로 켠 VPN을 끄지 않는다.
    private var hasVPNNeed: Bool {
        autoStartTask != nil || refreshesInFlight > 0 || isSendingLogs || isSendingCrashes
            || !installTasks.isEmpty || !activeSessions.isEmpty || installs.values.contains(where: \.isInProgress)
            || downloadTasks.keys.contains { !directDownloads.contains($0) }
            || fileDownloads.contains { $0.value == .downloading && !directDownloads.contains($0.key) }
            || pairing != nil || queuedPairing != nil
    }

    /// 자동으로 켠 VPN을 쓸 일이 없어졌는지 주기적으로 본다. 다시 부르면 새로 센다.
    private func startIdleWatch() {
        idleTask?.cancel()
        idle = AutoVPNIdle()
        let clock = clock
        let interval = timing.autoOffCheckInterval
        let token = UUID()
        idleToken = token
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self, self.idleToken == token, await self.idleTick() else { return }
            }
        }
    }

    /// 계속 지켜봐야 하면 `true`.
    private func idleTick() async -> Bool {
        let action = idle.check(now: clock.now, autoStarted: vpnAutoStarted, holder: tunnelController.vpnHolder,
                                state: tunnelController.currentState(), hasNeed: hasVPNNeed, delay: timing.autoOffDelay)
        switch action {
        case .keep:
            return true
        case .forget:
            vpnAutoStarted = false
            return false
        case .turnOff:
            log(.info, "vpn", "자동으로 켠 VPN을 \(Int(timing.autoOffDelay))초 동안 쓰지 않아 끔")
            vpnAutoStarted = false
            await tunnelController.disconnect()
            tunnel = tunnelController.currentState()
            return false
        }
    }

    private func tunnelDidChange(_ state: TunnelState) {
        if state != tunnel { log(state.isFailure ? .warning : .info, "vpn", "VPN 상태: \(state.logText)") }
        tunnel = state
        guard state == .connected else { return }
        guard needsTunnel || queuedPairing != nil || refreshQueued else { return }
        // 앱이 화면에 없는 동안 연결된 것으로는 1회용 제안을 보내지 않는다.
        if queuedPairing != nil, isBackgrounded {
            cancelPairing()
            lastError = Self.pairingInterruptedMessage
        }
        // 앱용 페어링은 이 앱의 터널이 연결됐을 때만 이어 간다. 바깥 VPN만 연결돼 있으면 그대로 기다린다.
        let waitsForOwnTunnel = queuedPairing != nil && !ownTunnelConnected
        needsTunnel = waitsForOwnTunnel
        if let message = lastError, Self.tunnelMessages.contains(message) { lastError = nil }
        if waitsForOwnTunnel { lastError = Self.pairingNeedsOwnTunnelMessage }
        var queued: PairingProposal?
        if !waitsForOwnTunnel {
            queued = queuedPairing
            queuedPairing = nil
        }
        let runRefresh = refreshQueued
        refreshQueued = false
        if let queued { startPairing(queued) }
        if runRefresh {
            resumeTask?.cancel()
            resumeTask = Task { [weak self] in
                await self?.refresh()
                self?.resumeTask = nil
            }
        }
    }

    private enum Deferred { case refresh }

    /// VPN이 연결돼 있으면 `true`. 아니면 안내를 띄우고, 연결되면 이어 할 동작을 기억한다.
    /// 앱용 페어링은 `startPairing`이 따로 기억한다.
    private func ensureTunnel(queue action: Deferred?) -> Bool {
        tunnel = tunnelController.currentState()
        if tunnel == .connected {
            needsTunnel = false
            idle.noteNeed()
            return true
        }
        needsTunnel = true
        switch action {
        case .refresh: refreshQueued = true
        case nil: break
        }
        lastError = Self.tunnelMessage(for: tunnel)
        return false
    }

    // MARK: 로그

    /// 쌓인 로그를 페어링한 Mac에 보낸다. 목록을 받은 뒤에도 자동으로 부른다.
    /// VPN이 꺼져 있으면 자동으로 켤 수 있을 때만 켜서 보낸다. 보내지 못하면 로그를 남겨 두고 다음에 다시 보낸다.
    public func sendLogs() async {
        guard !isSendingLogs, let current = host, makeAPI(current.fqdn) != nil, canReachHost else { return }
        isSendingLogs = true
        defer { isSendingLogs = false }
        guard await reachable(current) else { return }
        let generation = hostGeneration
        while generation == hostGeneration {
            let batch = logBook.nextBatch()
            if batch.isEmpty {
                logsSentAt = clock.now
                logSendError = nil
                return
            }
            do {
                _ = try await viaHost(current, tunnel: { [self] in await connectedForTransfer() }) { try await $0.sendLogs(batch) }
            } catch {
                guard !(error is CancellationError), !(error is VPNNotConnected) else { return }
                logSendError = Self.message(for: error)
                return
            }
            logBook.markSent(batch)
        }
    }

    /// 크래시 기록을 모으고 Mac에 보낸다. 이미 있는 기록이면 아무것도 하지 않는다.
    public func addCrash(_ report: CrashReport) async {
        guard report.text.utf8.count <= CrashReport.maxTextBytes else {
            log(.warning, "crash", "크래시 기록이 너무 커서 받지 않음: \(report.name) \(report.text.utf8.count)바이트")
            return
        }
        guard let item = crashBook.add(report) else { return }
        log(report.kind == .feedback ? .info : .error, "crash", "\(report.kind.label) 기록 \(item.id): \(report.name), \(report.bundleId) \(report.appVersion), \(report.crashedAt.formatted(Date.ISO8601FormatStyle()))")
        await sendCrashes()
    }

    /// 아직 보내지 않은 크래시 기록을 페어링한 Mac에 보낸다. 보내지 못하면 남겨 두고 다음에 다시 보낸다.
    public func sendCrashes() async {
        guard !isSendingCrashes, !crashBook.unsent.isEmpty, let current = host, makeAPI(current.fqdn) != nil,
              canReachHost
        else { return }
        isSendingCrashes = true
        defer { isSendingCrashes = false }
        guard await reachable(current) else { return }
        let generation = hostGeneration
        for item in crashBook.unsent where generation == hostGeneration {
            guard let report = crashBook.report(item) else { continue }
            do {
                try await viaHost(current, tunnel: { [self] in await connectedForTransfer() }) { try await $0.sendCrash(report) }
            } catch {
                guard !(error is CancellationError), !(error is VPNNotConnected) else { return }
                crashSendError = Self.message(for: error)
                return
            }
            crashBook.markSent(item.id)
        }
        crashSendError = nil
    }

    /// 로그 한 줄을 남긴다. 앱 수준 일(시작, 화면 전환)도 이것으로 남긴다.
    public func log(_ level: DeviceLogEntry.Level, _ source: String, _ message: String) {
        logBook.log(level, source, message)
    }

    // MARK: 새 빌드·파일 알림 (docs/protocol-addenda.md P)

    /// 이 앱이 알림 등록을 쓰는가(업데이트 앱은 `false`).
    public var isPushAvailable: Bool { push != nil }

    /// 설정 화면에 보이는 등록 상태.
    public var pushStatus: PushStatus {
        guard push != nil, pushEnabled else { return .off }
        guard let host else { return .pending }
        if pushUnsupportedHosts.contains(host.hostId) { return .unsupported }
        if let record = pushRecord, record.hostId == host.hostId, pushToken.map(record.matches(token:)) ?? true { return .registered }
        return .pending
    }

    /// 알림 스위치를 바꾼다. 권한은 앱이 먼저 받는다. 지금 닿는 경로(직접 연결·연결된 VPN)가 있으면 바로 Mac에 맞추고,
    /// 없으면 다음 새로고침 때 한다(이것만을 위해 VPN을 켜지 않는다).
    public func setPushEnabled(_ enabled: Bool) async {
        guard let push else { return }
        if enabled != pushEnabled { log(.info, "push", "새 빌드·파일 알림 \(enabled ? "켬" : "끔")") }
        push.store.enabled = enabled
        pushEnabled = enabled
        await syncPushIfReachable()
    }

    /// iOS가 준 기기 토큰(16진수). 바뀌었으면 지금 닿는 경로로 등록하고, 없으면 다음 새로고침 때 한다.
    public func receivePushToken(_ token: String) async {
        guard push != nil else { return }
        let normalized = token.lowercased()
        guard normalized != pushToken else { return }
        pushToken = normalized
        log(.info, "push", "기기 토큰 받음: \(normalized.pushTokenPrefix)")
        await syncPushIfReachable()
    }

    /// 알림을 눌러 앱이 열렸다. 갈 탭은 앱이 정하고, 모델은 목록을 새로 받는다(VPN 자동 켜기 규칙을 그대로 따른다).
    /// 목록을 새로 받고, 동작 버튼을 눌렀으면 그 항목을 찾아 돌려준다. 설치·열기는 화면 쪽이 한다.
    /// 그 사이 항목이 목록에서 빠졌으면 `.none`(목록만 보인다).
    @discardableResult
    public func openNotification(_ open: PushOpen) async -> PushFollowUp {
        log(.info, "push", "알림 열림: \(open.target) \(open.action)")
        await refresh()
        guard open.action != .show, let id = open.id else { return .none }
        let followUp: PushFollowUp = switch open.action {
        case .show: .none
        case .install: builds.first { $0.id == id }.map(PushFollowUp.install) ?? .none
        case .openLink: resources.first { $0.id == id }.flatMap(\.link).flatMap(URL.init(string:)).map(PushFollowUp.openLink) ?? .none
        case .download: resources.first { $0.id == id && !$0.isLink }.map(PushFollowUp.download) ?? .none
        }
        if followUp == .none { log(.warning, "push", "알림의 항목이 목록에 없음: \(id)") }
        return followUp
    }

    private func pushAction(for current: PairedHost) -> PushRegistrationPolicy.Action {
        guard let push else { return .none }
        return PushRegistrationPolicy.action(
            enabled: pushEnabled, token: pushToken, bundleId: push.bundleId, hostId: current.hostId,
            record: pushRecord, pendingRemoval: push.store.pendingRemoval,
            confirmedThisRun: pushConfirmed != nil && pushConfirmed == pushRecord,
            unsupported: pushUnsupportedHosts.contains(current.hostId))
    }

    /// 기록을 바꾼다. `nil`이면 지울 Mac 표시도 함께 지운다(Mac이 지웠음을 확인했거나 지울 수 없다).
    private func setPushRecord(_ record: PushRecord?) {
        push?.store.record = record
        pushRecord = record
        if record == nil {
            pushConfirmed = nil
            push?.store.pendingRemoval = nil
        }
    }

    /// 요청을 VPN을 켜지 않고 지금 닿는 경로로 보낸다. 다른 요청과 같이 직접 연결이 먼저고, 연결 오류나 토큰 거절이면
    /// 이미 연결된 VPN으로 넘어간다. 닿지 않으면 `VPNNotConnected`.
    private func viaReachable<T>(_ current: PairedHost, _ work: (HostAPI) async throws -> T) async throws -> T {
        try await viaHost(current, tunnel: { [self] in tunnelController.currentState() == .connected }, work)
    }

    private func syncPushIfReachable() async {
        guard push != nil, let current = host, pushAction(for: current) != .none else { return }
        await syncPush(host: current, generation: hostGeneration)
    }

    /// 판단(`PushRegistrationPolicy`)대로 등록하거나 지운다. 하는 사이 값이 바뀌었으면 한 번 더 맞춘다.
    /// Mac에 닿지 않으면 네트워크가 필요 없는 일만 하고 나머지는 다음 새로고침으로 미룬다.
    private func syncPush(host current: PairedHost, generation: Int) async {
        guard push != nil, !isSyncingPush, !isForgettingPush else { return }
        isSyncingPush = true
        defer {
            isSyncingPush = false
            let waiters = pushSyncWaiters
            pushSyncWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        for _ in 0..<3 {
            guard generation == hostGeneration, !isForgettingPush else { return }
            switch pushAction(for: current) {
            case .none:
                return
            case .forget:
                setPushRecord(nil)
                return
            case .register(let record):
                // 판단은 지금 토큰으로 했다(기록에는 해시만 있다).
                guard let token = pushToken else { return }
                // 응답을 잃어도 Mac에는 등록됐을 수 있다. 끄면 Mac이 지웠다고 확인할 때까지 지우기를 보낸다.
                push?.store.pendingRemoval = current.hostId
                let api: HostAPI
                do {
                    api = try await viaReachable(current) { api in
                        try await api.registerPushToken(token: token, bundleId: record.bundleId)
                        return api
                    }
                } catch is VPNNotConnected {
                    log(.info, "push", "Mac에 닿지 않아 알림 등록을 다음 연결로 미룸")
                    return
                } catch let error as HostAPIError where error.code == "not_found" {
                    guard generation == hostGeneration else { return }
                    pushUnsupportedHosts.insert(current.hostId)
                    log(.info, "push", "이 Mac은 알림 등록을 지원하지 않음")
                    return
                } catch {
                    guard !(error is CancellationError) else { return }
                    log(.warning, "push", "알림 등록 실패(다음 새로고침 때 다시 시도): \(Self.message(for: error))")
                    return
                }
                guard generation == hostGeneration else { return }
                setPushRecord(record)
                pushConfirmed = record
                log(.info, "push", "알림 등록: 토큰 \(token.pushTokenPrefix) \(api.isDirect ? "직접 연결" : "VPN")")
            case .remove:
                // 응답을 잃어도 Mac은 지웠을 수 있다. 다시 켜면 반드시 다시 등록하도록 확인 표시를 먼저 내린다.
                pushConfirmed = nil
                do {
                    try await viaReachable(current) { try await $0.removePushToken() }
                } catch is VPNNotConnected {
                    log(.info, "push", "Mac에 닿지 않아 알림 등록 지우기를 다음 연결로 미룸")
                    return
                } catch let error as HostAPIError where error.code == "not_found" {
                    // 알림 등록을 모르는 Mac에는 지울 것이 없다.
                } catch {
                    guard !(error is CancellationError) else { return }
                    log(.warning, "push", "알림 등록 지우기 실패(다음 새로고침 때 다시 시도): \(Self.message(for: error))")
                    return
                }
                guard generation == hostGeneration else { return }
                setPushRecord(nil)
                log(.info, "push", "Mac에서 알림 등록을 지움")
            }
        }
    }

    /// Mac을 잊기 전에: 닿는 경로(직접 연결, 실패하면 이미 연결된 VPN)가 있으면 Mac에서 토큰을 지우고, 어느 쪽이든 기록을 비운다.
    /// 실패해도 잊기는 막지 않는다. 잊은 뒤에는 그 Mac과 인증이 끊겨 다시 시도할 수 없지만,
    /// Mac에서 페어링을 해제하면 코어가 기기 항목과 함께 토큰을 지운다.
    private func forgetPushRegistration() async {
        guard let push else { return }
        // 가고 있는 등록이 삭제보다 늦게 도착하면 Mac에 토큰이 남는다. 등록이 끝난 뒤에 지운다.
        isForgettingPush = true
        defer { isForgettingPush = false }
        if isSyncingPush {
            await withCheckedContinuation { pushSyncWaiters.append($0) }
        }
        if let current = host,
           pushRecord?.hostId == current.hostId || push.store.pendingRemoval == current.hostId,
           !pushUnsupportedHosts.contains(current.hostId) {
            do {
                try await viaReachable(current) { try await $0.removePushToken() }
                log(.info, "push", "Mac을 잊기 전에 알림 등록을 지움")
            } catch is VPNNotConnected {
                log(.info, "push", "Mac에 닿지 않아 잊기 전에 알림 등록을 지우지 못함")
            } catch {
                log(.info, "push", "Mac을 잊기 전에 알림 등록을 지우지 못함: \(Self.message(for: error))")
            }
        }
        setPushRecord(nil)
    }

    // MARK: 에이전트 요청

    public static let agentUnsupportedMessage = String(localized: "Mac의 RemoteDebug 앱이 에이전트 요청을 지원하지 않습니다. Mac 앱을 업데이트하세요.")

    /// Mac의 에이전트 상태(받는지, 프로젝트, 최근 요청)를 다시 받는다. VPN이 연결돼 있을 때만 한다.
    public func refreshAgent() async {
        guard let current = host, tunnel == .connected, let api = makeAPI(current.fqdn) else { return }
        let generation = hostGeneration
        do {
            let board = try await api.agentBoard()
            guard generation == hostGeneration else { return }
            agentBoard = board
            agentError = nil
        } catch let error as HostAPIError where error.code == "not_found" {
            guard generation == hostGeneration else { return }
            agentBoard = nil
            agentError = Self.agentUnsupportedMessage
        } catch {
            guard !(error is CancellationError), generation == hostGeneration else { return }
            agentError = Self.message(for: error)
        }
    }

    /// 요청을 Mac의 에이전트에 보낸다. 실패하면 안내 문구를 돌려준다.
    public func sendAgentRequest(_ submission: AgentSubmission) async -> String? {
        guard let current = host, let api = makeAPI(current.fqdn) else { return String(localized: "페어링한 Mac이 없습니다.") }
        guard tunnel == .connected else { return String(localized: "VPN을 켠 뒤 다시 보내세요.") }
        do {
            let id = try await api.submitAgentRequest(submission)
            log(.info, "agent", "에이전트 요청 \(id) 보냄")
        } catch let error as HostAPIError where error.code == "agent_disabled" {
            return String(localized: "Mac이 iPhone의 요청을 받지 않습니다. Mac 앱의 에이전트 화면에서 켜세요.")
        } catch let error as HostAPIError where error.code == "not_found" {
            return Self.agentUnsupportedMessage
        } catch {
            log(.warning, "agent", "에이전트 요청 실패: \(Self.message(for: error))")
            return Self.message(for: error)
        }
        await refreshAgent()
        return nil
    }

    public func cancelAgentRequest(_ id: String) async {
        guard let current = host, tunnel == .connected, let api = makeAPI(current.fqdn) else { return }
        do {
            try await api.cancelAgentRequest(id: id)
        } catch {
            guard !(error is CancellationError) else { return }
            agentError = Self.message(for: error)
        }
        await refreshAgent()
    }

    // MARK: 도움

    private func makeAPI(_ host: String) -> HostAPI? {
        HostAPI(host: host, policy: policy, transport: transport, client: client, timeouts: timing.requestTimeouts)
    }

    nonisolated static func message(for error: any Error) -> String {
        (error as? HostAPIError)?.userMessage ?? HostAPIError.invalidResponse(status: 0, "").userMessage
    }

    /// 테스트용: 모델이 띄운 작업이 모두 끝날 때까지 기다린다.
    func waitForBackgroundWork() async {
        while true {
            if let autoStartTask {
                _ = await autoStartTask.value
                await Task.yield()
                continue
            }
            var tasks: [Task<Void, Never>] = installTasks.values.map(\.task) + Array(downloadTasks.values)
            if let pairing { tasks.append(pairing.task) }
            if let resumeTask { tasks.append(resumeTask) }
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
            await Task.yield()
        }
    }

    // MARK: 안내 문구

    public nonisolated static let tunnelOffMessage = String(localized: "VPN이 꺼져 있어 Mac에 연결할 수 없습니다. VPN을 켜세요.")
    public nonisolated static let tunnelConnectingMessage = String(localized: "VPN을 연결하는 중입니다. 연결되면 이어서 진행합니다.")
    public nonisolated static let tunnelNeedsLoginMessage = String(localized: "tailnet 로그인이 필요합니다. 로그인한 뒤 VPN을 켜세요.")
    public nonisolated static let tunnelFailedMessage = String(localized: "VPN 연결에 실패했습니다. ‘다시 연결’을 누르세요.")
    public nonisolated static let pairingNeedsOwnTunnelMessage = String(localized: "다른 VPN이 켜져 있습니다. 이 앱의 VPN을 켜면 페어링을 이어서 진행합니다.")
    public nonisolated static let tunnelMessages: Set<String> = [tunnelOffMessage, tunnelConnectingMessage, tunnelNeedsLoginMessage, tunnelFailedMessage, pairingNeedsOwnTunnelMessage]
    public nonisolated static let tunnelPrepareFailedMessage = String(localized: "VPN 구성을 저장하지 못했습니다. VPN을 다시 켜고 'VPN 구성 추가' 알림이 뜨면 허용을 누르세요.")
    public nonisolated static let vpnNotConnectedMessage = String(localized: "VPN이 연결되지 않았습니다. VPN 상태를 확인한 뒤 다시 시도하세요.")
    public nonisolated static let vpnLoginBeforeRetryMessage = String(localized: "tailnet 로그인이 필요합니다. 로그인한 뒤 다시 시도하세요.")

    /// 설치·파일 받기를 시작하려다 VPN이 연결되지 않았을 때의 안내.
    public nonisolated static func vpnNotConnectedMessage(for state: TunnelState) -> String {
        state.isNeedsLogin ? vpnLoginBeforeRetryMessage : vpnNotConnectedMessage
    }

    public nonisolated static let tunnelConnectFailedMessage = String(localized: "VPN을 켜지 못했습니다. 잠시 뒤 VPN을 다시 켜세요.")
    public nonisolated static let pairedAddressMismatchMessage = String(localized: "승인한 Mac의 주소가 링크와 다릅니다. Mac에 표시된 QR 코드로 다시 페어링하세요.")
    public nonisolated static let pairingInfoFailedMessage = String(localized: "Mac과 짝을 맺었지만 Mac 정보를 받지 못했습니다. VPN 연결을 확인하고 Mac에서 QR 코드를 새로 열어 다시 페어링하세요.")
    public nonisolated static let pairingInterruptedMessage = String(localized: "앱이 화면에서 벗어나 페어링이 중단되었습니다. Mac에서 QR 코드를 새로 열고 다시 시도하세요.")
    public nonisolated static let saveFailedMessage = String(localized: "페어링 정보를 저장하지 못했습니다. 앱을 다시 열면 다시 페어링해야 합니다.")
    public nonisolated static let hostChangedMessage = String(localized: "이 주소의 Mac이 페어링한 Mac과 다릅니다. 다시 페어링하세요.")
    public nonisolated static let openFailedMessage = String(localized: "설치 창을 열지 못했습니다. 설치를 다시 누르세요.")
    public nonisolated static let reopenFailedMessage = String(localized: "설치 창을 다시 열지 못했습니다. 설치를 취소한 뒤 다시 설치하세요.")
    public nonisolated static let untrustedInstallURLMessage = String(localized: "설치 주소가 페어링한 Mac을 가리키지 않아 열지 않았습니다. iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요.")
    public nonisolated static let sessionExpiredMessage = InstallState.expiredMessage
    public nonisolated static let sessionFailedMessage = String(localized: "Mac에서 설치를 중단했습니다. Mac에서 빌드를 내렸거나 이 기기의 페어링이 해제되었을 수 있습니다. 빌드 목록을 새로고침하세요.")
    public nonisolated static let installTimeoutMessage = String(localized: "제한 시간 안에 전송이 끝났는지 확인하지 못했습니다. 홈 화면에서 앱이 설치되었는지 확인하고, 없으면 다시 설치하세요.")
    public nonisolated static let createSessionTimeoutMessage = String(localized: "Mac이 빌드를 확인하는 동안 응답 시간이 지났습니다. 잠시 뒤 다시 설치하세요.")

    /// 앱용 페어링이 이 앱의 터널을 기다릴 때의 안내. 바깥 VPN이 연결돼 있으면 그 이유를 말한다.
    public nonisolated static func pairingTunnelMessage(for state: TunnelState) -> String {
        state == .connected ? pairingNeedsOwnTunnelMessage : tunnelMessage(for: state)
    }

    public nonisolated static func tunnelMessage(for state: TunnelState) -> String {
        switch state {
        case .connecting: tunnelConnectingMessage
        case .needsLogin: tunnelNeedsLoginMessage
        case .failed: tunnelFailedMessage
        case .off, .disconnecting, .connected: tunnelOffMessage
        }
    }
}
