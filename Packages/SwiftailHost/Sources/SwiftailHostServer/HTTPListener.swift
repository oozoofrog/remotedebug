import Foundation
import Network
import RDHostLogic
import Security
import Swiftail
import SwiftailCertificates
import SwiftailLoopback
import Synchronization

/// `NWListener` 하나와 그 위의 HTTP/1.1 서버(`HTTPConnectionServer`). 세 곳에 쓴다:
///
/// - tailnet 443의 루프백 TLS 리스너(`.bridge`). Swiftail 계약 `docs/contracts/SwiftailHost.md` 동작 B7을 지킨다:
///   `127.0.0.1`에만 묶고 포트는 시스템이 고른다. 리스너 하나에 다리 하나다. 다리의 프로토콜을 `applicationProtocols`의
///   **끝에**(TLS 아래) 더한다. 받은 연결이 `.ready`가 되면 요청을 읽기 전에 `origin(of:)`을 **한 번** 묻고 nil이면 끊는다.
/// - 같은 네트워크 직접 연결 리스너(`.direct`, protocol-addenda O). TLS 1.3, 사설·링크 로컬 상대만 받는다(TLS 전에 거른다).
/// - 업데이트 페이지의 루프백 평문 리스너(`.loopback`, protocol-addenda I).
///
/// 준비 전에 `.failed`가 된 연결과 끝난 연결은 `cancel()`하고 `NWConnection`의 참조를 놓는다(쥐고 있으면 소켓이 남는다).
public final class HTTPListener: Sendable {
    /// 받은 연결의 상대를 정하는 길.
    public enum Admission: Sendable {
        /// 다리가 이은 연결만 받는다(tailnet).
        case bridge(LoopbackBridge)
        /// 원격 주소가 이 판정을 통과한 연결만 받는다. 상대는 `HostOrigin.direct(remoteIP:)`.
        case direct(allow: @Sendable (String) -> Bool)
        /// 루프백 상대만 받는다(업데이트 페이지). 상대는 `HostOrigin.direct(remoteIP:)`.
        case loopback
        /// 시험 전용: framer 없이 모든 연결을 이 상대로 받는다.
        case acceptAllForTesting(HostPeer)
    }

    public enum Security: Sendable {
        case tls(TLSServerIdentity)
        case plaintext
    }

    /// 묶을 곳.
    public enum Binding: Sendable {
        /// `127.0.0.1`, 포트는 이것(0이면 시스템이 고른다).
        case loopback(port: UInt16)
        /// 모든 인터페이스, 이 포트(0이면 시스템이 고른다).
        case anyInterface(port: UInt16)
    }

    /// 리스너·연결 사건. 요청의 내용은 담지 않는다.
    public enum Event: Sendable {
        /// 상대를 확인한 연결이 섰다.
        case connection(HostOrigin)
        /// 다리의 토큰이 없거나 준비 전에 끝난 연결, 상대를 얻지 못한 연결, 거른 주소의 연결을 끊었다.
        case connectionRejected
    }

    public let port: UInt16
    private let listener: NWListener
    private let admission: Admission
    private let handler: any HostRequestHandling
    private let limits: HTTPServerLimits
    private let events: @Sendable (Event) -> Void
    private let connections = ConnectionRegistry()

    /// 받아서 아직 끝나지 않은 연결 수.
    public var activeConnectionCount: Int { connections.count }

    private init(port: UInt16, listener: NWListener, admission: Admission, handler: any HostRequestHandling,
                 limits: HTTPServerLimits, events: @escaping @Sendable (Event) -> Void) {
        (self.port, self.listener, self.admission, self.handler) = (port, listener, admission, handler)
        (self.limits, self.events) = (limits, events)
    }

    /// 리스너를 띄운다. 포트를 묶지 못하면 던진다.
    public static func start(binding: Binding, security: Security, admission: Admission, handler: any HostRequestHandling,
                             limits: HTTPServerLimits = HTTPServerLimits(),
                             events: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> HTTPListener {
        let parameters: NWParameters
        switch security {
        case .tls(let identity):
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            sec_protocol_options_set_local_identity(options, identity.value)
            sec_protocol_options_set_min_tls_protocol_version(options, identity.minimumVersion)
            sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        case .plaintext:
            parameters = .tcp
        }
        let port: NWEndpoint.Port
        switch binding {
        case .loopback(let value):
            port = NWEndpoint.Port(rawValue: value) ?? .any
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        case .anyInterface(let value):
            port = NWEndpoint.Port(rawValue: value) ?? .any
        }
        parameters.allowLocalEndpointReuse = false
        if case .bridge(let bridge) = admission {
            // 반드시 끝에(TLS 아래, TCP 바로 위). 앞에 넣으면 TLS 위에 놓여 핸드셰이크가 깨진다(동작 B7).
            parameters.defaultProtocolStack.applicationProtocols.append(bridge.makeListenerProtocolOptions())
        }
        let listener: NWListener
        if case .anyInterface = binding {
            listener = try NWListener(using: parameters, on: port)
        } else {
            listener = try NWListener(using: parameters)
        }
        let (accepted, sink) = AsyncStream.makeStream(of: NWConnection.self)
        listener.newConnectionHandler = { sink.yield($0) }
        let bound = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let once = Mutex<CheckedContinuation<UInt16, any Error>?>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { once.withLock { $0.take() }?.resume(returning: port) }
                case .failed(let error), .waiting(let error):
                    sink.finish()
                    listener.cancel()
                    once.withLock { $0.take() }?.resume(throwing: error)
                case .cancelled:
                    sink.finish()
                    once.withLock { $0.take() }?.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "swiftail-host.listener"))
        }
        let server = HTTPListener(port: bound, listener: listener, admission: admission, handler: handler, limits: limits,
                                  events: events)
        Task {
            for await connection in accepted { server.accept(connection) }
        }
        return server
    }

    /// 새 연결만 받지 않는다. 이미 받은 연결은 끝까지 간다(인증서 갱신 뒤의 옛 리스너).
    public func stopAccepting() { listener.cancel() }

    /// 리스너와 모든 연결을 닫는다.
    public func close() {
        listener.cancel()
        connections.cancelAll()
    }

    // MARK: - 연결

    private func accept(_ connection: NWConnection) {
        connections.add(connection)
        Task {
            await self.serve(connection)
            // 참조를 놓아야 준비되지 않고 끝난 연결의 소켓이 닫힌다(동작 B7).
            self.connections.remove(connection)
        }
    }

    private func serve(_ connection: NWConnection) async {
        // 주소로 거르는 길은 TLS 바이트를 주고받기 전에(start 전에) 거른다.
        var addressOrigin: HostOrigin?
        switch admission {
        case .direct(let allow):
            guard let ip = Self.remoteIP(connection.endpoint), allow(ip) else {
                events(.connectionRejected)
                return
            }
            addressOrigin = .direct(remoteIP: ip)
        case .loopback:
            guard let ip = Self.remoteIP(connection.endpoint), ip == "127.0.0.1" || ip == "::1" else {
                events(.connectionRejected)
                return
            }
            addressOrigin = .direct(remoteIP: ip)
        case .bridge, .acceptAllForTesting:
            break
        }
        let watchdog = Watchdog(connection: connection, seconds: limits.readyTimeout)
        defer { watchdog.stop() }
        guard await ConnectionIO.ready(connection) else {
            events(.connectionRejected)
            return
        }
        // 요청을 읽기 전에 한 번만 묻는다. 두 번째 답은 nil이다.
        let origin: HostOrigin
        switch admission {
        case .bridge(let bridge):
            guard let found = bridge.origin(of: connection) else {
                events(.connectionRejected)
                return
            }
            origin = .tailnet(Self.peer(found.peer))
        case .acceptAllForTesting(let peer):
            origin = .tailnet(peer)
        case .direct:
            guard case .direct(let ip, _)? = addressOrigin else { return }
            // 연결이 들어온 이 Mac의 인터페이스(USB 케이블 설치가 어느 iPhone인지 가리는 데 쓴다).
            origin = .direct(remoteIP: ip, interface: Self.localInterface(of: connection))
        case .loopback:
            guard let addressOrigin else { return }
            origin = addressOrigin
        }
        events(.connection(origin))
        await HTTPConnectionServer.serve(connection, origin: origin, handler: handler, limits: limits, watchdog: watchdog,
                                         openConnections: { [connections] in connections.count })
    }

    /// Swiftail의 신원 → 로직의 상대. 이름은 예전 Go 코어의 `whois`와 같다: MagicDNS 이름의 첫 레이블, 없으면 표시용 이름.
    /// 페어링(`PairingHost`의 승인 요청)도 같은 규칙으로 허용 목록 항목을 만든다.
    public static func peer(_ identity: PeerIdentity) -> HostPeer {
        let first = identity.name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return HostPeer(stableID: identity.stableID, nodeName: first.isEmpty ? identity.computedName : first,
                        loginName: identity.loginName)
    }

    /// 연결이 들어온 인터페이스의 이름. 링크 로컬 IPv6 상대는 주소에 붙은 영역이 그것이다. 그 밖에는 연결의 경로에서 읽는다.
    static func localInterface(of connection: NWConnection) -> String? {
        if case .hostPort(let host, _) = connection.endpoint, case .ipv6(let address) = host, let name = address.interface?.name {
            return name
        }
        return connection.currentPath?.availableInterfaces.first?.name
    }

    /// 연결의 원격 IP(문자열). IPv4 대응 IPv6는 IPv4로, 영역(`%en0`)은 뗀다.
    static func remoteIP(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return "\(address)".split(separator: "%").first.map(String.init)
        case .ipv6(let address):
            let raw = address.rawValue
            if raw.count == 16, raw.prefix(10).allSatisfy({ $0 == 0 }), raw[raw.startIndex + 10] == 0xFF, raw[raw.startIndex + 11] == 0xFF {
                return raw.suffix(4).map(String.init).joined(separator: ".")
            }
            return "\(address)".split(separator: "%").first.map(String.init)
        case .name:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// 리스너의 TLS 신원과 최소 버전. 키체인을 쓰지 않는다: 키는 `SecKeyCreateWithData`(메모리의 키), 신원은
/// `SecIdentityCreate`, 중간 인증서는 `sec_identity_create_with_certificates`로 싣는다(Swiftail 계약 6절의 조각).
public struct TLSServerIdentity: @unchecked Sendable {
    // sec_identity_t는 불변 객체다.
    let value: sec_identity_t
    let minimumVersion: tls_protocol_version_t

    public enum Failure: Error, Equatable {
        case key
        case certificate
        case identity
    }

    /// DER 사슬(leaf 먼저)과 P-256 개인 키(x9.63).
    public init(chain: [[UInt8]], privateKeyX963: [UInt8], minimumVersion: tls_protocol_version_t) throws(Failure) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(Data(privateKeyX963) as CFData, attributes as CFDictionary, nil) else { throw .key }
        var certificates: [SecCertificate] = []
        for der in chain {
            guard let value = SecCertificateCreateWithData(nil, Data(der) as CFData) else { throw .certificate }
            certificates.append(value)
        }
        guard let leaf = certificates.first, let identity = SecIdentityCreate(nil, leaf, key) else { throw .identity }
        // leaf 뒤의 사슬만 넘긴다. leaf까지 넣으면 서버가 leaf를 두 번 보낸다.
        guard let value = sec_identity_create_with_certificates(identity, Array(certificates.dropFirst()) as CFArray) else {
            throw .identity
        }
        self.value = value
        self.minimumVersion = minimumVersion
    }

    /// tailnet 인증서(TLS 1.2 이상. 예전 Go 호스트의 tailnet 리스너와 같다).
    public init(_ certificate: TailnetCertificate) throws(Failure) {
        try self.init(chain: certificate.chain, privateKeyX963: Array(certificate.privateKey.x963Representation),
                      minimumVersion: .TLSv12)
    }
}
