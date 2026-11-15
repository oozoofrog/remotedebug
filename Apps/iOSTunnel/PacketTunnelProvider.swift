import Foundation
import Network
import NetworkExtension
import os
import OSLog
import RDModels
import Swiftail

/// tailnet 패킷 터널(docs/tunnel.md "터널 확장(Swift)의 책임").
///
/// - 패킷은 Swiftail 노드가 utun fd로 직접 읽고 쓴다. 이 클래스는 `packetFlow`를 쓰지 않는다.
/// - 노드 시작·종료(`SwiftailTunnelEngine`)는 `coreQueue`(직렬)에서만 부른다.
/// - 시작·종료 순서는 `TunnelLifecycle`이 정한다. 시작 중에 온 종료 요청은 새 노드를 멈추고 시작을 실패시킨다.
/// - 그 밖의 변하는 상태는 `TunnelRuntime`(잠금)에 둔다. NE는 이 객체의 메서드를 여러 스레드에서 부른다.
/// - NE 경계를 넘기는 오류는 `TunnelProviderError`의 `NSError`다.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    static let mtu = 1280

    private let logger = Logger(subsystem: "com.oozoofrog.app.RemoteDebugPhone.Tunnel", category: "tunnel")
    private let coreQueue = DispatchQueue(label: "com.oozoofrog.app.RemoteDebugPhone.Tunnel.core")
    private let pathQueue = DispatchQueue(label: "com.oozoofrog.app.RemoteDebugPhone.Tunnel.path")
    private let runtime = TunnelRuntime()
    private let lifecycle = TunnelLifecycle<SwiftailTunnelEngine>()
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
        let resetsLogin = TunnelStartOptions.resetsLogin(options)
        Task {
            do {
                if resetsLogin { await resetLogin(config: config) }
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

        let node: SwiftailTunnelEngine
        do {
            node = try await onCoreQueue { [lifecycle, logger] in
                try lifecycle.startNode(generation: generation, start: { () throws -> SwiftailTunnelEngine in
                    try SwiftailTunnelEngine(
                        stateDirectory: try Self.prepareStateDirectory(),
                        hostname: config.hostname, controlURL: config.controlURL, authKey: authKey,
                        utunFd: found.fd, mtu: Self.mtu, logger: logger)
                }, stop: { started in
                    // 시작하는 동안 종료 요청이 왔다. 방금 만든 노드를 같은 큐에서 멈춘다.
                    logger.log("시작 중 종료 요청을 받아 새 노드를 멈춥니다")
                    Self.stopNode(started, logger: logger)
                })
            }
        } catch TunnelLifecycle<SwiftailTunnelEngine>.LifecycleError.stoppedDuringStart {
            throw stoppedDuringStart()
        } catch let error as NodeError {
            logger.error("노드 시작 실패: \(SwiftailTunnelEngine.kind(of: error), privacy: .public)")
            throw fail(.coreStart, generation: generation, detail: SwiftailTunnelEngine.message(for: error))
        } catch {
            logger.error("노드 시작 실패: \(error.localizedDescription, privacy: .public)")
            throw fail(.coreStart, generation: generation, detail: error.localizedDescription)
        }

        startEventLoop(node, generation: generation)
        startPathMonitor(node, generation: generation)
        startMemoryJournal(generation: generation)
        startSwiftailLogJournal(generation: generation)
        // 노드를 저장한 뒤 종료 요청이 왔으면 노드는 종료 쪽 장벽이 멈춘다. 시작을 성공으로 알리지 않는다.
        guard lifecycle.isCurrent(generation) else { throw stoppedDuringStart() }
        // Running을 기다리지 않는다. NeedsLogin이면 앱이 상태를 물어 authURL을 보여 준다.
        logger.log("노드 시작됨")
        SharedVPNState(owner: AppPair.currentAppID, connected: true, updatedAt: Date()).write()
    }

    // MARK: 종료

    override func stopTunnel(with reason: NEProviderStopReason) async {
        SharedVPNState(owner: AppPair.currentAppID, connected: false, updatedAt: Date()).write()
        logger.log("터널 종료 요청: 사유 \(reason.rawValue)")
        // 누가 끊었는지(사용자, 시스템, 설정 변경 등)를 앱이 뒤에 있어도 확장 기록으로 남긴다.
        TunnelMemoryJournal.append("터널 종료 요청: 사유 \(reason.rawValue) (\(Self.describe(reason)))")
        let (node, cleanups) = lifecycle.requestStop()
        applier.discardPending()
        for cleanup in cleanups { cleanup() }
        // 진행 중인 노드 시작이 있으면 그것이 끝난 뒤에 실행된다(같은 직렬 큐).
        // 엔진 종료는 몇 초 걸릴 수 있으므로 메인 스레드가 아닌 직렬 큐에서 부른다.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            coreQueue.async { [lifecycle, logger] in
                lifecycle.drainOnCoreQueue(extra: node) { Self.stopNode($0, logger: logger) }
                continuation.resume()
            }
        }
    }

    private static func stopNode(_ node: SwiftailTunnelEngine, logger: Logger) {
        node.stop()
    }

    // MARK: 앱 메시지

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let request = TunnelAppRequest.decode(messageData) else {
            return try? TunnelStatusReply(phase: lifecycle.phase, error: TunnelStatusReply.unknownCommand).encoded()
        }
        switch request.cmd {
        case .status:
            notePathPeer(request.peer)
            return try? await statusReply().encoded()
        }
    }

    /// 앱이 알려 준 Mac 이름이 바뀌었으면 노드에 알린다. 노드는 다음 상태 점검부터 `peerPath`를 채운다.
    private func notePathPeer(_ peer: String?) {
        guard let peer, let node = lifecycle.currentNode, runtime.updatePathPeer(peer) else { return }
        node.setPathPeer(peer)
    }

    private func statusReply() async -> TunnelStatusReply {
        var status = runtime.lastStatus
        if let node = lifecycle.currentNode, let fresh = await node.status() {
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

    private func startEventLoop(_ node: SwiftailTunnelEngine, generation: Int) {
        let stream = node.events()
        let task = Task.detached { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handleEvent(event)
            }
        }
        // 그사이 종료 요청이 왔으면 바로 끊는다.
        if !lifecycle.attach(generation: generation, cleanup: { task.cancel() }) { task.cancel() }
    }

    private func handleEvent(_ event: CoreEvent) {
        switch event {
        case .networkSettings(let settings):
            let plan = SettingsTranslator.translate(settings)
            logger.log("network-settings: IPv4 경로 \(plan.ipv4?.routes.count ?? 0)개, IPv6 경로 \(plan.ipv6?.routes.count ?? 0)개, DNS \(plan.dns == nil ? "없음" : "있음", privacy: .public), mtu \(plan.mtu)")
            applier.submit(plan)
        case .state(let status):
            if runtime.lastStatus?.backendState != status.backendState {
                TunnelMemoryJournal.append("tailnet 상태: \(status.backendState.rawValue)")
            }
            runtime.setStatus(status)
            logger.log("상태: \(status.backendState.rawValue, privacy: .public)")
            if status.backendState == .running { removeLegacyGoStateOnce() }
            if status.backendState == .error {
                runtime.setLastError(TunnelSecretRedactor.redact(status.errorMessage))
                if status.errorMessage == TunnelEngineMessages.tunDeviceClosed { engineDied() }
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

    // MARK: 메모리 기록

    /// 앱이 뒤에 있어 상태를 묻지 않는 동안에도 메모리 사용량이 남도록, 30초마다 재고 5분마다 한 줄을 쌓는다.
    private func startMemoryJournal(generation: Int) {
        let task = Task.detached {
            var log = TunnelMemoryLog()
            while !Task.isCancelled {
                if let mib = ProcessMemory.physFootprintMiB(), let line = log.sample(mib, at: Date()) {
                    TunnelMemoryJournal.append(line)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        if !lifecycle.attach(generation: generation, cleanup: { task.cancel() }) { task.cancel() }
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

    private func startPathMonitor(_ node: SwiftailTunnelEngine, generation: Int) {
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

    private func pathChanged(_ path: NWPath, node: SwiftailTunnelEngine) {
        guard path.status == .satisfied, let interface = Self.defaultInterface(path) else {
            if runtime.noteInterface(nil) { TunnelMemoryJournal.append("네트워크 경로 없음") }
            return
        }
        // 전환 시각을 남긴다(앱이 뒤에 있어도 확장 기록으로 올라간다).
        if runtime.noteInterface(interface.name) {
            TunnelMemoryJournal.append("네트워크 경로: \(interface.name) (\(String(describing: interface.type)))")
        }
        #if RD_TEST_LINKS
        // 시험 링크 빌드 전용: 알림마다 경로의 주소 체계를 남긴다(주소 값은 남기지 않는다).
        TunnelMemoryJournal.append(
            "기본 인터페이스 알림: \(interface.name) 경로 IPv4=\(path.supportsIPv4) IPv6=\(path.supportsIPv6) DNS=\(path.supportsDNS), \(Self.addressFamilies(of: interface.name))")
        #endif
        // 같은 인터페이스를 다시 알릴지는 노드가 정한다(Swiftail이 같은 인터페이스는 거른다).
        node.setDefaultInterface(interface)
    }

    #if RD_TEST_LINKS
    /// 시험 링크 빌드 전용: 인터페이스에 붙은 주소의 종류만 문장으로 만든다.
    static func addressFamilies(of name: String) -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return "주소 읽기 실패" }
        defer { freeifaddrs(head) }
        var v4 = false, clat = false, v6 = false, v6Routable = false
        var cursor = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard String(cString: entry.pointee.ifa_name) == name, let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                v4 = true
                let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if raw >> 8 == 0xC00000 { clat = true }
            case AF_INET6:
                v6 = true
                let first = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr.__u6_addr.__u6_addr8.0 }
                if first != 0xFE { v6Routable = true }
            default: break
            }
        }
        let v4Text = v4 ? (clat ? "AF_INET 있음(192.0.0.x CLAT)" : "AF_INET 있음(CLAT 아님)") : "AF_INET 없음"
        let v6Text = v6 ? (v6Routable ? "AF_INET6 있음(링크 로컬 밖 주소 있음)" : "AF_INET6 있음(링크 로컬뿐)") : "AF_INET6 없음"
        return "\(v4Text), \(v6Text)"
    }

    #endif

    /// 이 프로세스의 Swiftail 로거 줄(상태 전이, 제어·DERP 연결, 경로 전환. 키·주소·이름은 없다)을 2초마다
    /// 확장 기록으로 옮긴다. 앱이 앞에 올 때 기기 로그로 올라가므로 앱이 뒤에 있던 동안의 사건도 남는다.
    private func startSwiftailLogJournal(generation: Int) {
        let task = Task.detached {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
                TunnelMemoryJournal.append("Swiftail 로그 저장소를 열지 못함")
                return
            }
            var since = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let predicate = NSPredicate(format: "subsystem == %@ AND date > %@", "Swiftail", since as NSDate)
                guard let entries = try? store.getEntries(matching: predicate) else { continue }
                for case let entry as OSLogEntryLog in entries where entry.date > since {
                    TunnelMemoryJournal.append("[Swiftail \(entry.category)] \(entry.composedMessage.prefix(220))", at: entry.date)
                    since = entry.date
                }
            }
        }
        if !lifecycle.attach(generation: generation, cleanup: { task.cancel() }) { task.cancel() }
    }

    /// 만족된 경로의 첫 물리 인터페이스(터널 자신 `utun*`·`ipsec*`·루프백 제외).
    static func defaultInterface(_ path: NWPath) -> NWInterface? {
        path.availableInterfaces.first { interface in
            interface.type != .loopback && interface.type != .other
                && !interface.name.hasPrefix("utun") && !interface.name.hasPrefix("ipsec")
        }
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

    /// 공용 컨테이너의 `Library/Application Support/RemoteDebug/swiftail`(첫 잠금 해제 후 접근 가능, 백업 제외).
    /// 두 앱이 같은 tailnet 기기로 보이도록 App Group 컨테이너를 쓴다. 공용 컨테이너가 없으면 확장 컨테이너를 쓴다.
    /// 예전 Go 터널의 상태는 읽거나 옮기지 않는다(로그인은 다시 한다).
    static func prepareStateDirectory() throws -> URL {
        if let shared = SharedContainer.groupSupportDirectory() {
            return try TunnelStorage.prepareStateDirectory(in: shared)
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try TunnelStorage.prepareStateDirectory(in: support)
    }

    // MARK: 로그인 초기화

    /// "다른 계정으로 로그인". 순서는 `run()` 중지·대기 → 서버 쪽 `logOut()` → 상태 폴더 지우기다.
    /// 앱이 VPN을 먼저 끄고 꺼질 때까지 기다린 뒤 시작을 요청하므로 이 시점에 도는 노드는 없다(`stopTunnel`이 노드의
    /// `run()`이 끝나기를 기다렸다). 도는 노드가 남아 있으면 같은 폴더를 지우지 않는다.
    /// `logOut()`은 실패하거나 기한(10초)이 지날 수 있다. 서버가 이미 적용했을 수 있으므로 어느 쪽이든 로컬 상태는 지운다.
    private func resetLogin(config: TunnelProviderConfig) async {
        guard lifecycle.currentNode == nil else {
            logger.error("도는 노드가 있어 로그인을 지우지 않습니다")
            return
        }
        if let directory = try? Self.prepareStateDirectory() {
            let result = await SwiftailTunnelEngine.logOut(
                stateDirectory: directory, hostname: config.hostname, controlURL: config.controlURL, logger: logger)
            if case .failed(let kind) = result {
                TunnelMemoryJournal.append("서버 로그아웃 실패(\(kind)): 로컬 로그인을 그대로 지웁니다")
            }
        }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try TunnelStorage.resetStateDirectory(in: support)
            if let shared = SharedContainer.groupSupportDirectory() { try TunnelStorage.resetStateDirectory(in: shared) }
            logger.log("저장된 tailnet 로그인을 지웠습니다")
        } catch {
            logger.error("tailnet 로그인을 지우지 못했습니다: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 예전 Go 상태

    /// Swiftail 노드가 처음 실행 상태가 된 뒤 App Group 컨테이너의 예전 Go 터널 상태를 한 번 지운다(그 밖의 것은 건드리지 않는다).
    private func removeLegacyGoStateOnce() {
        guard runtime.markLegacyCleanup(), let shared = SharedContainer.groupSupportDirectory() else { return }
        Task.detached(priority: .utility) { [logger] in
            if TunnelStorage.removeLegacyGoState(in: shared) { logger.log("예전 Go 터널 상태를 지웠습니다") }
        }
    }

    private static func describe(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none: "없음"
        case .userInitiated: "사용자"
        case .providerFailed: "확장 오류"
        case .noNetworkAvailable: "네트워크 없음"
        case .unrecoverableNetworkChange: "네트워크 전환"
        case .providerDisabled: "확장 꺼짐"
        case .authenticationCanceled: "인증 취소"
        case .configurationFailed: "구성 오류"
        case .idleTimeout: "유휴 시간 초과"
        case .configurationDisabled: "구성 해제"
        case .configurationRemoved: "구성 삭제"
        case .superceded: "다른 구성이 켜짐"
        case .userLogout: "사용자 로그아웃"
        case .userSwitch: "사용자 전환"
        case .connectionFailed: "연결 실패"
        case .sleep: "잠자기"
        case .appUpdate: "앱 업데이트"
        @unknown default: "알 수 없음"
        }
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
    private var _engineDead = false
    private var _interface: String?
    private var _interfaceKnown = false
    private var _pathPeer: String?
    /// 예전 Go 상태 정리를 이 프로세스에서 이미 했는가(`reset()`이 지우지 않는다).
    private var _legacyCleaned = false

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
            _engineDead = false
            _interface = nil
            _interfaceKnown = false
            _pathPeer = nil
        }
    }

    /// 이름이 바뀌었으면 기억하고 `true`.
    func updatePathPeer(_ name: String) -> Bool {
        locked {
            guard _pathPeer != name else { return false }
            _pathPeer = name
            return true
        }
    }

    func setStatus(_ status: CoreStatus) { locked { _status = status } }
    func setLastError(_ message: String?) { locked { _lastError = message } }

    /// 기본 인터페이스 이름이 바뀌었으면 기억하고 `true`(기록용).
    func noteInterface(_ name: String?) -> Bool {
        locked {
            guard _interface != name || !_interfaceKnown else { return false }
            _interface = name
            _interfaceKnown = true
            return true
        }
    }

    /// 처음 부르면 `true`.
    func markLegacyCleanup() -> Bool {
        locked {
            guard !_legacyCleaned else { return false }
            _legacyCleaned = true
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
