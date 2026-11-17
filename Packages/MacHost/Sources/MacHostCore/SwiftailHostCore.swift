// SwiftailHostCore — Swiftail 노드(SwiftailHostServer)와 호스트 로직(RDHostLogic)을 MacHostKit의 `HostCore`로 묶는다.
// 예전 Go 코어의 host 모드가 하던 일을 옮겨 온 것이다(Go 코어는 없어졌다).
//
// - 노드: `start`가 `SwiftailHostRuntime`을 띄우고 `stop`이 그 Task를 취소한 뒤 노드와 인증서 관리자가 끝나기를 기다린다.
//   `run()`이 다시 켜도 소용없는 실패로 끝나면 다시 켜지 않는다(사용자가 공유를 다시 시작할 때까지 상태로만 알린다).
// - 로그인: `needsLogin(url)`의 URL은 상태(`authURL`)와 상태 이벤트로만 화면에 간다. 로그 파일과 로그 이벤트에는 쓰지 않는다.
//   `startInteractiveLogin()`은 부르지 않는다(이미 등록돼 있어도 새 node 키로 다시 등록한다. Swiftail 계약).
// - 상태 이벤트: 250ms(실행 전)·2초(실행 중)마다 상태를 읽어 바뀌었으면 낸다. 그때 로직의 `sweep()`도 한다
//   (예전 Go 코어와 같은 간격: 페어링 요청·세션 만료, 오래된 기록·거부 기록·직접 연결 실패 차단 정리).
// - 로직의 사건은 완전한 형태(`eventDetails`)로 받아 RDModels 이벤트에 없는 값(크래시를 받은 시각, 에이전트 요청의 노드 이름,
//   멈춤 요청의 기기 id)을 채워 넘긴다. 로직이 잠금 안에서 낸 순서 그대로 구독자 버퍼에 동기로 들어간다.
// - QR·링크 페어링: 노드에 `PairingHost`(SwiftailPairing)를 붙여 `pairingPort`를 듣는다(OfferPairing.swift). 승인은 화면이
//   `decidePairing`으로 하고, 허용하면 로직의 허용 목록에 코드 페어링과 같은 항목을 넣는다.
// - `stop()`: 노드를 멈추고, 직접 연결 리스너를 닫고, 로직을 닫아(열린 세션의 `failed`, addenda C.3) 그 이벤트까지 넘긴 뒤
//   스트림을 끝낸다(`HostCore` 계약). 로직의 이벤트는 동기로 스트림 버퍼에 들어가므로 끝내기 전에 모두 들어 있다.
// - 실행 구분: `start`마다 실행 번호를 매긴다. 로직·노드·페어링이 내는 이벤트는 그 실행이 아직 지금 실행일 때만 구독자에게 간다.
//   `stop()`은 허용한 QR 페어링의 마무리(짝 저장 확인과 허용 목록 넣기)를 취소하고 끝나기를 기다린 뒤 로직을 닫는다.
import Darwin
import Foundation
import MacHostKit
import RDHostLogic
import RDModels
import Swiftail
import SwiftailCertificates
import SwiftailHostServer
import SwiftailPairing
import Synchronization

public final class SwiftailHostCore: HostCore, Sendable {
    /// 저장 위치. 노드 상태는 `CoreConfig.stateDir`에 둔다.
    public struct Layout: Sendable {
        /// 직접 연결 신원 폴더. nil이면 `stateDir`(예전 Go 코어가 직접 연결 신원을 두던 자리와 같다).
        public var directDirectory: URL?
        /// 예전 Go 코어가 남긴 노드 상태 폴더. 있으면 노드가 처음 `.running`이 된 뒤 지운다(직접 연결 신원은 먼저 옮긴다).
        public var legacyStateDirectory: URL?
        /// QR·링크 페어링의 짝 목록 폴더. nil이면 `stateDir`의 `pairing`.
        public var pairingDirectory: URL?
        /// QR·링크 페어링 연결을 받는 tailnet 포트. 제안의 링크에 실린다.
        public var pairingPort: UInt16
        /// 제안 링크의 연결 도메인 주소(Info.plist `RDPairLinkBase`). nil이면 `remotedebug://pair`.
        public var pairingLinkBase: PairingLinkBase?

        public init(directDirectory: URL? = nil, legacyStateDirectory: URL? = nil, pairingDirectory: URL? = nil,
                    pairingPort: UInt16 = SwiftailHostCore.defaultPairingPort, pairingLinkBase: PairingLinkBase? = nil) {
            (self.directDirectory, self.legacyStateDirectory) = (directDirectory, legacyStateDirectory)
            (self.pairingDirectory, self.pairingPort, self.pairingLinkBase) = (pairingDirectory, pairingPort, pairingLinkBase)
        }
    }

    /// QR·링크 페어링의 tailnet 포트. 고정이라 tailnet 정책(ACL)에 적을 수 있다(protocol-addenda B.5).
    public static let defaultPairingPort: UInt16 = 4747
    /// 제안 링크의 기본 앞부분. iPhone 앱이 이 스킴을 받는다.
    static let pairingBaseURL = URL(string: PairingLinkBase.customScheme)!
    /// QR 페어링 요청이 승인을 기다리는 시간(계약 P5의 120초와 같다).
    static let offerRequestSeconds: TimeInterval = 120
    /// 허용한 뒤 `PairingHost`가 짝으로 저장하기를 기다리는 시간.
    static let defaultOfferSaveTimeout: Duration = .seconds(5)

    /// 실행 하나의 것.
    private final class Session: Sendable {
        /// 실행 번호. 이 실행의 이벤트는 이 번호가 지금 실행일 때만 구독자에게 간다.
        let run: Int
        let config: CoreConfig
        let logic: HostLogic
        let node: any HostNodeLayer
        let log: CoreLogFile
        let stateDirectory: URL
        let directDirectory: URL
        let lock = Mutex(SessionState())
        let runTask = Mutex<Task<Void, Never>?>(nil)
        let monitorTask = Mutex<Task<Void, Never>?>(nil)
        /// QR·링크 페어링의 여는 쪽과 그것을 돌리는 Task. 붙이지 못했으면 nil.
        let pairing = Mutex<(host: (any PairingHosting)?, task: Task<Void, Never>?)>((nil, nil))
        let offers = PendingOffers()
        /// 짝 목록 맞추기를 한 번에 하나씩.
        let reconciling = SerialLock()

        init(run: Int, config: CoreConfig, logic: HostLogic, node: any HostNodeLayer, log: CoreLogFile, stateDirectory: URL,
             directDirectory: URL) {
            (self.run, self.config, self.logic, self.node, self.log) = (run, config, logic, node, log)
            (self.stateDirectory, self.directDirectory) = (stateDirectory, directDirectory)
        }
    }

    private struct SessionState {
        var phase: NodePhase = .running
        var snapshot = NodeSnapshot()
        var certificate: CertificateSnapshot?
        var peerPaths: [String: RDModels.PeerPath] = [:]
        var direct: DirectIdentity?
        var directListener: HTTPListener?
        var lastEmitted: CoreStatus?
        var lastFailure: CertificateFailure?
        var lockWaiting = false
        var loggedState: String?
        var reachedRunning = false
        var stopped = false
        /// 화면이 허용 목록을 한 번이라도 넣었다. 그 전에는 짝 목록을 맞추지 않는다(빈 목록으로 짝을 지우지 않게).
        var devicesApplied = false
        /// 허용한 QR 페어링의 마무리(요청 id → 작업). `stop()`이 취소하고 기다린다.
        var admissions: [String: Task<DeviceEntry?, any Error>] = [:]
    }

    private struct Shared {
        var session: Session?
        var subscribers: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
        /// 이번 앱 실행에서 직접 연결을 한 번이라도 켰다(상태의 `direct`).
        var directEverOn = false
        /// 마지막으로 매긴 실행 번호.
        var lastRun = 0
    }

    private let layout: Layout
    private let factory: HostNodeFactory
    private let shared = Mutex(Shared())
    private let lifecycle = SerialLock()
    /// 상태를 읽는 간격(실행 전, 실행 중).
    let pollIntervals: (starting: Duration, running: Duration)
    /// 직접 연결 리스너를 루프백에만 묶는다(시험).
    let directLoopbackOnly: Bool
    /// 허용한 뒤 짝 저장을 기다리는 시간.
    let offerSaveTimeout: Duration

    public convenience init(layout: Layout = Layout()) {
        self.init(layout: layout, factory: .swiftail)
    }

    /// 앱의 저장 위치로. `pairingLinkBase`가 있으면 제안 링크와 QR을 그 https 주소로 낸다.
    public convenience init(paths: HostPaths, pairingLinkBase: PairingLinkBase? = nil) {
        self.init(layout: Layout(directDirectory: paths.directDir, legacyStateDirectory: paths.legacyStateDir,
                                 pairingDirectory: paths.pairingDir, pairingLinkBase: pairingLinkBase))
    }

    init(layout: Layout, factory: HostNodeFactory, pollIntervals: (starting: Duration, running: Duration) = (.milliseconds(250), .seconds(2)),
         directLoopbackOnly: Bool = false, offerSaveTimeout: Duration = SwiftailHostCore.defaultOfferSaveTimeout) {
        self.layout = layout
        self.factory = factory
        self.pollIntervals = pollIntervals
        self.directLoopbackOnly = directLoopbackOnly
        self.offerSaveTimeout = offerSaveTimeout
    }

    // MARK: HostCore — 수명

    public func start(_ config: CoreConfig) async throws {
        await lifecycle.lock()
        defer { lifecycle.unlock() }
        guard shared.withLock({ $0.session == nil }) else {
            throw APIErrorBody(code: "invalid_config", message: String(localized: "코어가 이미 실행 중입니다."))
        }
        guard config.mode == .host else { throw Self.invalid("host 모드만 지원합니다.") }
        guard !config.stateDir.isEmpty else { throw Self.invalid("stateDir가 필요합니다.") }
        guard !config.hostname.isEmpty else { throw Self.invalid("hostname이 필요합니다.") }
        guard (1...65_535).contains(config.port) else { throw Self.invalid("port가 올바르지 않습니다.") }
        let stateDirectory = URL(filePath: config.stateDir, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw Self.invalid("stateDir를 만들 수 없습니다.")
        }
        var node = NodeConfiguration(stateDirectory: stateDirectory, hostname: config.hostname,
                                     authKey: config.authKey.isEmpty ? nil : config.authKey, ephemeral: config.ephemeral)
        let control = config.controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !control.isEmpty {
            guard let url = URL(string: control), url.scheme == "https" || url.scheme == "http" else {
                throw Self.invalid("controlURL은 http(s) 주소여야 합니다.")
            }
            node.controlURL = url
        }
        let directDirectory = layout.directDirectory ?? stateDirectory
        if let legacy = layout.legacyStateDirectory {
            LegacyState.adoptDirectIdentity(from: legacy, to: directDirectory)
        }
        let log = CoreLogFile(path: config.logPath)

        let run = shared.withLock { value -> Int in
            value.lastRun += 1
            return value.lastRun
        }
        // 로직은 노드보다 먼저 선다(직접 연결은 tailnet과 무관하게 답한다).
        let infoBox = InfoBox()
        let logic: HostLogic
        do {
            logic = try HostLogic(options: HostLogic.Options(
                publishDirectory: config.publishDir,
                info: { [infoBox] in infoBox.info(config: config) },
                baseURL: { [infoBox] in CoreStatusMapping.baseURL(tls: config.listenTLS, fqdn: infoBox.fqdn, port: config.port) },
                direct: { [infoBox] in infoBox.directInfo() },
                events: { _ in },
                updatePageURL: { UpdatePageServer.shared.publicURL },
                eventDetails: { [weak self] detail in
                    self?.broadcast(run: run, Self.coreEvent(detail))
                    // 설치 페이지 코드로 요청이 오면 앱용 QR은 닫는다: 페어링은 한 번에 하나다.
                    if case .pairRequest(let event) = detail.event, event.confirmationCode == nil { self?.closeOfferInBackground(run: run) }
                }
            ))
        } catch let error as APIErrorBody {
            throw error
        } catch {
            throw Self.invalid(String(localized: "호스트를 준비하지 못했습니다."))
        }

        let configuration = HostConfiguration(
            node: node,
            certificates: config.listenTLS ? CertificateConfiguration(directoryURL: CertificateConfiguration.letsEncryptDirectoryURL) : nil,
            port: UInt16(config.port)
        )
        let layer: any HostNodeLayer
        do {
            layer = try factory.make(configuration, logic, { [weak self] event in self?.nodeEvent(event, run: run) })
        } catch {
            logic.close()
            throw Self.invalid(String(localized: "노드 설정이 올바르지 않습니다."))
        }
        let session = Session(run: run, config: config, logic: logic, node: layer, log: log, stateDirectory: stateDirectory,
                              directDirectory: directDirectory)
        sessionInfo.withLock { $0 = infoBox }
        shared.withLock { $0.session = session }
        log.line("info: 시작: Swiftail 노드(\(config.listenTLS ? "TLS" : "평문") \(config.port))")

        await attachPairing(session, stateDirectory: stateDirectory)

        session.runTask.withLock { $0 = Task { [weak self] in
            do {
                try await layer.run()
            } catch {
                self?.nodeEnded(session, error: error)
            }
        } }
        // 사용자가 공유를 (다시) 시작했다: 조건을 기다리던 발급을 곧바로 다시 본다(동작 R).
        Task { await layer.retryCertificates() }
        session.monitorTask.withLock { $0 = Task { [weak self] in await self?.monitor(session) } }

        if config.directListen {
            // tailnet과 무관하다: 실패해도 노드는 멈추지 않는다.
            do {
                try await setDirect(true)
            } catch {
                log.line("warn: 직접 연결 리스너를 열지 못했습니다")
                broadcast(run: run, .log(LogEvent(level: "warn", message: String(localized: "직접 연결 리스너를 열지 못했습니다."))))
            }
        }
    }

    public func stop() async {
        await lifecycle.lock()
        defer { lifecycle.unlock() }
        guard let session = shared.withLock({ $0.session }) else { return }
        let admissions = session.lock.withLock { value -> [Task<DeviceEntry?, any Error>] in
            value.stopped = true
            defer { value.admissions = [:] }
            return Array(value.admissions.values)
        }
        // 허용한 QR 페어링의 마무리: 취소하고 끝나기를 기다린다(이 실행의 로직이 열려 있을 때 끝나게).
        for task in admissions { task.cancel() }
        for task in admissions { _ = await task.result }
        // 페어링: 듣기를 멈춘다. 승인을 기다리던 요청은 취소되어 거절로 돌아간다(그 사건까지 넘긴 뒤 로직을 닫는다).
        let pairing = session.pairing.withLock { value in
            defer { value = (nil, nil) }
            return value.task
        }
        pairing?.cancel()
        await pairing?.value
        // 노드: 취소하고 `run()`(노드와 인증서 관리자)이 끝나기를 기다린다.
        let run = session.runTask.withLock { $0 }
        run?.cancel()
        await run?.value
        session.monitorTask.withLock { $0 }?.cancel()
        await session.monitorTask.withLock({ $0 })?.value
        let listener = session.lock.withLock { value -> HTTPListener? in
            defer { value.directListener = nil }
            return value.directListener
        }
        listener?.close()
        // 열린 세션의 `failed` 등 로직의 마지막 이벤트가 구독자 버퍼에 들어간다.
        session.logic.close()
        session.log.line("info: 멈춤")
        let subscribers = shared.withLock { value -> [AsyncStream<CoreEvent>.Continuation] in
            defer {
                value.session = nil
                value.subscribers = [:]
            }
            return Array(value.subscribers.values)
        }
        sessionInfo.withLock { $0 = nil }
        for continuation in subscribers { continuation.finish() }
    }

    public func logOut(_ config: CoreConfig) async {
        await lifecycle.lock()
        defer { lifecycle.unlock() }
        // `stop()`이 끝났다(노드와 인증서 관리자의 `run()`이 끝났다). 그다음이 서버 쪽 로그아웃, 그다음이 폴더 지우기다.
        let log = CoreLogFile(path: config.logPath)
        guard shared.withLock({ $0.session == nil }), !config.stateDir.isEmpty else {
            log.line("warn: 로그아웃: 노드가 돌고 있어 서버에 알리지 않음")
            return
        }
        let stateDirectory = URL(filePath: config.stateDir, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: stateDirectory.appending(path: "identity.json").path) else {
            log.line("info: 로그아웃: 등록한 적 없음(서버에 알릴 것 없음)")
            return
        }
        var node = NodeConfiguration(stateDirectory: stateDirectory, hostname: config.hostname.isEmpty ? "rd-mac" : config.hostname)
        if let url = URL(string: config.controlURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil {
            node.controlURL = url
        }
        let factory = factory
        let nodeConfiguration = node
        // Swiftail이 10초 기한을 두지만 그 바깥에서도 묶는다(앱의 로그아웃이 멈추지 않게).
        let outcome = await Self.withDeadline(seconds: 12) { () -> String in
            do {
                try await factory.logOut(nodeConfiguration)
                return "info: 로그아웃: 서버에 알림"
            } catch let error as NodeError {
                return "warn: 로그아웃: 서버에 알리지 못함(\(Self.logName(error))). 서버가 이미 적용했을 수 있다. 로컬 상태는 지운다"
            } catch {
                return "warn: 로그아웃: 서버에 알리지 못함. 로컬 상태는 지운다"
            }
        } ?? "warn: 로그아웃: 기한 안에 끝나지 않음. 서버가 이미 적용했을 수 있다. 로컬 상태는 지운다"
        log.line(outcome)
    }

    // MARK: HostCore — 상태·이벤트

    public func status() async throws -> CoreStatus {
        let session = try current()
        await refresh(session)
        return makeStatus(session)
    }

    public func events() -> AsyncStream<CoreEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoreEvent.self, bufferingPolicy: .unbounded)
        let id = UUID()
        let added = shared.withLock { value -> Bool in
            guard value.session != nil else { return false }
            value.subscribers[id] = continuation
            return true
        }
        guard added else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.shared.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: HostCore — 로직

    public func publish(_ request: PublishRequest) async throws {
        let session = try current()
        _ = try await Self.detached { try session.logic.publish(request) }
    }

    public func unpublish(buildID: String) async throws {
        let session = try current()
        try await Self.detached { try session.logic.unpublish(buildID: buildID) }
    }

    public func publishResource(_ request: ResourcePublishRequest) async throws {
        let session = try current()
        _ = try await Self.detached { try session.logic.publishResource(request) }
    }

    public func unpublishResource(id: String) async throws {
        let session = try current()
        try await Self.detached { try session.logic.unpublishResource(id: id) }
    }

    public func setAgentBoard(_ board: Data) async throws {
        try current().logic.setAgentBoard(board)
    }

    public func setDevices(_ devices: [DeviceEntry]) async throws {
        let session = try current()
        try session.logic.setDevices(devices)
        session.lock.withLock { $0.devicesApplied = true }
        await reconcilePairing(session)
    }

    public func openPairing(ttlSeconds: Int) async throws -> PairingCode {
        let session = try current()
        let code = try session.logic.openPairing(ttlSeconds: ttlSeconds)
        await session.pairing.withLock { $0.host }?.closeCurrentOffer()
        return PairingCode(code: code.code, expiresAt: code.expiresAt)
    }

    public func decidePairing(requestID: String, allow: Bool) async throws -> DeviceEntry? {
        let session = try current()
        if session.offers.knows(requestID) { return try await decideOffer(session, requestID: requestID, allow: allow) }
        return try session.logic.decidePairing(requestID: requestID, allow: allow)
    }

    public func openPairingOffer(_ request: PairingInviteRequest) async throws -> PairingInvite {
        let session = try current()
        guard let host = session.pairing.withLock({ $0.host }) else {
            throw APIErrorBody(code: "pairing_unavailable", message: String(localized: "QR 페어링을 준비하지 못했습니다. 공유를 다시 시작하세요."))
        }
        guard (1...3600).contains(request.lifetimeSeconds) else { throw Self.invalid("제안의 수명은 1~3600초여야 합니다.") }
        let snapshot = await session.node.snapshot()
        guard snapshot.state == .running, !(snapshot.fqdn ?? "").isEmpty else {
            throw APIErrorBody(code: "not_running", message: String(localized: "이 Mac이 아직 tailnet에 연결되지 않았습니다."))
        }
        var authKey: String?
        var keyState = PairingInvite.AuthKey.none
        if let client = request.oauthClient {
            do {
                let issued = try await factory.issueKey(client, request.lifetimeSeconds)
                authKey = issued.key
                keyState = .included(expires: issued.expires)
            } catch {
                keyState = .failed(error)
                session.log.line("warn: 페어링 키를 만들지 못함(\(Self.logName(error)))")
            }
        }
        // 키를 만드는 동안 화면이 다른 동선으로 바꿨으면 아무것도 닫거나 열지 않는다.
        try Task.checkCancellation()
        // 설치 페이지 코드는 닫는다: 페어링은 한 번에 하나다.
        session.logic.closePairingCode()
        let offer: PairingOffer
        do {
            offer = try await host.open(lifetimeSeconds: request.lifetimeSeconds, authKey: authKey)
        } catch .invalidAuthKey {
            // 발급된 키를 링크에 실을 수 없다(감싼 키 등). 키 없이 연다.
            session.log.line("warn: 페어링 키를 링크에 실을 수 없어 키 없이 엶")
            keyState = .failed(.invalidResponse)
            authKey = nil
            do {
                offer = try await host.open(lifetimeSeconds: request.lifetimeSeconds, authKey: nil)
            } catch {
                throw Self.offerError(error)
            }
        } catch {
            throw Self.offerError(error)
        }
        session.log.line("info: 페어링 QR을 엶(\(authKey == nil ? "키 없음" : "키 있음"))")
        let (base, shareable) = Self.offerLinkBase(layout.pairingLinkBase, carriesKey: authKey != nil)
        return PairingInvite(link: shareable ? offer.url(base: base) : nil, qrImage: offer.qrCode(base: base),
                             expiresAt: offer.expires, authKey: keyState, tailnetLockEnabled: snapshot.tailnetLockEnabled)
    }

    /// 제안 링크·QR의 앞부분과 링크를 내보내도 되는지. 연결 도메인 주소가 있으면 그 https 주소로 내고 링크도 보인다.
    /// 없으면 `remotedebug://pair`이고, 인증 키를 실은 제안은 링크로 내보내지 않는다: 사용자 지정 스킴은 같은 스킴을 선언한
    /// 다른 앱이 받을 수 있다. QR만 보인다(iPhone 앱 안 카메라로 읽는다).
    static func offerLinkBase(_ linkBase: PairingLinkBase?, carriesKey: Bool) -> (base: URL, shareable: Bool) {
        if let linkBase { return (linkBase.url, true) }
        return (pairingBaseURL, !carriesKey)
    }

    public func closePairingOffer() async {
        guard let session = try? current() else { return }
        await session.pairing.withLock { $0.host }?.closeCurrentOffer()
    }

    public func checkOAuthClient(_ client: TailscaleAPI.OAuthClient) -> TailscaleAPI.Failure? {
        PairingKeys.check(client)
    }

    public func setDirect(_ on: Bool) async throws {
        let session = try current()
        if !on {
            let listener = session.lock.withLock { value -> HTTPListener? in
                defer { value.directListener = nil }
                return value.directListener
            }
            listener?.close()
            infoBox()?.setDirectOn(false)
            return
        }
        if session.lock.withLock({ $0.stopped }) { throw APIErrorBody(code: "not_running", message: String(localized: "노드가 종료되었습니다.")) }
        if session.lock.withLock({ $0.directListener != nil }) { return }
        let identity: DirectIdentity
        if let loaded = session.lock.withLock({ $0.direct }) {
            identity = loaded
        } else {
            do {
                identity = try DirectIdentity(directory: session.directDirectory)
            } catch {
                throw APIErrorBody(code: "internal", message: String(localized: "직접 연결 키를 준비하지 못했습니다."))
            }
            session.lock.withLock { $0.direct = identity }
            shared.withLock { $0.directEverOn = true }
        }
        infoBox()?.setDirect(identity)
        let listener: HTTPListener
        do {
            listener = try await DirectListener.start(identity: identity, handler: session.logic, loopbackOnly: directLoopbackOnly)
        } catch {
            throw APIErrorBody(code: "internal", message: String(localized: "직접 연결 포트를 열지 못했습니다."))
        }
        let keep = session.lock.withLock { value -> Bool in
            guard !value.stopped, value.directListener == nil else { return false }
            value.directListener = listener
            return true
        }
        if !keep { listener.close() }
        infoBox()?.setDirectOn(keep)
    }

    // MARK: QR·링크 페어링

    /// 노드에 여는 쪽을 붙이고 듣기 시작한다. 붙이지 못해도 공유는 계속된다(설치 페이지 코드는 쓸 수 있다).
    private func attachPairing(_ session: Session, stateDirectory: URL) async {
        let directory = layout.pairingDirectory ?? stateDirectory.appending(path: "pairing", directoryHint: .isDirectory)
        guard layout.pairingPort != 0, Int(layout.pairingPort) != session.config.port else {
            session.log.line("warn: 페어링 포트가 호스트 포트와 같아 QR 페어링을 붙이지 않음")
            return
        }
        let host: (any PairingHosting)?
        do {
            host = try await factory.makePairing(session.node, layout.pairingPort, directory) { [weak self, weak session] request in
                guard let self, let session else { return false }
                return await self.offerDecision(session, request)
            }
        } catch {
            session.log.line("warn: QR 페어링을 준비하지 못함(\(Self.pairingLogName(error)))")
            broadcast(run: session.run, .log(LogEvent(level: "warn", message: String(localized: "QR 페어링을 준비하지 못했습니다. 설치 페이지 코드로는 페어링할 수 있습니다."))))
            return
        }
        guard let host else { return }
        let task = Task { [weak self] in
            do {
                try await host.runListener()
            } catch {
                guard !Task.isCancelled else { return }
                session.log.line("warn: 페어링 포트를 듣지 못함(\(Self.pairingLogName(error)))")
                self?.broadcast(run: session.run, .log(LogEvent(level: "warn", message: String(localized: "QR 페어링 포트를 열지 못했습니다. 공유를 다시 시작하세요."))))
            }
        }
        session.pairing.withLock { $0 = (host, task) }
    }

    /// `PairingHost`의 `decide`: 화면에 승인 요청을 내고 사용자의 답을 기다린다. iPhone이 끊거나 120초가 지나 이 Task가
    /// 취소되면 곧 거절로 돌아가고, 화면의 요청은 만료로 내린다.
    private func offerDecision(_ session: Session, _ request: OfferPairingRequest) async -> Bool {
        let id = HostIDs.newID("pr_")
        let event = PairRequestEvent(requestId: id, deviceName: request.deviceName, nodeName: request.peer.nodeName,
                                     loginName: request.peer.loginName, expiresAt: Date().addingTimeInterval(Self.offerRequestSeconds),
                                     confirmationCode: request.confirmationCode)
        session.log.line("info: QR 페어링 요청을 받음")
        let (allowed, cancelled) = await session.offers.wait(id: id, request: .init(peer: request.peer, name: request.deviceName)) {
            session.logic.noteOfferPairingRequest(event)
        }
        if cancelled {
            session.log.line("info: QR 페어링 요청이 답 없이 끝남")
            session.logic.finishOfferPairingRequest(requestID: id, state: .expired)
        }
        return allowed
    }

    /// 화면의 허용·거부. 허용하면 `PairingHost`가 이번 요청으로 짝을 저장하기를 기다려 허용 목록에 넣는다. 저장되지 않았거나
    /// (iPhone이 그사이 끊음, 노드 신원이 바뀜, 저장 실패) 그사이 공유가 멈췄으면 넣지 않고 던진다.
    private func decideOffer(_ session: Session, requestID: String, allow: Bool) async throws -> DeviceEntry? {
        guard allow else {
            guard session.offers.answer(id: requestID, allow: false) != nil else { throw Self.unknownRequest }
            session.offers.finish(requestID)
            session.logic.finishOfferPairingRequest(requestID: requestID, state: .denied)
            session.log.line("info: QR 페어링 요청을 거절함")
            return nil
        }
        guard let pending = session.offers.waitingRequest(id: requestID) else { throw Self.unknownRequest }
        let host = session.pairing.withLock { $0.host }
        // 허용하기 전의 그 노드 기록. 허용한 뒤 이 기록이 바뀌어야 이번 요청이 저장된 것이다(같은 노드의 예전 짝과 가린다).
        let before = await host?.pairedAt(stableID: pending.peer.stableID)
        guard let request = session.offers.answer(id: requestID, allow: true) else { throw Self.unknownRequest }
        let task = session.lock.withLock { value -> Task<DeviceEntry?, any Error>? in
            guard !value.stopped else { return nil }
            let task = Task { [self] in
                try await self.admitOffer(session, requestID: requestID, request: request, host: host, before: before)
            }
            value.admissions[requestID] = task
            return task
        }
        guard let task else {
            session.offers.finish(requestID)
            session.logic.finishOfferPairingRequest(requestID: requestID, state: .expired)
            throw Self.stoppedError
        }
        defer { session.lock.withLock { _ = $0.admissions.removeValue(forKey: requestID) } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// 허용한 요청의 마무리: 짝 목록의 그 노드 기록이 `before`에서 바뀌기를 기다려 허용 목록에 넣는다.
    /// 취소되거나(공유를 멈춤) 기한이 지나면 넣지 않는다. 늦게 저장된 짝은 짝 목록 맞추기가 지운다.
    private func admitOffer(_ session: Session, requestID: String, request: PendingOffers.Request, host: (any PairingHosting)?,
                            before: Date?) async throws -> DeviceEntry? {
        defer { session.offers.finish(requestID) }
        let deadline = ContinuousClock.now + offerSaveTimeout
        var saved = false
        while let host, !Task.isCancelled, ContinuousClock.now < deadline {
            if let pairedAt = await host.pairedAt(stableID: request.peer.stableID), pairedAt != before {
                saved = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if Task.isCancelled || session.lock.withLock({ $0.stopped }) {
            session.log.line("info: QR 페어링을 끝내기 전에 공유가 멈춤")
            session.logic.finishOfferPairingRequest(requestID: requestID, state: .expired)
            throw Self.stoppedError
        }
        guard saved else {
            session.log.line("warn: QR 페어링을 허용했지만 짝이 저장되지 않음")
            session.logic.finishOfferPairingRequest(requestID: requestID, state: .expired)
            throw APIErrorBody(code: "pair_incomplete",
                               message: String(localized: "iPhone과 페어링을 끝내지 못했습니다. iPhone이 연결을 끊었을 수 있습니다. 새 QR로 다시 시도하세요."))
        }
        session.log.line("info: QR 페어링을 허용함")
        return session.logic.admitOfferPairedDevice(requestID: requestID, peer: request.peer, name: request.name)
    }

    /// 짝 목록을 허용 목록(로직의 기기)의 부분집합으로 맞춘다. 허용 목록에 없는 짝은 지운다(허용한 뒤 저장을 기다리는 짝은 둔다).
    /// 허용 목록을 받은 뒤 그 목록이 바뀔 때와 상태를 읽을 때마다 부른다(기한이 지난 뒤 늦게 저장된 짝도 지운다).
    private func reconcilePairing(_ session: Session) async {
        guard let host = session.pairing.withLock({ $0.host }) else { return }
        await session.reconciling.lock()
        defer { session.reconciling.unlock() }
        // 허용 중인 노드를 허용 목록보다 먼저 읽는다. 허용 목록에 넣은 뒤에야 허용 중에서 빠지므로, 둘 중 어디에도 없는 짝만 지운다.
        let admitting = session.offers.admittingStableIDs
        let allowed = Set(session.logic.deviceStableIDs())
        for id in await host.pairedStableIDs() where !allowed.contains(id) && !admitting.contains(id) {
            do {
                try await host.removePeer(stableID: id)
            } catch {
                session.log.line("warn: 허용 목록에서 뺀 기기를 짝 목록에서 지우지 못함")
            }
        }
    }

    private func closeOfferInBackground(run: Int) {
        guard let session = shared.withLock({ $0.session }), session.run == run,
              let host = session.pairing.withLock({ $0.host }) else { return }
        Task { await host.closeCurrentOffer() }
    }

    private static var unknownRequest: APIErrorBody {
        APIErrorBody(code: "bad_request", message: String(localized: "이미 처리되었거나 만료된 페어링 요청입니다."))
    }

    private static var stoppedError: APIErrorBody {
        APIErrorBody(code: "not_running", message: String(localized: "공유가 꺼져 있습니다."))
    }

    private static func offerError(_ error: PairingError) -> APIErrorBody {
        switch error {
        case .notRunning: APIErrorBody(code: "not_running", message: String(localized: "이 Mac이 아직 tailnet에 연결되지 않았습니다."))
        default: APIErrorBody(code: "internal", message: String(localized: "페어링 QR을 만들지 못했습니다."))
        }
    }

    /// 로그에 쓰는 이름. 값(경로·이름·주소)은 싣지 않는다.
    static func pairingLogName(_ error: any Error) -> String {
        guard let error = error as? PairingError else { return "other" }
        switch error {
        case .invalidConfiguration: return "invalidConfiguration"
        case .invalidAuthKey: return "invalidAuthKey"
        case .notRunning: return "notRunning"
        case .storeUnreadable: return "storeUnreadable"
        case .storeInUse: return "storeInUse"
        case .storeWriteFailed: return "storeWriteFailed"
        default: return "other"
        }
    }

    static func logName(_ failure: TailscaleAPI.Failure) -> String {
        switch failure {
        case .badClient: "badClient"
        case .badTags: "badTags"
        case .clientRejected: "clientRejected"
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .http(let status): "http(\(status))"
        case .invalidResponse: "invalidResponse"
        case .network: "network"
        case .cancelled: "cancelled"
        }
    }

    // MARK: 내부

    private let sessionInfo = Mutex<InfoBox?>(nil)

    private func infoBox() -> InfoBox? { sessionInfo.withLock { $0 } }

    /// 로직이 동기로 읽는 값(`/v1/info`, 직접 연결 정보).
    private final class InfoBox: Sendable {
        let info = Mutex<(fqdn: String, selfID: String, direct: DirectIdentity?, directOn: Bool)>(("", "", nil, false))

        var fqdn: String { info.withLock { $0.fqdn } }

        func info(config: CoreConfig) -> HostLogic.Info {
            let (fqdn, selfID, direct) = info.withLock { ($0.fqdn, $0.selfID, $0.direct) }
            // tailnet 노드가 뜨기 전에는 직접 연결 신원이 기억한 hostId로 답한다.
            let hostID = selfID.isEmpty ? (direct?.hostID ?? "") : HostIDs.hostID(stableID: selfID)
            let display = config.hostDisplayName.flatMap { $0.isEmpty ? nil : $0 } ?? config.hostname
            return HostLogic.Info(hostID: hostID, hostName: display, fqDN: fqdn, appVersion: config.appVersion ?? "")
        }

        func directInfo() -> HostLogic.DirectInfo? {
            info.withLock { value in
                guard value.directOn, let direct = value.direct else { return nil }
                return HostLogic.DirectInfo(id: direct.id, port: direct.port, spki: direct.spki)
            }
        }

        func setDirect(_ identity: DirectIdentity) {
            let selfID = info.withLock { value -> String in
                value.direct = identity
                return value.selfID
            }
            if !selfID.isEmpty { identity.setHostID(HostIDs.hostID(stableID: selfID)) }
        }

        func setDirectOn(_ on: Bool) { info.withLock { $0.directOn = on } }

        func update(fqdn: String?, selfID: String?) {
            let direct = info.withLock { value -> DirectIdentity? in
                if let fqdn { value.fqdn = fqdn }
                if let selfID { value.selfID = selfID }
                return value.direct
            }
            if let selfID, !selfID.isEmpty { direct?.setHostID(HostIDs.hostID(stableID: selfID)) }
        }
    }

    private func current() throws -> Session {
        guard let session = shared.withLock({ $0.session }), !session.lock.withLock({ $0.stopped }) else {
            throw APIErrorBody(code: "not_running", message: String(localized: "공유가 꺼져 있습니다."))
        }
        return session
    }

    private static func invalid(_ message: String) -> APIErrorBody {
        APIErrorBody(code: "invalid_config", message: message)
    }

    /// 로직의 완전한 사건 → 모델로 가는 이벤트. RDModels의 JSON 모양에 없는 값을 채운다.
    static func coreEvent(_ detail: HostLogic.EmittedEvent) -> CoreEvent {
        switch detail.event {
        case .deviceCrash(var event):
            event.receivedAt = detail.receivedAt
            return .deviceCrash(event)
        case .agentRequest(var event):
            event.nodeName = detail.nodeName ?? ""
            return .agentRequest(event)
        case .agentCancel(var event):
            event.deviceId = detail.deviceID ?? ""
            return .agentCancel(event)
        default:
            return detail.event
        }
    }

    /// `run` 실행의 이벤트를 구독자에게 보낸다. 그 실행이 이미 끝났으면(멈춤, 다시 시작) 버린다.
    private func broadcast(run: Int, _ event: CoreEvent) {
        let subscribers = shared.withLock { $0.session?.run == run ? Array($0.subscribers.values) : [] }
        for continuation in subscribers { continuation.yield(event) }
    }

    /// 노드 층의 사건. URL·이름·키는 로그로 보내지 않는다(상태로만 간다).
    private func nodeEvent(_ event: HostEvent, run: Int) {
        guard let session = shared.withLock({ $0.session }), session.run == run else { return }
        switch event {
        case .certificate(_, _, let notAfter, _):
            session.log.line("info: 인증서: \(RDTimestamp.string(notAfter))까지")
            broadcast(run: run, .log(LogEvent(level: "info", message: String(localized: "HTTPS 인증서를 받았습니다."))))
        case .serverFailed(let kind):
            session.log.line("warn: 루프백 리스너를 띄우지 못함(\(kind))")
            broadcast(run: run, .log(LogEvent(level: "warn", message: CoreStatusMapping.listenerPrefix + String(localized: "루프백 리스너를 띄우지 못했습니다."))))
        case .defaultInterface(let name):
            session.log.line("info: 기본 인터페이스: \(name)")
        case .listening(let port):
            session.log.line("info: tailnet \(port) 포트를 듣는다")
        case .nodeState, .running, .tailnetLock, .certificateStatus, .serverStarted, .connection, .connectionRejected:
            break
        }
    }

    /// `run()`이 실패로 끝났다. 다시 켜지 않는다.
    private func nodeEnded(_ session: Session, error: any Error) {
        let end = NodeEnd(error)
        let wasStopped = session.lock.withLock { value -> Bool in
            if !value.stopped { value.phase = .ended(end) }
            return value.stopped
        }
        guard !wasStopped else { return }
        session.log.line("error: 노드가 끝남(\(end.logName))")
        let message = end == .nodeKeyExpired ? String(localized: "tailnet 로그인이 만료됐습니다. 공유를 다시 시작해 로그인하세요.") : (end.message ?? "")
        broadcast(run: session.run, .log(LogEvent(level: end == .nodeKeyExpired ? "warn" : "error", message: message)))
    }

    private func refresh(_ session: Session) async {
        let snapshot = await session.node.snapshot()
        let certificate = await session.node.certificateSnapshot()
        let peerPaths = await session.node.peerPaths(to: session.logic.deviceStableIDs())
        session.lock.withLock { value in
            value.snapshot = snapshot
            value.certificate = certificate
            value.peerPaths = peerPaths
        }
        infoBox()?.update(fqdn: snapshot.fqdn, selfID: snapshot.stableID)
    }

    private func makeStatus(_ session: Session) -> CoreStatus {
        let (phase, snapshot, certificate, peerPaths, direct, listening) = session.lock.withLock {
            ($0.phase, $0.snapshot, $0.certificate, $0.peerPaths, $0.direct, $0.directListener != nil && !$0.stopped)
        }
        return CoreStatusMapping.status(CoreStatusMapping.Input(
            phase: phase, node: snapshot, certificate: certificate, serving: session.node.serving,
            hostname: session.config.hostname, counts: session.logic.counts(),
            direct: direct.map { DirectStatus(listening: listening, port: $0.port, id: $0.id) },
            peerPaths: peerPaths, rssMiB: Self.residentMiB()
        ))
    }

    /// 상태를 읽어 바뀌었으면 상태 이벤트를 내고, 로직을 쓸고, 인증서 실패·lock 대기·첫 실행을 알린다.
    private func monitor(_ session: Session) async {
        var lastDomains: [String]?
        while !Task.isCancelled {
            await refresh(session)
            session.logic.sweep()
            if session.lock.withLock({ $0.devicesApplied && !$0.stopped }) { await reconcilePairing(session) }
            let status = makeStatus(session)
            let (snapshot, certificate) = session.lock.withLock { ($0.snapshot, $0.certificate) }

            // cert 도메인이 생기거나 바뀌면 발급을 곧바로 다시 본다(사용자가 HTTPS를 켰을 수 있다).
            if snapshot.state == .running, lastDomains != snapshot.certDomains {
                if lastDomains != nil { await session.node.retryCertificates() }
                lastDomains = snapshot.certDomains
            }
            noteState(session, snapshot.state)
            noteCertificate(session, failure: certificate?.lastFailure)
            noteLock(session, waiting: snapshot.state == .running && snapshot.signingRequest != nil)
            if snapshot.state == .running {
                let first = session.lock.withLock { value -> Bool in
                    defer { value.reachedRunning = true }
                    return !value.reachedRunning
                }
                if first, let legacy = layout.legacyStateDirectory {
                    LegacyState.remove(legacy, keepingDirectIdentityIn: session.directDirectory, log: session.log)
                }
            }

            let comparable = CoreStatusMapping.comparable(status)
            let changed = session.lock.withLock { value -> Bool in
                defer { value.lastEmitted = comparable }
                return value.lastEmitted != comparable
            }
            if changed { broadcast(run: session.run, .state(status)) }
            let running = status.backendState == .running
            try? await Task.sleep(for: running ? pollIntervals.running : pollIntervals.starting)
        }
    }

    /// 노드 상태가 바뀌면 이름만 로그에 쓴다(로그인 URL은 쓰지 않는다).
    private func noteState(_ session: Session, _ state: NodeState) {
        let name = Self.stateName(state)
        let changed = session.lock.withLock { value -> Bool in
            defer { value.loggedState = name }
            return value.loggedState != name
        }
        if changed { session.log.line("info: 노드 상태: \(name)") }
    }

    private func noteCertificate(_ session: Session, failure: CertificateFailure?) {
        let changed = session.lock.withLock { value -> Bool in
            defer { value.lastFailure = failure }
            return value.lastFailure != failure
        }
        guard changed, let failure, failure != .nodeNotRunning else { return }
        let name = CoreStatusMapping.logName(failure)
        session.log.line("warn: 인증서를 받지 못함(\(name))")
        broadcast(run: session.run, .log(LogEvent(level: "warn", message: String(localized: "TLS 인증서를 받지 못했습니다(\(name))."))))
    }

    private func noteLock(_ session: Session, waiting: Bool) {
        let was = session.lock.withLock { value -> Bool in
            defer { value.lockWaiting = waiting }
            return value.lockWaiting
        }
        if was == waiting { return }
        let text = waiting ? "tailnet lock: waiting for a signature" : "tailnet lock: this node is signed"
        session.log.line("info: \(text)")
        broadcast(run: session.run, .log(LogEvent(level: "info", message: text)))
    }

    static func stateName(_ state: NodeState) -> String {
        switch state {
        case .starting: "starting"
        case .needsLogin: "needsLogin"
        case .needsMachineAuth: "needsMachineAuth"
        case .running: "running"
        }
    }

    static func logName(_ error: NodeError) -> String {
        switch error {
        case .control(let control):
            switch control {
            case .invalidConfiguration: "control.invalidConfiguration"
            case .storage: "control.storage"
            case .connection: "control.connection"
            case .http(let status): "control.http(\(status))"
            case .authKeyRejected: "control.authKeyRejected"
            case .registrationRejected: "control.registrationRejected"
            case .nodeKeyExpired: "control.nodeKeyExpired"
            }
        case .invalidConfiguration: "invalidConfiguration"
        case .udpUnavailable: "udpUnavailable"
        case .stateDirectoryInUse: "stateDirectoryInUse"
        case .tunnelDeviceClosed: "tunnelDeviceClosed"
        }
    }

    /// 이 프로세스의 물리 메모리 사용량(MiB). 예전 Go 코어가 같은 값을 보고하던 자리.
    static func residentMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10
    }

    /// 파일 복사가 들어 있는 로직 호출은 협력 스레드 풀을 오래 막지 않게 떼어 돌린다.
    private static func detached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    /// 기한 안에 끝나면 그 값, 아니면 nil. 기한이 지나도 일은 뒤에서 마저 끝난다(취소를 알린다).
    private static func withDeadline<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// 비동기 작업을 한 번에 하나씩(start·stop·logOut).
final class SerialLock: Sendable {
    private let state = Mutex<(busy: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func lock() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { value -> Bool in
                if value.busy {
                    value.waiters.append(continuation)
                    return false
                }
                value.busy = true
                return true
            }
            if acquired { continuation.resume() }
        }
    }

    func unlock() {
        let next = state.withLock { value -> CheckedContinuation<Void, Never>? in
            if value.waiters.isEmpty {
                value.busy = false
                return nil
            }
            return value.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// 예전 Go 코어가 남긴 상태 폴더(`<root>/state`). 옮기지 않는다: 직접 연결 신원만 새 자리로 옮기고 나머지는 지운다.
enum LegacyState {
    static let directFiles = [DirectIdentity.stateFile, DirectIdentity.certificateFile, DirectIdentity.keyFile]

    /// 새 자리에 직접 연결 신원이 없고 옛 자리에 셋 다 있으면 복사한다(옛 파일은 지울 때까지 둔다).
    static func adoptDirectIdentity(from legacy: URL, to directory: URL) {
        let fm = FileManager.default
        guard legacy.standardizedFileURL != directory.standardizedFileURL else { return }
        guard !directFiles.contains(where: { fm.fileExists(atPath: directory.appending(path: $0).path) }) else { return }
        guard directFiles.allSatisfy({ fm.fileExists(atPath: legacy.appending(path: $0).path) }) else { return }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for name in directFiles {
                try fm.copyItem(at: legacy.appending(path: name), to: directory.appending(path: name))
                chmod(directory.appending(path: name).path, 0o600)
            }
        } catch {
            for name in directFiles { try? fm.removeItem(at: directory.appending(path: name)) }
        }
    }

    /// 직접 연결 신원을 먼저 옮기고(이미 옮겼으면 그대로) 옛 폴더를 지운다.
    static func remove(_ legacy: URL, keepingDirectIdentityIn directory: URL, log: CoreLogFile) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), legacy.standardizedFileURL != directory.standardizedFileURL else { return }
        adoptDirectIdentity(from: legacy, to: directory)
        let hasLegacyDirect = directFiles.allSatisfy { fm.fileExists(atPath: legacy.appending(path: $0).path) }
        let adopted = directFiles.allSatisfy { fm.fileExists(atPath: directory.appending(path: $0).path) }
        if hasLegacyDirect, !adopted {
            log.line("warn: 옛 노드 상태 폴더: 직접 연결 신원을 옮기지 못해 지우지 않음")
            return
        }
        do {
            try fm.removeItem(at: legacy)
            log.line("info: 옛 노드 상태 폴더를 지움")
        } catch {
            log.line("warn: 옛 노드 상태 폴더를 지우지 못함")
        }
    }
}

/// `CoreConfig.logPath`의 진단 로그. 5MiB에 닿으면 `<경로>.1`로 한 번 돌린다(예전 Go 코어의 로그와 같은 규칙).
/// URL·키·이름·주소는 쓰지 않는다(부르는 쪽이 종류만 넘긴다).
final class CoreLogFile: Sendable {
    static let maxBytes = 5 << 20
    private let path: String
    private let lock = Mutex(())

    init(path: String) { self.path = path }

    func line(_ text: String) {
        guard !path.isEmpty else { return }
        let stamp = RDTimestamp.string(Date())
        let bytes = Array("\(stamp) \(text)\n".utf8)
        lock.withLock { _ in
            var info = stat()
            if stat(path, &info) == 0, info.st_size + off_t(bytes.count) > off_t(Self.maxBytes) {
                rename(path, path + ".1")
            }
            let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return }
            _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            close(descriptor)
        }
    }
}
