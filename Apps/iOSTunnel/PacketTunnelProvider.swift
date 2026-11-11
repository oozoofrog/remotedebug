import Foundation
import Network
import NetworkExtension
import os
import RDCoreBridge
import RDModels

/// tailnet 패킷 터널(docs/tunnel.md "터널 확장(Swift)의 책임").
///
/// - 패킷은 코어(Go)가 utun fd로 직접 읽고 쓴다. 이 클래스는 `packetFlow`를 쓰지 않는다.
/// - `rd_start`·`rd_stop`은 `coreQueue`(직렬)에서만 부른다.
/// - 시작·종료 순서는 `TunnelLifecycle`이 정한다. 시작 중에 온 종료 요청은 새 노드를 멈추고 시작을 실패시킨다.
/// - 그 밖의 변하는 상태는 `TunnelRuntime`(잠금)에 둔다. NE는 이 객체의 메서드를 여러 스레드에서 부른다.
/// - NE 경계를 넘기는 오류는 `TunnelProviderError`의 `NSError`다.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    static let mtu = 1280

    private let logger = Logger(subsystem: "com.oozoofrog.app.RemoteDebugPhone.Tunnel", category: "tunnel")
    private let coreQueue = DispatchQueue(label: "com.oozoofrog.app.RemoteDebugPhone.Tunnel.core")
    private let pathQueue = DispatchQueue(label: "com.oozoofrog.app.RemoteDebugPhone.Tunnel.path")
    private let runtime = TunnelRuntime()
    private let lifecycle = TunnelLifecycle<RDNode>()
    private let applier: SerialApplier<TunnelSettingsPlan>

    override init() {
        let box = ProviderBox()
        applier = SerialApplier { plan, done in
            guard let provider = box.provider else { return done() }
            provider.applyNow(plan, done: done)
        }
        super.init()
        box.provider = self
    }

    // MARK: 시작

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let generation = lifecycle.begin()
        runtime.reset()
        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        guard let config = TunnelProviderConfig(providerConfiguration: providerConfiguration) else {
            completionHandler(fail(.missingConfiguration, generation: generation))
            return
        }
        // 인증 키는 이 시작에만 쓰고 보관하지 않는다.
        let authKey = TunnelStartOptions.authKey(from: options) ?? ""
        Task {
            do {
                try await start(config: config, authKey: authKey, generation: generation)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    private func start(config: TunnelProviderConfig, authKey: String, generation: Int) async throws {
        let found: UTUNLocator.Found
        if let existing = UTUNLocator.find() {
            found = existing
        } else {
            // 첫 설정 전에는 utun이 없을 수 있다(실기기 확인 2). 자리표시 설정으로 만든 뒤 다시 찾는다.
            guard lifecycle.isCurrent(generation) else { throw stoppedDuringStart() }
            logger.log("utun이 없어 자리표시 설정을 먼저 적용합니다")
            do {
                try await setTunnelNetworkSettings(NetworkSettingsBuilder.make(SettingsTranslator.placeholder(mtu: Self.mtu)))
            } catch {
                logger.error("자리표시 설정 적용 실패: \(error.localizedDescription, privacy: .public)")
                // 종료 요청 때문에 실패한 경우는 `fail`이 stoppedDuringStart(코드 6)로 바꿔 돌려준다.
                throw fail(.placeholderFailed, generation: generation)
            }
            guard lifecycle.isCurrent(generation) else { throw stoppedDuringStart() }
            guard let created = UTUNLocator.find() else { throw fail(.utunNotFound, generation: generation) }
            found = created
        }
        guard lifecycle.isCurrent(generation) else { throw stoppedDuringStart() }
        logger.log("utun 확인: \(found.interfaceName, privacy: .public) fd=\(found.fd)")

        let node: RDNode
        do {
            node = try await onCoreQueue { [lifecycle, logger] in
                try lifecycle.startNode(generation: generation, start: {
                    let stateDir = try Self.prepareStateDirectory()
                    let coreConfig = CoreConfig(
                        mode: .tunnel,
                        stateDir: stateDir.path,
                        hostname: config.hostname,
                        authKey: authKey,
                        controlURL: config.controlURL,
                        goMemLimitMiB: config.goMemLimitMiB,
                        logPath: config.logging ? try Self.logFileURL().path : "",
                        utunFd: Int(found.fd),
                        mtu: Self.mtu,
                        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    )
                    return try RDNode.start(config: RDJSON.encoder().encode(coreConfig))
                }, stop: { started in
                    // 시작하는 동안 종료 요청이 왔다. 방금 만든 노드를 같은 큐에서 멈춘다.
                    logger.log("시작 중 종료 요청을 받아 새 노드를 멈춥니다")
                    Self.stopNode(started, logger: logger)
                })
            }
        } catch TunnelLifecycle<RDNode>.LifecycleError.stoppedDuringStart {
            throw stoppedDuringStart()
        } catch let error as RDCoreError {
            logger.error("코어 시작 실패: \(error.code, privacy: .public)")
            throw fail(.coreStart, generation: generation, detail: error.message)
        } catch {
            logger.error("코어 시작 실패: \(error.localizedDescription, privacy: .public)")
            throw fail(.coreStart, generation: generation, detail: error.localizedDescription)
        }

        startEventLoop(node, generation: generation)
        startPathMonitor(node, generation: generation)
        // 노드를 저장한 뒤 종료 요청이 왔으면 노드는 종료 쪽 장벽이 멈춘다. 시작을 성공으로 알리지 않는다.
        guard lifecycle.isCurrent(generation) else { throw stoppedDuringStart() }
        // Running을 기다리지 않는다. NeedsLogin이면 앱이 상태를 물어 authURL을 보여 준다.
        logger.log("코어 시작됨")
    }

    // MARK: 종료

    override func stopTunnel(with reason: NEProviderStopReason) async {
        logger.log("터널 종료 요청: 사유 \(reason.rawValue)")
        let (node, cleanups) = lifecycle.requestStop()
        applier.discardPending()
        for cleanup in cleanups { cleanup() }
        // 진행 중인 rd_start가 있으면 그것이 끝난 뒤에 실행된다(같은 직렬 큐).
        // 엔진 종료는 몇 초 걸릴 수 있으므로 메인 스레드가 아닌 직렬 큐에서 부른다.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            coreQueue.async { [lifecycle, logger] in
                lifecycle.drainOnCoreQueue(extra: node) { Self.stopNode($0, logger: logger) }
                continuation.resume()
            }
        }
    }

    private static func stopNode(_ node: RDNode, logger: Logger) {
        do { try node.stop() } catch { logger.error("rd_stop 실패: \(String(describing: error), privacy: .public)") }
    }

    // MARK: 앱 메시지

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let request = TunnelAppRequest.decode(messageData) else {
            return try? TunnelStatusReply(phase: lifecycle.phase, error: TunnelStatusReply.unknownCommand).encoded()
        }
        switch request.cmd {
        case .status:
            return try? statusReply().encoded()
        }
    }

    private func statusReply() -> TunnelStatusReply {
        var status = runtime.lastStatus
        if let node = lifecycle.currentNode, let data = try? node.status(),
           let fresh = try? RDJSON.decoder().decode(CoreStatus.self, from: data) {
            status = fresh
            runtime.setStatus(fresh)
        }
        return TunnelStatusReply.make(
            phase: lifecycle.phase,
            status: status,
            physFootprintMiB: ProcessMemory.physFootprintMiB(),
            lastError: runtime.lastError
        )
    }

    // MARK: 이벤트

    private func startEventLoop(_ node: RDNode, generation: Int) {
        // RDNode.events()는 rd_next_event를 전용 스레드에서 돈다.
        let stream = node.events()
        let task = Task.detached { [weak self] in
            for await data in stream {
                guard let self else { return }
                self.handleEvent(data)
            }
        }
        // 그사이 종료 요청이 왔으면 바로 끊는다.
        if !lifecycle.attach(generation: generation, cleanup: { task.cancel() }) { task.cancel() }
    }

    private func handleEvent(_ data: Data) {
        let event: CoreEvent
        do {
            event = try RDJSON.decoder().decode(CoreEvent.self, from: data)
        } catch {
            logger.error("이벤트를 읽지 못했습니다")
            return
        }
        switch event {
        case .networkSettings(let settings):
            let plan = SettingsTranslator.translate(settings)
            logger.log("network-settings: IPv4 경로 \(plan.ipv4?.routes.count ?? 0)개, IPv6 경로 \(plan.ipv6?.routes.count ?? 0)개, DNS \(plan.dns == nil ? "없음" : "있음", privacy: .public), mtu \(plan.mtu)")
            applier.submit(plan)
        case .state(let status):
            runtime.setStatus(status)
            logger.log("상태: \(status.backendState.rawValue, privacy: .public)")
            if status.backendState == .error {
                runtime.setLastError(TunnelSecretRedactor.redact(status.errorMessage))
                if status.errorMessage == TunnelEngineMessages.tunDeviceClosed { engineDied() }
            }
        case .log(let entry):
            // 코어 로그는 비밀을 담지 않지만 내용은 공개 로그로 남기지 않는다.
            switch entry.level {
            case "error": logger.error("코어: \(entry.message, privacy: .private)")
            case "warn": logger.warning("코어: \(entry.message, privacy: .private)")
            default: logger.debug("코어: \(entry.message, privacy: .private)")
            }
        default:
            break
        }
    }

    /// 엔진이 utun을 닫았다. iOS가 VPN을 끊고 앱이 `NEVPNStatusDidChange`로 보고 다시 연결을 제안한다.
    private func engineDied() {
        guard runtime.markEngineDead() else { return }
        lifecycle.markFailed()
        logger.error("엔진이 멈춰 터널을 끝냅니다")
        applier.discardPending()
        cancelTunnelWithError(TunnelProviderError.engineStopped.nsError())
    }

    // MARK: 설정 적용

    fileprivate func applyNow(_ plan: TunnelSettingsPlan, done: @escaping @Sendable () -> Void) {
        let phase = lifecycle.phase
        guard phase == .running || phase == .starting else { return done() }
        let settings = NetworkSettingsBuilder.make(plan)
        setTunnelNetworkSettings(settings) { [logger] error in
            if let error {
                logger.error("네트워크 설정 적용 실패: \(error.localizedDescription, privacy: .public)")
            }
            done()
        }
    }

    // MARK: 기본 인터페이스

    private func startPathMonitor(_ node: RDNode, generation: Int) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathChanged(path, node: node)
        }
        // 시작하면 현재 경로가 곧바로 한 번 전달된다(시작 직후 한 번).
        // 먼저 시작하고 나중에 붙인다. 종료 쪽 `cancel()`이 `start` 앞서 실행되는 순서를 만들지 않는다.
        monitor.start(queue: pathQueue)
        // 그사이 종료 요청이 왔으면 바로 끊는다.
        if !lifecycle.attach(generation: generation, cleanup: { monitor.cancel() }) { monitor.cancel() }
    }

    private func pathChanged(_ path: NWPath, node: RDNode) {
        guard path.status == .satisfied, let name = Self.defaultInterfaceName(path) else { return }
        guard runtime.updateDefaultInterface(name) else { return }
        do {
            try node.setDefaultInterface(name)
            logger.log("기본 인터페이스: \(name, privacy: .public)")
        } catch {
            logger.error("기본 인터페이스 알림 실패: \(String(describing: error), privacy: .public)")
        }
    }

    /// 만족된 경로의 첫 물리 인터페이스(터널 자신 `utun*`·`ipsec*`·루프백 제외).
    static func defaultInterfaceName(_ path: NWPath) -> String? {
        path.availableInterfaces.first { interface in
            interface.type != .loopback && interface.type != .other
                && !interface.name.hasPrefix("utun") && !interface.name.hasPrefix("ipsec")
        }?.name
    }

    // MARK: 도움

    /// 이 세대의 시작 실패를 기록하고 NE 경계를 넘길 오류를 돌려준다.
    /// 종료 요청이 왔거나 새 시작이 들어온 뒤의 실패는 기록하지 않고 `stoppedDuringStart`(코드 6)로 돌려준다.
    private func fail(_ code: TunnelProviderError, generation: Int, detail: String? = nil) -> NSError {
        guard lifecycle.markFailed(generation: generation) else { return stoppedDuringStart() }
        let error = code.nsError(detail: detail)
        runtime.setLastError(error.localizedDescription)
        return error
    }

    private func stoppedDuringStart() -> NSError {
        logger.log("시작 중 종료 요청을 받아 시작을 그만둡니다")
        return TunnelProviderError.stoppedDuringStart.nsError()
    }

    private func onCoreQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            coreQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// 확장 컨테이너의 `Library/Application Support/RemoteDebug/tailscale`(첫 잠금 해제 후 접근 가능, 백업 제외).
    static func prepareStateDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try TunnelStorage.prepareStateDirectory(in: support)
    }

    static func logFileURL() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try TunnelStorage.prepareLogFile(in: caches)
    }
}

/// `init`에서 `self`를 넘기기 위한 약한 참조 상자.
private final class ProviderBox: @unchecked Sendable {
    weak var provider: PacketTunnelProvider?
}

/// 확장의 변하는 상태(시작·종료 순서는 `TunnelLifecycle`). 모든 접근은 잠금 안에서 한다.
private final class TunnelRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: CoreStatus?
    private var _lastError: String?
    private var _defaultInterface: String?
    private var _engineDead = false

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var lastStatus: CoreStatus? { locked { _status } }
    var lastError: String? { locked { _lastError } }

    func reset() {
        locked {
            _status = nil
            _lastError = nil
            _defaultInterface = nil
            _engineDead = false
        }
    }

    func setStatus(_ status: CoreStatus) { locked { _status = status } }
    func setLastError(_ message: String?) { locked { _lastError = message } }

    /// 이름이 바뀌었으면 기억하고 `true`.
    func updateDefaultInterface(_ name: String) -> Bool {
        locked {
            guard _defaultInterface != name else { return false }
            _defaultInterface = name
            return true
        }
    }

    /// 처음 표시하면 `true`.
    func markEngineDead() -> Bool {
        locked {
            guard !_engineDead else { return false }
            _engineDead = true
            _lastError = TunnelEngineMessages.tunDeviceClosed
            return true
        }
    }
}
