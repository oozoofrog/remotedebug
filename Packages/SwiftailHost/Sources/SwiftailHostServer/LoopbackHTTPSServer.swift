import Foundation
import Network
import Security
import SwiftailCertificates
import SwiftailLoopback
import Synchronization

/// 루프백 TLS 리스너 하나와 그 위의 최소 HTTP/1.1 서버. Swiftail 계약 `docs/contracts/SwiftailHost.md` 동작 B7을 지킨다:
///
/// - 리스너는 `127.0.0.1`에만 묶고 포트는 시스템이 고른다. 리스너 하나에 다리 하나다.
/// - 다리의 프로토콜을 `applicationProtocols`의 **끝에**(TLS 아래) 더한다.
/// - 받은 연결이 `.ready`가 되면 요청을 읽기 전에 `origin(of:)`을 **한 번** 묻고 nil이면 끊는다.
/// - 준비 전에 `.failed`가 된 연결과 끝난 연결은 `cancel()`하고 `NWConnection`의 참조를 놓는다(쥐고 있으면 소켓이 남는다).
///
/// 연결마다 요청 하나만 받고 `Connection: close`로 답한다.
public final class LoopbackHTTPSServer: Sendable {
    /// 받은 연결의 상대를 정하는 길.
    enum Admission: Sendable {
        /// 다리가 이은 연결만 받는다(운영).
        case bridge(LoopbackBridge)
        /// 시험 전용: framer 없이 모든 연결을 이 `StableID`로 받는다. 평문 리스너와만 쓴다.
        case acceptAllForTesting(stableID: String)
    }

    /// 시험 전용 평문 모드. 운영은 늘 TLS다.
    enum Security {
        case tls(sec_identity_t)
        case plaintextForTesting
    }

    /// 연결 하나의 한도(초).
    struct Timeouts: Sendable {
        /// `.ready`까지(다리 framer의 토큰 5초 + TLS 핸드셰이크).
        var ready: Double = 20
        /// 준비된 뒤 요청 머리가 다 오기까지.
        var head: Double = 20
        /// 응답을 보내는 동안 진전이 없어도 되는 시간.
        var idle: Double = 60
    }

    /// 한 번에 받는 바이트.
    static let receiveChunk = 16_384
    /// 파일을 한 번에 읽어 보내는 바이트.
    static let sendChunk = 262_144

    public let port: UInt16
    /// 이 리스너의 TLS 이름. 매니페스트의 URL에 쓴다.
    public let domain: String
    private let listener: NWListener
    private let admission: Admission
    private let content: ServedContent
    private let timeouts: Timeouts
    private let events: @Sendable (HostEvent) -> Void
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])

    /// 받아서 아직 끝나지 않은 연결 수.
    public var activeConnectionCount: Int { connections.withLock { $0.count } }

    private init(port: UInt16, domain: String, listener: NWListener, admission: Admission, content: ServedContent,
                 timeouts: Timeouts, events: @escaping @Sendable (HostEvent) -> Void) {
        (self.port, self.domain, self.listener, self.admission) = (port, domain, listener, admission)
        (self.content, self.timeouts, self.events) = (content, timeouts, events)
    }

    /// 인증서로 TLS 리스너를 띄운다. 다리는 이 리스너만의 것이어야 한다.
    public static func start(certificate: TailnetCertificate, bridge: LoopbackBridge, content: ServedContent,
                             events: @escaping @Sendable (HostEvent) -> Void) async throws -> LoopbackHTTPSServer {
        try await start(security: .tls(TLSIdentity.make(certificate)), admission: .bridge(bridge), domain: certificate.domain,
                        content: content, timeouts: Timeouts(), events: events)
    }

    static func start(security: Security, admission: Admission, domain: String, content: ServedContent, timeouts: Timeouts,
                      events: @escaping @Sendable (HostEvent) -> Void) async throws -> LoopbackHTTPSServer {
        let parameters: NWParameters
        switch security {
        case .tls(let identity):
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            sec_protocol_options_set_local_identity(options, identity)
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        case .plaintextForTesting:
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = false
        if case .bridge(let bridge) = admission {
            // 반드시 끝에(TLS 아래, TCP 바로 위). 앞에 넣으면 TLS 위에 놓여 핸드셰이크가 깨진다(동작 B7).
            parameters.defaultProtocolStack.applicationProtocols.append(bridge.makeListenerProtocolOptions())
        }
        let listener = try NWListener(using: parameters)
        let (accepted, sink) = AsyncStream.makeStream(of: NWConnection.self)
        listener.newConnectionHandler = { sink.yield($0) }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let once = Mutex<CheckedContinuation<UInt16, any Error>?>(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { once.withLock { $0.take() }?.resume(returning: port) }
                case .failed(let error):
                    sink.finish()
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
        let server = LoopbackHTTPSServer(port: port, domain: domain, listener: listener, admission: admission,
                                         content: content, timeouts: timeouts, events: events)
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
        let open = connections.withLock { Array($0.values) }
        for connection in open { connection.cancel() }
    }

    // MARK: - 연결

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections.withLock { $0[key] = connection }
        Task {
            await self.serve(connection)
            connection.cancel()
            connection.stateUpdateHandler = nil
            // 참조를 놓아야 준비되지 않고 끝난 연결의 소켓이 닫힌다(동작 B7).
            self.connections.withLock { _ = $0.removeValue(forKey: key) }
        }
    }

    private func serve(_ connection: NWConnection) async {
        let watchdog = Watchdog(connection: connection, seconds: timeouts.ready)
        defer { watchdog.stop() }
        guard await Self.ready(connection) else {
            events(.connectionRejected)
            return
        }
        // 요청을 읽기 전에 한 번만 묻는다. 두 번째 답은 nil이다.
        let peer: String?
        switch admission {
        case .bridge(let bridge): peer = bridge.origin(of: connection)?.peer.stableID
        case .acceptAllForTesting(let stableID): peer = stableID
        }
        guard let peer else {
            events(.connectionRejected)
            return
        }
        events(.connection(peerStableID: peer))

        watchdog.extend(seconds: timeouts.head)
        var buffer: [UInt8] = []
        var outcome = HTTPRequestParser.parse(buffer)
        while outcome == .needMore {
            guard case .bytes(let more) = await Self.receive(connection) else { return }
            buffer += more
            outcome = HTTPRequestParser.parse(buffer)
        }
        watchdog.extend(seconds: timeouts.idle)
        switch outcome {
        case .needMore:
            return
        case .reject(let status):
            await respond(connection, watchdog: watchdog, peer: peer, method: nil, route: nil,
                          plan: .bytes(status: status, headers: [], body: []), isHead: false)
        case .request(let request):
            let (route, plan) = HostRouter.plan(request, content: content, domain: domain)
            await respond(connection, watchdog: watchdog, peer: peer, method: request.method, route: route, plan: plan,
                          isHead: request.method == .head, request: request)
        }
    }

    private func respond(_ connection: NWConnection, watchdog: Watchdog, peer: String, method: HTTPRequest.Method?, route: Route?,
                         plan: ResponsePlan, isHead: Bool, request: HTTPRequest? = nil) async {
        let started = ContinuousClock.now
        var record = ResponseRecord(method: method, route: route, status: 0, bodyBytes: 0, seconds: 0, completed: false,
                                    peerStableID: peer)
        defer {
            record.seconds = Self.seconds(started.duration(to: .now))
            events(.response(record))
        }
        switch plan {
        case .bytes(let status, let headers, let body):
            record.status = status
            let head = ResponseHead.serialize(status: status, contentLength: UInt64(body.count), headers: headers)
            guard await Self.send(connection, isHead ? head : head + body) else { return }
            record.bodyBytes = isHead ? 0 : UInt64(body.count)
        case .file(let path, let headers):
            let source: FileSource
            do {
                source = try FileSource(path: path)
            } catch {
                record.status = 500
                _ = await Self.send(connection, ResponseHead.serialize(status: 500, contentLength: 0, headers: []))
                return
            }
            let response = FileResponse.make(length: source.length, request: request ?? HTTPRequest(method: .get, path: ""),
                                             baseHeaders: headers)
            record.status = response.status
            let head = ResponseHead.serialize(status: response.status, contentLength: response.count, headers: response.headers)
            guard await Self.send(connection, head) else { return }
            watchdog.extend(seconds: timeouts.idle)
            if !isHead {
                var sent: UInt64 = 0
                while sent < response.count {
                    let count = Int(min(UInt64(Self.sendChunk), response.count - sent))
                    guard let chunk = try? source.read(at: response.offset + sent, count: count) else { return }
                    guard await Self.send(connection, chunk) else { return }
                    sent += UInt64(count)
                    record.bodyBytes = sent
                    watchdog.extend(seconds: timeouts.idle)
                }
            }
        }
        // 쓰기를 닫는다(TLS는 close_notify). 상대가 닫기를 잠깐 기다려 마지막 바이트가 RST에 잘리지 않게 한다.
        guard await Self.send(connection, [], final: true) else { return }
        record.completed = true
        watchdog.extend(seconds: 2)
        while case .bytes = await Self.receive(connection) {}
    }

    // MARK: - NWConnection의 비동기 감싸개

    enum Received: Sendable { case bytes([UInt8]), end }

    /// `.ready`가 되면 참. 준비 전에 `.failed`·`.cancelled`·`.waiting`이면 거짓.
    static func ready(_ connection: NWConnection) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Mutex<CheckedContinuation<Bool, Never>?>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.withLock { $0.take() }?.resume(returning: true)
                case .failed, .cancelled, .waiting: once.withLock { $0.take() }?.resume(returning: false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "swiftail-host.connection"))
        }
    }

    static func receive(_ connection: NWConnection) async -> Received {
        await withCheckedContinuation { (continuation: CheckedContinuation<Received, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: receiveChunk) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: .bytes([UInt8](data))) }
                else if error != nil || isComplete { continuation.resume(returning: .end) }
                else { continuation.resume(returning: .bytes([])) }
            }
        }
    }

    /// 보내고 네트워크 스택이 받아 갈 때까지 기다린다. 실패하면 거짓. `final`이면 쓰기 방향을 닫는다.
    static func send(_ connection: NWConnection, _ bytes: [UInt8], final: Bool = false) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: bytes.isEmpty ? nil : Data(bytes), contentContext: final ? .finalMessage : .defaultMessage,
                            isComplete: true, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// 기한이 지나면 연결을 끊는다. 진전이 있을 때마다 `extend`로 기한을 민다. 끊긴 연결의 받기·보내기는 곧바로 끝난다.
final class Watchdog: Sendable {
    private let deadline: Mutex<ContinuousClock.Instant>
    private let task: Mutex<Task<Void, Never>?>

    init(connection: NWConnection, seconds: Double) {
        deadline = Mutex(.now + .milliseconds(Int(seconds * 1000)))
        task = Mutex(nil)
        let watched = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if ContinuousClock.now > self.deadline.withLock({ $0 }) {
                    connection.cancel()
                    return
                }
            }
        }
        task.withLock { $0 = watched }
    }

    func extend(seconds: Double) {
        deadline.withLock { $0 = .now + .milliseconds(Int(seconds * 1000)) }
    }

    func stop() {
        task.withLock { $0?.cancel() }
    }
}

/// `TailnetCertificate` → TLS 신원. 키체인을 쓰지 않는다: 키는 `SecKeyCreateWithData`(메모리의 키), 신원은
/// `SecIdentityCreate`, 중간 인증서는 `sec_identity_create_with_certificates`로 싣는다(Swiftail 계약 6절의 조각).
enum TLSIdentity {
    enum Failure: Error, Equatable {
        case key
        case certificate
        case identity
    }

    static func make(_ certificate: TailnetCertificate) throws(Failure) -> sec_identity_t {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(Data(certificate.privateKey.x963Representation) as CFData,
                                             attributes as CFDictionary, nil) else { throw .key }
        var certificates: [SecCertificate] = []
        for der in certificate.chain {
            guard let value = SecCertificateCreateWithData(nil, Data(der) as CFData) else { throw .certificate }
            certificates.append(value)
        }
        guard let leaf = certificates.first, let identity = SecIdentityCreate(nil, leaf, key) else { throw .identity }
        // leaf 뒤의 사슬만 넘긴다. leaf까지 넣으면 서버가 leaf를 두 번 보낸다.
        guard let value = sec_identity_create_with_certificates(identity, Array(certificates.dropFirst()) as CFArray) else {
            throw .identity
        }
        return value
    }
}
