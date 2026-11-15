import Foundation
import Network
import RDHostLogic
import Swiftail
import SwiftailCertificates
import SwiftailLoopback
import Synchronization

/// 호스트 하나의 설정.
public struct HostConfiguration: Sendable {
    /// 노드 설정. 상태 디렉터리는 이미 있어야 한다(인증서 관리자는 그 아래 `certs/`만 만든다).
    public var node: NodeConfiguration
    /// ACME 설정. nil이면 tailnet 포트에서 평문 HTTP로 답한다(루프백 시험 제어 서버용. Go 코어의 `listenTLS: false`).
    public var certificates: CertificateConfiguration?
    /// tailnet에서 들을 포트.
    public var port: UInt16
    public var limits: HTTPServerLimits
    /// 기본 경로가 바뀔 때마다 노드에 알린다(`NWPathMonitor`). 시험에서 끈다.
    public var followsDefaultPath: Bool

    public init(node: NodeConfiguration, certificates: CertificateConfiguration?, port: UInt16 = 443,
                limits: HTTPServerLimits = HTTPServerLimits(), followsDefaultPath: Bool = true) {
        (self.node, self.certificates, self.port, self.limits) = (node, certificates, port, limits)
        self.followsDefaultPath = followsDefaultPath
    }
}

/// 지금 tailnet 쪽 서버의 모습.
public struct ServingState: Sendable, Equatable {
    /// tailnet 포트를 듣고 있다.
    public var listening = false
    /// TLS 리스너가 인증서로 서 있다(평문 모드면 리스너가 섰다).
    public var tlsReady = false
    /// 지금 TLS 리스너의 인증서 이름.
    public var domain: String?

    public init(listening: Bool = false, tlsReady: Bool = false, domain: String? = nil) {
        (self.listening, self.tlsReady, self.domain) = (listening, tlsReady, domain)
    }
}

/// Swiftail 노드 위의 HTTP(S) 호스트. Swiftail 계약 `docs/contracts/SwiftailHost.md` 2절 "쓰는 모양(Mac 호스트)"을 따른다:
///
/// ```
/// tailnet :443 ── TailnetListener ── LoopbackBridge ── 127.0.0.1:<시스템 포트> ── NWListener(TLS) ── HTTP ── 로직
/// ```
///
/// `init`은 파일·소켓을 만들지 않는다. `run()`은 부른 Task가 취소될 때까지 돌고, 취소되면 노드의 `run()`과
/// `CertificateManager.run()`이 끝나기를 기다린 뒤 돌아온다. 그 뒤라면 `node.logOut()`을 부를 수 있다.
public final class SwiftailHostRuntime: Sendable {
    public let node: TailnetNode
    public let certificates: CertificateManager?
    private let configuration: HostConfiguration
    private let handler: any HostRequestHandling
    private let events: @Sendable (HostEvent) -> Void
    private let state = Mutex(ServingState())

    /// - Throws: 설정 오류(`NodeError.invalidConfiguration`, `CertificateError.invalidConfiguration`).
    public init(configuration: HostConfiguration, handler: any HostRequestHandling,
                events: @escaping @Sendable (HostEvent) -> Void) throws {
        let node = try TailnetNode(configuration: configuration.node, device: .inProcess)
        self.node = node
        certificates = try configuration.certificates.map { try CertificateManager(node: node, configuration: $0) }
        self.configuration = configuration
        self.handler = handler
        self.events = events
    }

    public var serving: ServingState { state.withLock { $0 } }

    /// 사용자가 tailnet 설정을 고쳤을 때(또는 고쳐졌을 수 있을 때) 인증서 발급을 곧바로 다시 본다(동작 R의 `retryNow()`).
    public func retryCertificates() async {
        await certificates?.retryNow()
    }

    /// - Throws: 노드나 인증서 관리자의 다시 켜도 소용없는 실패(`NodeError`, `CertificateError`), tailnet 포트를 듣지 못함
    ///   (`ConnectionError`).
    public func run() async throws {
        let node = node
        let events = events
        let servers = ServerSlot(node: node, handler: handler, limits: configuration.limits, events: events)
        let listener = try await node.listen(port: configuration.port)
        state.withLock { $0.listening = true }
        events(.listening(port: configuration.port))
        if certificates == nil {
            await servers.startPlaintext()
            let ready = await servers.target != nil
            state.withLock { $0.tlsReady = ready }
        }
        defer { state.withLock { $0 = ServingState() } }

        do {
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask { try await node.run() }
                if let certificates {
                    group.addTask { try await certificates.run() }
                    group.addTask { [self] in
                        // 인증서가 오거나 바뀔 때마다 TLS 리스너를 (다시) 띄운다.
                        for await certificate in certificates.certificates {
                            events(.certificate(domain: certificate.domain, notBefore: certificate.notBefore,
                                                notAfter: certificate.notAfter, chainCount: certificate.chain.count))
                            if await servers.restart(with: certificate) {
                                self.state.withLock { $0.tlsReady = true; $0.domain = certificate.domain }
                            }
                        }
                    }
                    group.addTask {
                        var last: CertificateStatus?
                        while !Task.isCancelled {
                            let status = await certificates.status
                            if status != last {
                                last = status
                                events(.certificateStatus(status))
                            }
                            try? await Task.sleep(for: .seconds(2))
                        }
                    }
                }
                group.addTask {
                    for await event in node.events {
                        switch event {
                        case .stateChanged(let state):
                            events(.nodeState(state))
                            if state == .running {
                                let status = await node.status
                                let inDomains = status.fqdn.map { status.certDomains.contains($0) } ?? false
                                events(.running(peerCount: status.peerCount, nameInCertDomains: inDomains))
                            }
                        case .tailnetLockChanged(let lock):
                            events(.tailnetLock(lock))
                        case .peerPathChanged:
                            break
                        }
                    }
                }
                if configuration.followsDefaultPath {
                    group.addTask { await DefaultPathFollower.follow(node: node, events: events) }
                }
                // 이 흐름은 노드의 `run()`이 끝나거나 이 Task가 취소되면 끝난다.
                for await connection in listener {
                    group.addTask {
                        guard let target = await servers.target else {
                            // 아직 인증서가 없다.
                            await connection.abort()
                            return
                        }
                        try? await target.bridge.forward(connection, toLoopbackPort: target.port)
                    }
                }
                group.cancelAll()
            }
        } catch {
            await listener.close()
            await servers.close()
            throw error
        }
        await listener.close()
        await servers.close()
    }
}

/// 기본 경로를 따라 노드에 인터페이스를 알린다. Swiftail에는 경로 감시가 없고 `setDefaultInterface(_:)`가 망 전환의 유일한
/// 통지원이다(Swiftail 계약 SwiftailTunnel D6, 동작 N). 알리지 않으면 Wi-Fi를 바꾸거나 잠자기에서 깬 뒤 노드가 첫 소켓을 쥔
/// 채 조용히 죽는다.
enum DefaultPathFollower {
    /// 터널·VPN 인터페이스의 이름 앞부분. 다른 VPN(공식 Tailscale 앱 포함)이 기본 경로를 쥐어도 그 아래의 물리 인터페이스를 넘긴다.
    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "awdl", "llw", "anpi", "ap"]

    static func follow(node: TailnetNode, events: @escaping @Sendable (HostEvent) -> Void) async {
        let monitor = NWPathMonitor()
        let (paths, sink) = AsyncStream.makeStream(of: NWPath.self, bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { sink.yield($0) }
        monitor.start(queue: DispatchQueue(label: "swiftail-host.path"))
        defer { monitor.cancel() }
        await withTaskCancellationHandler {
            var last: String?
            for await path in paths {
                guard path.status == .satisfied else { continue }
                let interfaces = path.availableInterfaces
                guard let index = choose(interfaces.map { ($0.name, $0.type) }) else { continue }
                let interface = interfaces[index]
                await node.setDefaultInterface(interface)
                if interface.name != last {
                    last = interface.name
                    events(.defaultInterface(name: interface.name))
                }
            }
        } onCancel: {
            sink.finish()
        }
    }

    /// 넘길 인터페이스의 차례. 경로가 고른 순서에서 루프백·터널(`.other`와 터널 이름)을 건너뛴 첫 것.
    static func choose(_ interfaces: [(name: String, type: NWInterface.InterfaceType)]) -> Int? {
        interfaces.firstIndex { name, type in
            switch type {
            case .wifi, .wiredEthernet, .cellular:
                return !tunnelPrefixes.contains { name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy(\.isNumber) }
            case .loopback, .other:
                return false
            @unknown default:
                return false
            }
        }
    }
}

/// 지금 쓰는 TLS 리스너와 그 다리. 인증서가 바뀌면 새 리스너를 세운 뒤 옛 리스너는 새 연결만 그만 받는다.
actor ServerSlot {
    struct Target: Sendable {
        let bridge: LoopbackBridge
        let port: UInt16
    }

    private let node: TailnetNode
    private let handler: any HostRequestHandling
    private let limits: HTTPServerLimits
    private let events: @Sendable (HostEvent) -> Void
    private var current: (server: HTTPListener, bridge: LoopbackBridge)?
    /// 새 연결은 받지 않고 받은 연결이 끝나기를 기다리는 옛 리스너.
    private var retired: [HTTPListener] = []

    init(node: TailnetNode, handler: any HostRequestHandling, limits: HTTPServerLimits,
         events: @escaping @Sendable (HostEvent) -> Void) {
        (self.node, self.handler, self.limits, self.events) = (node, handler, limits, events)
    }

    var target: Target? { current.map { Target(bridge: $0.bridge, port: $0.server.port) } }

    @discardableResult
    func restart(with certificate: TailnetCertificate) async -> Bool {
        do {
            return await start(security: .tls(try TLSServerIdentity(certificate)))
        } catch {
            events(.serverFailed("TLS 신원(\(error))"))
            return false
        }
    }

    /// 평문 모드(인증서 없음).
    func startPlaintext() async {
        await start(security: .plaintext)
    }

    @discardableResult
    private func start(security: HTTPListener.Security) async -> Bool {
        // 리스너 하나에 다리 하나(동작 B7).
        let bridge = LoopbackBridge(node: node)
        let events = events
        do {
            let server = try await HTTPListener.start(binding: .loopback(port: 0), security: security, admission: .bridge(bridge),
                                                      handler: handler, limits: limits) { event in
                switch event {
                case .connection(let origin): events(.connection(origin))
                case .connectionRejected: events(.connectionRejected)
                }
            }
            if let old = current {
                old.server.stopAccepting()
                retired.append(old.server)
            }
            retired.removeAll { $0.activeConnectionCount == 0 }
            current = (server, bridge)
            events(.serverStarted)
            return true
        } catch {
            events(.serverFailed("리스너"))
            return false
        }
    }

    func close() {
        current?.server.close()
        for server in retired { server.close() }
        current = nil
        retired = []
    }
}
