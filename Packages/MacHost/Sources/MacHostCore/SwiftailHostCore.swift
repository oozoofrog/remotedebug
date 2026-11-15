// SwiftailHostCore — Swiftail 노드(SwiftailHostServer)와 호스트 로직(RDHostLogic)을 MacHostKit의 `HostCore`로 묶는다.
// Go 코어(`core/internal/node`의 host 모드)가 하던 일을 옮겼다.
//
// - 노드: `start`가 `SwiftailHostRuntime`을 띄우고 `stop`이 그 Task를 취소한 뒤 노드와 인증서 관리자가 끝나기를 기다린다.
//   `run()`이 다시 켜도 소용없는 실패로 끝나면 다시 켜지 않는다(사용자가 공유를 다시 시작할 때까지 상태로만 알린다).
// - 로그인: `needsLogin(url)`의 URL은 상태(`authURL`)와 상태 이벤트로만 화면에 간다. 로그 파일과 로그 이벤트에는 쓰지 않는다.
//   `startInteractiveLogin()`은 부르지 않는다(이미 등록돼 있어도 새 node 키로 다시 등록한다. Swiftail 계약).
// - 상태 이벤트: 250ms(실행 전)·2초(실행 중)마다 상태를 읽어 바뀌었으면 낸다. 그때 로직의 `sweep()`도 한다
//   (Go `node.monitor`와 같은 간격: 페어링 요청·세션 만료, 오래된 기록·거부 기록·직접 연결 실패 차단 정리).
// - 로직의 사건은 완전한 형태(`eventDetails`)로 받아 RDModels 이벤트에 없는 값(크래시를 받은 시각, 에이전트 요청의 노드 이름,
//   멈춤 요청의 기기 id)을 채워 넘긴다. 로직이 잠금 안에서 낸 순서 그대로 구독자 버퍼에 동기로 들어간다.
// - `stop()`: 노드를 멈추고, 직접 연결 리스너를 닫고, 로직을 닫아(열린 세션의 `failed`, addenda C.3) 그 이벤트까지 넘긴 뒤
//   스트림을 끝낸다(`HostCore` 계약). 로직의 이벤트는 동기로 스트림 버퍼에 들어가므로 끝내기 전에 모두 들어 있다.
import Darwin
import Foundation
import MacHostKit
import RDHostLogic
import RDModels
import Swiftail
import SwiftailCertificates
import SwiftailHostServer
import Synchronization

public final class SwiftailHostCore: HostCore, Sendable {
    /// 저장 위치. 노드 상태는 `CoreConfig.stateDir`에 둔다.
    public struct Layout: Sendable {
        /// 직접 연결 신원 폴더. nil이면 `stateDir`(Go 코어와 같은 자리).
        public var directDirectory: URL?
        /// Go 코어의 노드 상태 폴더. 있으면 노드가 처음 `.running`이 된 뒤 지운다(직접 연결 신원은 먼저 옮긴다).
        public var legacyStateDirectory: URL?

        public init(directDirectory: URL? = nil, legacyStateDirectory: URL? = nil) {
            (self.directDirectory, self.legacyStateDirectory) = (directDirectory, legacyStateDirectory)
        }
    }

    /// 실행 하나의 것.
    private final class Session: Sendable {
        let config: CoreConfig
        let logic: HostLogic
        let node: any HostNodeLayer
        let log: CoreLogFile
        let stateDirectory: URL
        let directDirectory: URL
        let lock = Mutex(SessionState())
        let runTask = Mutex<Task<Void, Never>?>(nil)
        let monitorTask = Mutex<Task<Void, Never>?>(nil)

        init(config: CoreConfig, logic: HostLogic, node: any HostNodeLayer, log: CoreLogFile, stateDirectory: URL, directDirectory: URL) {
            (self.config, self.logic, self.node, self.log) = (config, logic, node, log)
            (self.stateDirectory, self.directDirectory) = (stateDirectory, directDirectory)
        }
    }

    private struct SessionState {
        var phase: NodePhase = .running
        var snapshot = NodeSnapshot()
        var certificate: CertificateSnapshot?
        var direct: DirectIdentity?
        var directListener: HTTPListener?
        var lastEmitted: CoreStatus?
        var lastFailure: CertificateFailure?
        var lockWaiting = false
        var loggedState: String?
        var reachedRunning = false
        var stopped = false
    }

    private struct Shared {
        var session: Session?
        var subscribers: [UUID: AsyncStream<CoreEvent>.Continuation] = [:]
        /// 이번 앱 실행에서 직접 연결을 한 번이라도 켰다(상태의 `direct`).
        var directEverOn = false
    }

    private let layout: Layout
    private let factory: HostNodeFactory
    private let shared = Mutex(Shared())
    private let lifecycle = SerialLock()
    /// 상태를 읽는 간격(실행 전, 실행 중).
    let pollIntervals: (starting: Duration, running: Duration)
    /// 직접 연결 리스너를 루프백에만 묶는다(시험).
    let directLoopbackOnly: Bool

    public convenience init(layout: Layout = Layout()) {
        self.init(layout: layout, factory: .swiftail)
    }

    /// 앱의 저장 위치로.
    public convenience init(paths: HostPaths) {
        self.init(layout: Layout(directDirectory: paths.directDir, legacyStateDirectory: paths.legacyStateDir))
    }

    init(layout: Layout, factory: HostNodeFactory, pollIntervals: (starting: Duration, running: Duration) = (.milliseconds(250), .seconds(2)),
         directLoopbackOnly: Bool = false) {
        self.layout = layout
        self.factory = factory
        self.pollIntervals = pollIntervals
        self.directLoopbackOnly = directLoopbackOnly
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
                eventDetails: { [weak self] detail in self?.broadcast(Self.coreEvent(detail)) }
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
            layer = try factory.make(configuration, logic, { [weak self] event in self?.nodeEvent(event) })
        } catch {
            logic.close()
            throw Self.invalid(String(localized: "노드 설정이 올바르지 않습니다."))
        }
        let session = Session(config: config, logic: logic, node: layer, log: log, stateDirectory: stateDirectory,
                              directDirectory: directDirectory)
        sessionInfo.withLock { $0 = infoBox }
        shared.withLock { $0.session = session }
        log.line("info: 시작: Swiftail 노드(\(config.listenTLS ? "TLS" : "평문") \(config.port))")

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
                broadcast(.log(LogEvent(level: "warn", message: String(localized: "직접 연결 리스너를 열지 못했습니다."))))
            }
        }
    }

    public func stop() async {
        await lifecycle.lock()
        defer { lifecycle.unlock() }
        guard let session = shared.withLock({ $0.session }) else { return }
        session.lock.withLock { $0.stopped = true }
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
        try current().logic.setDevices(devices)
    }

    public func openPairing(ttlSeconds: Int) async throws -> PairingCode {
        let code = try current().logic.openPairing(ttlSeconds: ttlSeconds)
        return PairingCode(code: code.code, expiresAt: code.expiresAt)
    }

    public func decidePairing(requestID: String, allow: Bool) async throws -> DeviceEntry? {
        try current().logic.decidePairing(requestID: requestID, allow: allow)
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

    private func broadcast(_ event: CoreEvent) {
        let subscribers = shared.withLock { Array($0.subscribers.values) }
        for continuation in subscribers { continuation.yield(event) }
    }

    /// 노드 층의 사건. URL·이름·키는 로그로 보내지 않는다(상태로만 간다).
    private func nodeEvent(_ event: HostEvent) {
        guard let session = shared.withLock({ $0.session }) else { return }
        switch event {
        case .certificate(_, _, let notAfter, _):
            session.log.line("info: 인증서: \(RDTimestamp.string(notAfter))까지")
            broadcast(.log(LogEvent(level: "info", message: String(localized: "HTTPS 인증서를 받았습니다."))))
        case .serverFailed(let kind):
            session.log.line("warn: 루프백 리스너를 띄우지 못함(\(kind))")
            broadcast(.log(LogEvent(level: "warn", message: CoreStatusMapping.listenerPrefix + String(localized: "루프백 리스너를 띄우지 못했습니다."))))
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
        broadcast(.log(LogEvent(level: end == .nodeKeyExpired ? "warn" : "error", message: message)))
    }

    private func refresh(_ session: Session) async {
        let snapshot = await session.node.snapshot()
        let certificate = await session.node.certificateSnapshot()
        session.lock.withLock { value in
            value.snapshot = snapshot
            value.certificate = certificate
        }
        infoBox()?.update(fqdn: snapshot.fqdn, selfID: snapshot.stableID)
    }

    private func makeStatus(_ session: Session) -> CoreStatus {
        let (phase, snapshot, certificate, direct, listening) = session.lock.withLock {
            ($0.phase, $0.snapshot, $0.certificate, $0.direct, $0.directListener != nil && !$0.stopped)
        }
        return CoreStatusMapping.status(CoreStatusMapping.Input(
            phase: phase, node: snapshot, certificate: certificate, serving: session.node.serving,
            hostname: session.config.hostname, counts: session.logic.counts(),
            direct: direct.map { DirectStatus(listening: listening, port: $0.port, id: $0.id) },
            rssMiB: Self.residentMiB()
        ))
    }

    /// 상태를 읽어 바뀌었으면 상태 이벤트를 내고, 로직을 쓸고, 인증서 실패·lock 대기·첫 실행을 알린다.
    private func monitor(_ session: Session) async {
        var lastDomains: [String]?
        while !Task.isCancelled {
            await refresh(session)
            session.logic.sweep()
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
            if changed { broadcast(.state(status)) }
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
        broadcast(.log(LogEvent(level: "warn", message: String(localized: "TLS 인증서를 받지 못했습니다(\(name))."))))
    }

    private func noteLock(_ session: Session, waiting: Bool) {
        let was = session.lock.withLock { value -> Bool in
            defer { value.lockWaiting = waiting }
            return value.lockWaiting
        }
        if was == waiting { return }
        let text = waiting ? "tailnet lock: waiting for a signature" : "tailnet lock: this node is signed"
        session.log.line("info: \(text)")
        broadcast(.log(LogEvent(level: "info", message: text)))
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

    /// 이 프로세스의 물리 메모리 사용량(MiB). Go `memstat.RSSMiB` 자리.
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

/// Go 코어의 상태 폴더(`<root>/state`). 옮기지 않는다: 직접 연결 신원만 새 자리로 옮기고 나머지는 지운다.
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

/// `CoreConfig.logPath`의 진단 로그. 5MiB에 닿으면 `<경로>.1`로 한 번 돌린다(Go 코어와 같다).
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
