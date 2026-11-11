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
        "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요."
    public static let completedMessage =
        "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요. " + developerModeHint
    public static let expiredMessage = "설치 세션이 만료되었습니다. 다시 설치하세요."

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
/// - 페어링 요청 보내는 중: `phase == .requestingPairing`.
/// - Mac 승인 대기: `phase == .waitingApproval(deviceName:)`, 남은 시간은 `pairingExpiresAt`. 취소는 `cancelPairing()`.
/// - VPN이 켜지면 이어 할 페어링: `queuedPairing`(취소는 `cancelPairing()`).
/// - 다른 Mac으로 바꿀지 확인: `pendingReplacement`(`confirmReplacement()` / `dismissReplacement()`).
/// - VPN: `tunnel`(`.off`, `.connecting`, `.disconnecting`, `.needsLogin(authURL:)`, `.failed`, `.connected`). 동작이 VPN 때문에 멈췄으면 `needsTunnel`.
/// - 빌드 목록: `builds`. 한 번이라도 받았으면 `buildsLoadedAt`이 있다(받았는데 비어 있으면 게시된 빌드가 없는 것).
///   새로고침 중이면 `isRefreshing`, 마지막 새로고침이 실패했으면 `refreshError`.
/// - 설치: `installs[buildID]`(`InstallState`). 전송 진행은 `installProgress(for:)`, 끝난 상태 지우기는 `clearInstall(_:)`.
///   설치기를 기다리는 동안 설치 창 다시 열기는 `reopenInstaller(_:)`, 그만두기는 `cancelInstall(_:)`.
/// - 마지막 실패 안내: `lastError`(지우기는 `clearError()`).
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
        public var pairingPollInterval: Duration
        public var pairingTimeout: TimeInterval
        public var sessionPollInterval: Duration
        public var sessionTimeout: TimeInterval
        /// 호스트 요청의 제한 시간.
        public var requestTimeouts: HostAPI.Timeouts

        public init(
            pairingPollInterval: Duration = .seconds(1),
            pairingTimeout: TimeInterval = 120,
            sessionPollInterval: Duration = .seconds(1),
            sessionTimeout: TimeInterval = 600,
            requestTimeouts: HostAPI.Timeouts = .standard
        ) {
            self.pairingPollInterval = pairingPollInterval
            self.pairingTimeout = pairingTimeout
            self.sessionPollInterval = sessionPollInterval
            self.sessionTimeout = sessionTimeout
            self.requestTimeouts = requestTimeouts
        }

        public static let standard = Timing()
    }

    // MARK: 상태

    public private(set) var phase: Phase = .unpaired
    public private(set) var host: PairedHost?
    /// 승인 대기의 마감 시각(호스트의 `expiresAt`과 로컬 제한 중 이른 쪽). 승인 대기가 아니면 `nil`.
    public private(set) var pairingExpiresAt: Date?
    /// VPN이 연결되면 보낼 페어링. VPN이 꺼진 채 링크를 열었을 때 생긴다.
    public private(set) var queuedPairing: PairingLink?
    /// 이미 페어링한 Mac이나 진행 중인 페어링과 다른 링크를 받았다. 사용자가 확인해야 페어링을 시작한다.
    public private(set) var pendingReplacement: PairingLink?
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
    /// 마지막 동작이 VPN이 연결되지 않아 멈췄다. VPN이 연결되면 멈춘 페어링·새로고침을 이어 간다.
    public private(set) var needsTunnel = false

    // MARK: 의존성

    private let deviceName: String
    private let client: ClientInfo
    private let transport: any HTTPTransport
    private let store: any PairedHostStoring
    private let opener: any URLOpening
    private let tunnelController: any TunnelControlling
    private let clock: any PollingClock
    private let policy: HostPolicy
    private let timing: Timing

    // MARK: 내부 상태

    private struct PairingPoll { var link: PairingLink; var requestID: String; var deadline: Date }
    private struct ActiveSession { var sessionID: String; var installURL: URL; var deadline: Date }
    private struct Running { var token: UUID; var task: Task<Void, Never> }
    private struct PairingRun { var token: UUID; var link: PairingLink; var task: Task<Void, Never> }

    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var pairingPoll: PairingPoll?
    @ObservationIgnored private var pairing: PairingRun?
    /// 마지막으로 승인된 링크. 같은 링크가 다시 들어오면(1회용 코드라 다시 보내면 실패한다) 무시한다.
    @ObservationIgnored private var lastApprovedLink: PairingLink?
    @ObservationIgnored private var installTasks: [String: Running] = [:]
    @ObservationIgnored private var activeSessions: [String: ActiveSession] = [:]
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var tunnelObserver: Task<Void, Never>?
    @ObservationIgnored private var refreshesInFlight = 0
    /// 호스트가 바뀔 때(복원·다른 호스트 승인·잊기)마다 늘어난다. 기다리는 동안 값이 바뀐 작업은 결과를 쓰지 않는다.
    @ObservationIgnored private var hostGeneration = 0

    public init(
        deviceName: String,
        client: ClientInfo,
        transport: any HTTPTransport = URLSessionTransport(),
        store: any PairedHostStoring,
        opener: any URLOpening,
        tunnel: any TunnelControlling,
        clock: any PollingClock = SystemPollingClock(),
        hostPolicy: HostPolicy = .tailnetOnly,
        timing: Timing = .standard
    ) {
        self.deviceName = deviceName
        self.client = client
        self.transport = transport
        self.store = store
        self.opener = opener
        self.tunnelController = tunnel
        self.clock = clock
        self.policy = hostPolicy
        self.timing = timing
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
        pairing?.task.cancel()
        for running in installTasks.values { running.task.cancel() }
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
        if phase == .unpaired { phase = .paired }
        guard generation == hostGeneration else { return }
        await refresh()
    }

    // MARK: 페어링

    /// 앱이 받은 URL을 처리한다. 페어링 링크가 아니면 `false`.
    /// 이미 페어링한 Mac이나 진행 중인 페어링과 다른 링크면 바로 시작하지 않고 `pendingReplacement`에 둔다.
    @discardableResult
    public func handle(url: URL) -> Bool {
        do {
            let link = try PairingLink.parse(url: url, policy: policy)
            request(link, confirmed: false)
            return true
        } catch {
            if error == .notPairingLink { return false }
            lastError = error.userMessage
            return true
        }
    }

    /// 사용자가 직접 입력한 코드와 Mac 주소로 페어링한다. 입력 자체가 사용자의 확인이므로 바로 시작한다.
    public func pair(code: String, host: String) {
        do {
            request(try PairingLink(host: host, code: code, policy: policy), confirmed: true)
        } catch {
            lastError = error.userMessage
        }
    }

    /// 링크(QR 등)로 페어링한다. `handle(url:)`과 같이 다른 Mac으로 바뀌면 확인을 거친다.
    public func pair(link: PairingLink) {
        request(link, confirmed: false)
    }

    /// `pendingReplacement`의 링크로 페어링을 시작한다. 진행 중이던 페어링은 그만둔다.
    /// 지금 페어링한 Mac은 새 Mac이 승인할 때까지 그대로 남는다.
    public func confirmReplacement() {
        guard let link = pendingReplacement else { return }
        pendingReplacement = nil
        startPairing(link)
    }

    /// `pendingReplacement`를 버린다. 아무 상태도 바꾸지 않는다.
    public func dismissReplacement() {
        pendingReplacement = nil
    }

    /// 진행 중이거나 VPN을 기다리는 페어링을 그만둔다. 페어링한 Mac과 VPN은 그대로 둔다.
    public func cancelPairing() {
        pairing?.task.cancel()
        pairing = nil
        pairingPoll = nil
        pairingExpiresAt = nil
        queuedPairing = nil
        if phase == .requestingPairing || isWaitingApproval { phase = settledPhase }
    }

    private func request(_ link: PairingLink, confirmed: Bool) {
        // 링크가 다른 정책으로 만들어졌을 수 있으므로 이 모델의 정책으로 다시 확인한다.
        guard let validHost = policy.validatedHost(link.host), validHost == link.host else {
            lastError = PairingLinkError.hostNotAllowed.userMessage
            return
        }
        // 같은 링크가 다시 들어왔다(QR을 다시 찍음, URL 중복 전달). 1회용 코드를 다시 보내지 않는다.
        if link == inFlightPairingLink { return }
        if link == lastApprovedLink, host?.fqdn == link.host { return }
        if !confirmed, needsConfirmation(link) {
            pendingReplacement = link
            return
        }
        pendingReplacement = nil
        startPairing(link)
    }

    private func needsConfirmation(_ link: PairingLink) -> Bool {
        if let host, host.fqdn != link.host { return true }
        if let other = inFlightPairingLink, other != link { return true }
        return false
    }

    /// 진행 중(요청·승인 대기)이거나 VPN을 기다리는 페어링의 링크.
    private var inFlightPairingLink: PairingLink? {
        pairingPoll?.link ?? pairing?.link ?? queuedPairing
    }

    private func startPairing(_ link: PairingLink) {
        cancelPairing()
        lastError = nil
        guard ensureTunnel(queue: .pair(link)) else { return }
        let token = UUID()
        pairing = PairingRun(token: token, link: link, task: Task { [weak self] in
            await self?.runPairing(link, token: token)
        })
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

    private func runPairing(_ link: PairingLink, token: UUID) async {
        defer { if pairing?.token == token { pairing = nil } }
        phase = .requestingPairing
        guard let api = makeAPI(link.host) else {
            phase = settledPhase
            lastError = PairingLinkError.hostNotAllowed.userMessage
            return
        }

        let started: PairRequestState
        do {
            started = try await api.requestPairing(code: link.code, deviceName: deviceName)
        } catch {
            guard ownsPairing(token), !(error is CancellationError) else { return }
            phase = settledPhase
            lastError = Self.message(for: error)
            return
        }
        guard ownsPairing(token) else { return }

        let now = clock.now
        var deadline = now.addingTimeInterval(timing.pairingTimeout)
        if let expiresAt = started.expiresAt, expiresAt > now, expiresAt < deadline { deadline = expiresAt }
        let poll = PairingPoll(link: link, requestID: started.requestId, deadline: deadline)
        pairingPoll = poll
        pairingExpiresAt = deadline
        phase = .waitingApproval(deviceName: deviceName)
        if started.state != .pending {
            await apply(started, poll: poll, token: token)
            return
        }
        await pollPairing(api: api, poll: poll, token: token)
    }

    private func pollPairing(api: HostAPI, poll: PairingPoll, token: UUID) async {
        while true {
            if clock.now >= poll.deadline {
                await finishPairingAfterDeadline(api: api, poll: poll, token: token)
                return
            }
            do { try await clock.sleep(for: timing.pairingPollInterval) } catch { return }
            guard ownsPairing(token) else { return }
            let state: PairRequestState
            do {
                state = try await api.pairingState(requestID: poll.requestID)
            } catch let error as HostAPIError where error.isConnectionFailure {
                guard ownsPairing(token) else { return }
                continue  // 일시적 끊김은 마감까지 다시 시도한다.
            } catch {
                guard ownsPairing(token), !(error is CancellationError) else { return }
                failPairing(Self.message(for: error))
                return
            }
            guard ownsPairing(token) else { return }
            if state.state == .pending { continue }
            await apply(state, poll: poll, token: token)
            return
        }
    }

    /// 로컬 마감이 지나면 호스트에 한 번 더 묻고 그 답을 따른다(호스트는 결정된 요청을 1시간 보관한다).
    /// 답을 못 받거나 아직 대기 중이면 만료로 끝낸다.
    private func finishPairingAfterDeadline(api: HostAPI, poll: PairingPoll, token: UUID) async {
        let state = try? await api.pairingState(requestID: poll.requestID)
        guard ownsPairing(token) else { return }
        if let state, state.state != .pending {
            await apply(state, poll: poll, token: token)
        } else {
            failPairing(Self.pairingExpiredMessage)
        }
    }

    private func apply(_ state: PairRequestState, poll: PairingPoll, token: UUID) async {
        guard ownsPairing(token) else { return }
        switch state.state {
        case .pending:
            return
        case .denied:
            failPairing(Self.pairingDeniedMessage)
        case .expired:
            failPairing(Self.pairingExpiredMessage)
        case .approved:
            guard let summary = state.host else {
                failPairing(HostAPIError.invalidResponse(status: 200, "approved without host").userMessage)
                return
            }
            // 승인 응답의 주소는 링크의 주소와 같아야 한다. 저장하는 주소는 실제로 페어링한 주소다.
            // 테스트 정책의 루프백 링크만 예외다(가짜 호스트의 fqdn은 루프백이 아니다).
            let isLoopbackTest = policy.allowsLoopback && HostPolicy.loopbackHost(poll.link.host) != nil
            if !isLoopbackTest, HostPolicy.normalizedName(summary.fqdn) != poll.link.host {
                failPairing(Self.pairedAddressMismatchMessage)
                return
            }
            let paired = PairedHost(hostId: summary.hostId, hostName: summary.hostName, fqdn: poll.link.host, pairedAt: clock.now)
            pairingPoll = nil
            pairingExpiresAt = nil
            if host?.fqdn != paired.fqdn || host?.hostId != paired.hostId {
                resetHostScopedState()
            }
            host = paired
            phase = .paired
            lastApprovedLink = poll.link
            do {
                try store.save(paired)
                lastError = nil
            } catch {
                lastError = Self.saveFailedMessage
            }
            await refresh()
        }
    }

    private func failPairing(_ message: String) {
        pairingPoll = nil
        pairingExpiresAt = nil
        phase = settledPhase
        lastError = message
    }

    // MARK: 빌드 목록

    public func refresh() async {
        guard let current = host, let api = makeAPI(current.fqdn) else { return }
        guard ensureTunnel(queue: .refresh) else { return }
        let generation = hostGeneration
        refreshesInFlight += 1
        isRefreshing = true
        defer {
            refreshesInFlight -= 1
            isRefreshing = refreshesInFlight > 0
        }
        do {
            let info = try await api.info()
            guard generation == hostGeneration else { return }
            guard info.hostId == current.hostId else {
                failRefresh(Self.hostChangedMessage)
                return
            }
            guard info.protocolVersion == 1 else {
                failRefresh(HostAPIError.protocolMismatch("info.protocol").userMessage)
                return
            }
            let list = try await api.builds()
            guard generation == hostGeneration else { return }
            builds = list
            buildsLoadedAt = clock.now
            if let previous = refreshError, lastError == previous { lastError = nil }
            refreshError = nil
            if var renamed = host, info.hostName != renamed.hostName {
                renamed.hostName = info.hostName
                host = renamed
                try? store.save(renamed)
            }
        } catch {
            guard !(error is CancellationError), generation == hostGeneration else { return }
            failRefresh(Self.message(for: error))
        }
    }

    private func failRefresh(_ message: String) {
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
        guard ensureTunnel(queue: nil) else { return }
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
                conclude(id, terminal)
                return
            }
            installs[id] = Self.progressState(status)
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

    /// 진행 확인(페어링 승인·설치 진행)을 멈춘다. 앱이 백그라운드로 가거나 화면이 사라질 때 부른다.
    /// 상태는 그대로 두고 `resumePolling()`으로 이어 간다.
    public func stopPolling() {
        pairing?.task.cancel()
        pairing = nil
        // 요청을 보내기 전·응답 전이면 이어 갈 것이 없으므로 페어링 전 상태로 돌린다.
        if phase == .requestingPairing, pairingPoll == nil { phase = settledPhase }
        for running in installTasks.values { running.task.cancel() }
        installTasks = [:]
        resumeTask?.cancel()
        resumeTask = nil
    }

    /// 멈춘 진행 확인을 다시 시작한다. 마감이 지났으면 호스트에 한 번 물어 결과를 정한다.
    public func resumePolling() {
        if pairing == nil, let poll = pairingPoll, let api = makeAPI(poll.link.host) {
            let token = UUID()
            pairing = PairingRun(token: token, link: poll.link, task: Task { [weak self] in
                guard let self else { return }
                defer { if self.pairing?.token == token { self.pairing = nil } }
                await self.pollPairing(api: api, poll: poll, token: token)
            })
        }
        if let current = host, let api = makeAPI(current.fqdn) {
            for (id, active) in activeSessions where installTasks[id] == nil {
                startSessionPolling(buildID: id, api: api, active: active)
            }
        }
    }

    // MARK: 호스트 잊기

    /// 페어링한 Mac을 잊고 VPN을 끈다.
    public func forgetHost() async {
        stopPolling()
        cancelPairing()
        pendingReplacement = nil
        refreshQueued = false
        lastApprovedLink = nil
        resetHostScopedState()
        store.clear()
        host = nil
        phase = .unpaired
        needsTunnel = false
        lastError = nil
        await tunnelController.disconnect()
        tunnel = tunnelController.currentState()
    }

    private func resetHostScopedState() {
        hostGeneration &+= 1
        for running in installTasks.values { running.task.cancel() }
        installTasks = [:]
        activeSessions = [:]
        installs = [:]
        builds = []
        buildsLoadedAt = nil
        refreshError = nil
        resumeTask?.cancel()
        resumeTask = nil
    }

    // MARK: VPN

    /// VPN 구성을 확인(`prepare`)한 뒤 VPN을 켠다.
    public func connectTunnel() async {
        do {
            try await tunnelController.prepare()
        } catch {
            guard !(error is CancellationError) else { return }
            tunnel = tunnelController.currentState()
            lastError = Self.tunnelPrepareFailedMessage
            return
        }
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
        await tunnelController.disconnect()
        tunnel = tunnelController.currentState()
    }

    private func tunnelDidChange(_ state: TunnelState) {
        tunnel = state
        guard state == .connected else { return }
        guard needsTunnel || queuedPairing != nil || refreshQueued else { return }
        needsTunnel = false
        if let message = lastError, Self.tunnelMessages.contains(message) { lastError = nil }
        let link = queuedPairing
        queuedPairing = nil
        let runRefresh = refreshQueued
        refreshQueued = false
        if let link { startPairing(link) }
        if runRefresh {
            resumeTask?.cancel()
            resumeTask = Task { [weak self] in
                await self?.refresh()
                self?.resumeTask = nil
            }
        }
    }

    private enum Deferred { case pair(PairingLink), refresh }

    /// VPN이 연결돼 있으면 `true`. 아니면 안내를 띄우고, 연결되면 이어 할 동작을 기억한다.
    /// 페어링과 새로고침은 따로 기억하므로 서로 지우지 않는다.
    private func ensureTunnel(queue action: Deferred?) -> Bool {
        tunnel = tunnelController.currentState()
        if tunnel == .connected {
            needsTunnel = false
            return true
        }
        needsTunnel = true
        switch action {
        case .pair(let link): queuedPairing = link
        case .refresh: refreshQueued = true
        case nil: break
        }
        lastError = Self.tunnelMessage(for: tunnel)
        return false
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
            var tasks: [Task<Void, Never>] = installTasks.values.map(\.task)
            if let pairing { tasks.append(pairing.task) }
            if let resumeTask { tasks.append(resumeTask) }
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
            await Task.yield()
        }
    }

    // MARK: 안내 문구

    public nonisolated static let tunnelOffMessage = "VPN이 꺼져 있어 Mac에 연결할 수 없습니다. VPN을 켜세요."
    public nonisolated static let tunnelConnectingMessage = "VPN을 연결하는 중입니다. 연결되면 이어서 진행합니다."
    public nonisolated static let tunnelNeedsLoginMessage = "tailnet 로그인이 필요합니다. 로그인한 뒤 VPN을 켜세요."
    public nonisolated static let tunnelFailedMessage = "VPN 연결에 실패했습니다. ‘다시 연결’을 누르세요."
    public nonisolated static let tunnelMessages: Set<String> = [tunnelOffMessage, tunnelConnectingMessage, tunnelNeedsLoginMessage, tunnelFailedMessage]
    public nonisolated static let tunnelPrepareFailedMessage = "VPN 구성을 저장하지 못했습니다. VPN을 다시 켜고 'VPN 구성 추가' 알림이 뜨면 허용을 누르세요."
    public nonisolated static let tunnelConnectFailedMessage = "VPN을 켜지 못했습니다. 잠시 뒤 VPN을 다시 켜세요."
    public nonisolated static let pairingDeniedMessage = "Mac에서 페어링을 거절했습니다. 다시 하려면 Mac에서 새 코드를 여세요."
    public nonisolated static let pairingExpiredMessage = "페어링 요청이 만료되었습니다. Mac에서 새 코드를 열고 다시 시도하세요."
    public nonisolated static let pairedAddressMismatchMessage = "승인한 Mac의 주소가 링크와 다릅니다. Mac에 표시된 링크로 다시 페어링하세요."
    public nonisolated static let saveFailedMessage = "페어링 정보를 저장하지 못했습니다. 앱을 다시 열면 다시 페어링해야 합니다."
    public nonisolated static let hostChangedMessage = "이 주소의 Mac이 페어링한 Mac과 다릅니다. 다시 페어링하세요."
    public nonisolated static let openFailedMessage = "설치 창을 열지 못했습니다. 설치를 다시 누르세요."
    public nonisolated static let reopenFailedMessage = "설치 창을 다시 열지 못했습니다. 설치를 취소한 뒤 다시 설치하세요."
    public nonisolated static let untrustedInstallURLMessage = "설치 주소가 페어링한 Mac을 가리키지 않아 열지 않았습니다. iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요."
    public nonisolated static let sessionExpiredMessage = InstallState.expiredMessage
    public nonisolated static let sessionFailedMessage = "Mac에서 설치를 중단했습니다. Mac에서 빌드를 내렸거나 이 기기의 페어링이 해제되었을 수 있습니다. 빌드 목록을 새로고침하세요."
    public nonisolated static let installTimeoutMessage = "제한 시간 안에 전송이 끝났는지 확인하지 못했습니다. 홈 화면에서 앱이 설치되었는지 확인하고, 없으면 다시 설치하세요."
    public nonisolated static let createSessionTimeoutMessage = "Mac이 빌드를 확인하는 동안 응답 시간이 지났습니다. 잠시 뒤 다시 설치하세요."

    public nonisolated static func tunnelMessage(for state: TunnelState) -> String {
        switch state {
        case .connecting: tunnelConnectingMessage
        case .needsLogin: tunnelNeedsLoginMessage
        case .failed: tunnelFailedMessage
        case .off, .disconnecting, .connected: tunnelOffMessage
        }
    }
}
