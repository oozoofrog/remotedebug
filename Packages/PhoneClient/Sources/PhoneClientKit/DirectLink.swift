import Foundation
import RDModels

// 같은 네트워크 직접 연결(docs/protocol-addenda.md O)의 iPhone 쪽 규칙.
// 시스템에 닿는 부분(Keychain, Bonjour, 네트워크 경로, 공개 키를 고정한 TLS)은 프로토콜 뒤에 두고
// 실제 구현은 DirectSystem.swift에 있다.

/// 직접 연결 리스너의 주소. `host`는 IP 주소다(이름이 아니다).
public struct DirectEndpoint: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Mac에 등록해 받은 값. 토큰이 들어 있어 Keychain에만 둔다.
public struct DirectCredential: Codable, Equatable, Sendable {
    /// 이 값을 받은 Mac(`PairedHost.hostId`).
    public var hostId: String
    /// Mac이 Bonjour로 광고하는 인스턴스 이름.
    public var directId: String
    public var deviceId: String
    public var token: String
    /// 리스너 인증서의 SubjectPublicKeyInfo SHA-256(base64).
    public var spki: String
    public var port: Int
    /// 마지막으로 연결된 Mac의 IP 주소.
    public var lastAddress: String?

    public init(hostId: String, directId: String, deviceId: String, token: String, spki: String, port: Int, lastAddress: String? = nil) {
        self.hostId = hostId
        self.directId = directId
        self.deviceId = deviceId
        self.token = token
        self.spki = spki
        self.port = port
        self.lastAddress = lastAddress
    }

    /// `Authorization` 헤더 값.
    var authorization: String { "RD-Device \(deviceId).\(token)" }
}

/// 등록 값을 보관한다. 두 iPhone 앱은 같은 tailnet 기기라 Mac에 토큰이 하나뿐이다.
/// 그래서 같은 보관소를 함께 써야 서로의 토큰을 무효로 만들지 않는다.
public protocol DirectCredentialStoring: Sendable {
    func load() -> DirectCredential?
    func save(_ credential: DirectCredential)
    func clear()
}

/// 같은 네트워크에서 Mac의 광고를 찾는다. 로컬 네트워크 권한이 없거나 찾지 못하면 `nil`.
public protocol DirectBrowsing: Sendable {
    func find(directId: String, timeout: Duration) async -> DirectEndpoint?
}

/// Wi-Fi(또는 유선)에 붙어 있는지. 셀룰러뿐이면 직접 연결을 찾지 않는다.
public protocol LocalNetworkChecking: Sendable {
    var isOnLocalNetwork: Bool { get }
}

/// 인증서의 공개 키가 `pin`일 때만 연결하는 전송을 만든다. 이름과 시스템 신뢰는 보지 않는다.
/// 고정 값이 다르면 TLS 연결 단계에서 끊어, 요청(토큰)은 보내지 않는다.
public protocol DirectTransportMaking: Sendable {
    func transport(pin: String) -> any HTTPTransport
}

/// Mac까지 가는 경로를 고른다: 같은 네트워크면 직접, 아니면 `nil`(부른 쪽이 VPN 경로를 쓴다).
@MainActor
public final class DirectRoute {
    public struct Timing: Sendable {
        /// 마지막으로 알던 주소에 `/v1/info`를 물어보는 제한 시간.
        public var probeTimeout: TimeInterval
        /// Bonjour로 찾는 제한 시간.
        public var browseTimeout: Duration
        /// 직접 연결을 찾지 못한 뒤 다시 찾기까지의 시간.
        public var retryAfter: TimeInterval
        /// Mac이 직접 연결을 모르거나 꺼 두었을 때 다시 등록해 보기까지의 시간.
        public var enrollRetryAfter: TimeInterval

        public init(probeTimeout: TimeInterval = 1, browseTimeout: Duration = .seconds(2), retryAfter: TimeInterval = 60, enrollRetryAfter: TimeInterval = 600) {
            self.probeTimeout = probeTimeout
            self.browseTimeout = browseTimeout
            self.retryAfter = retryAfter
            self.enrollRetryAfter = enrollRetryAfter
        }

        public static let standard = Timing()
    }

    private enum State: Equatable {
        /// 아직 찾아보지 않았다(시작, 네트워크 변경, 앱 활성, 연결 오류 뒤).
        case unknown
        case direct(DirectEndpoint)
        /// 찾지 못했다. `retryAfter`가 지나면 다시 찾는다.
        case unavailable(since: Date)
    }

    private enum Probe { case ok, unreachable, rejected }

    private let store: any DirectCredentialStoring
    private let browser: any DirectBrowsing
    private let network: any LocalNetworkChecking
    private let transports: any DirectTransportMaking
    private let clock: any PollingClock
    private let timing: Timing

    private var credential: DirectCredential?
    private var state: State = .unknown
    /// 직접 경로가 토큰을 거절했다. tailnet으로 다시 등록해야 한다.
    private var rejectedToken: String?
    private var enrollBlockedUntil: Date?
    /// 이 앱이 마지막으로 등록해 받은 토큰. Mac이 방금 준 토큰마저 거절하면 등록을 되풀이하지 않는다.
    private var issuedToken: String?
    private var discovery: Task<DirectEndpoint?, Never>?
    private var transport: (pin: String, value: any HTTPTransport)?

    public init(
        store: any DirectCredentialStoring,
        browser: any DirectBrowsing,
        network: any LocalNetworkChecking,
        transports: any DirectTransportMaking,
        clock: any PollingClock = SystemPollingClock(),
        timing: Timing = .standard
    ) {
        self.store = store
        self.browser = browser
        self.network = network
        self.transports = transports
        self.clock = clock
        self.timing = timing
        self.credential = store.load()
    }

    /// 지금 직접 경로를 쓰고 있다.
    public var isDirect: Bool {
        if case .direct = state { return true }
        return false
    }

    /// 이 Mac에 등록해 두었는가.
    public func isEnrolled(for host: PairedHost) -> Bool {
        credential?.hostId == host.hostId && rejectedToken == nil
    }

    /// 직접 경로를 써 볼 만한가: 등록했고, Wi-Fi에 있고, 방금 실패해 쉬는 중이 아니다. 네트워크를 건드리지 않는다.
    public func mayReach(_ host: PairedHost) -> Bool {
        guard isEnrolled(for: host), network.isOnLocalNetwork else { return false }
        if case .unavailable(let since) = state { return clock.now.timeIntervalSince(since) >= timing.retryAfter }
        return true
    }

    /// 직접 경로의 API. 쓸 수 없으면 `nil`.
    /// 처음이거나 다시 찾을 때가 됐으면 마지막 주소 확인(1초)과 Bonjour 찾기(2초)를 함께 한다.
    public func api(for host: PairedHost, client: ClientInfo, timeouts: HostAPI.Timeouts) async -> HostAPI? {
        guard mayReach(host), let credential else {
            if !network.isOnLocalNetwork, isDirect { state = .unknown }
            return nil
        }
        var endpoint: DirectEndpoint?
        if case .direct(let known) = state {
            endpoint = known
        } else {
            let task = discovery ?? Task { [weak self] in await self?.discover(credential, host: host, client: client) ?? nil }
            discovery = task
            endpoint = await task.value
            if discovery == task { discovery = nil }
            // 찾는 동안 등록이 바뀌었거나 거절됐으면 쓰지 않는다.
            guard self.credential == credential || self.credential?.token == credential.token, rejectedToken == nil else { return nil }
            if let endpoint {
                state = .direct(endpoint)
                remember(endpoint)
            } else if state == .unknown {
                state = .unavailable(since: clock.now)
            }
        }
        guard let endpoint, let current = self.credential else { return nil }
        return HostAPI(direct: endpoint, authorization: current.authorization, transport: pinned(current.spki), client: client, timeouts: timeouts)
    }

    /// 직접 경로의 요청이 연결 오류로 끝났다. 한 번은 바로 다시 찾고(`final == false`), 또 실패하면 `retryAfter` 동안 쉰다.
    public func connectionFailed(final: Bool) {
        state = final ? .unavailable(since: clock.now) : .unknown
    }

    /// 직접 경로가 토큰을 거절했다(403) 또는 시도가 막혔다(429). tailnet 경로로 다시 등록할 때까지 쓰지 않는다.
    public func rejected() {
        rejectedToken = credential?.token
        state = .unknown
        if let issuedToken, issuedToken == credential?.token {
            // 방금 받은 토큰이 거절됐다(Mac이 저장하지 못했다 등). 요청마다 다시 등록하지 않게 한동안 VPN 경로만 쓴다.
            enrollBlockedUntil = clock.now.addingTimeInterval(timing.enrollRetryAfter)
            self.issuedToken = nil
        }
    }

    /// 네트워크가 바뀌었거나 앱이 다시 활성이 됐다. 다음 요청에서 다시 찾는다.
    /// 짝 앱이 그사이 다시 등록했을 수 있으므로 보관소도 다시 읽는다.
    public func invalidate() {
        state = .unknown
        adoptStored()
    }

    /// 페어링을 지웠다.
    public func forget() {
        store.clear()
        credential = nil
        rejectedToken = nil
        issuedToken = nil
        enrollBlockedUntil = nil
        state = .unknown
    }

    /// tailnet 경로로 요청이 성공한 뒤 부른다. 등록이 없거나 거절됐으면 등록한다.
    /// Mac이 직접 연결을 모르거나(예전 버전) 꺼 두었으면 한동안 다시 묻지 않는다.
    public func enrollIfNeeded(using api: HostAPI, host: PairedHost) async {
        guard !api.isDirect, !isEnrolled(for: host) else { return }
        // 짝 앱이 이미 다시 등록했으면 그 값을 쓴다(또 등록하면 짝 앱의 토큰이 무효가 된다).
        adoptStored()
        guard !isEnrolled(for: host) else { return }
        if let until = enrollBlockedUntil, clock.now < until { return }
        do {
            let e = try await api.enrollDirect()
            let fresh = DirectCredential(hostId: host.hostId, directId: e.directId, deviceId: e.deviceId, token: e.token, spki: e.tlsSPKI,
                                         port: e.port, lastAddress: credential?.hostId == host.hostId ? credential?.lastAddress : nil)
            store.save(fresh)
            credential = fresh
            issuedToken = fresh.token
            rejectedToken = nil
            enrollBlockedUntil = nil
            state = .unknown
        } catch let error as HostAPIError where error.status == 404 || error.status == 405 {
            enrollBlockedUntil = clock.now.addingTimeInterval(timing.enrollRetryAfter)
        } catch {
            // 연결 오류 등: 다음 tailnet 요청 뒤에 다시 해 본다.
        }
    }

    // MARK: -

    private func adoptStored() {
        let stored = store.load()
        guard stored != credential else { return }
        if let stored, stored.token != rejectedToken { rejectedToken = nil }
        credential = stored
        state = .unknown
    }

    private func pinned(_ pin: String) -> any HTTPTransport {
        if let transport, transport.pin == pin { return transport.value }
        let made = transports.transport(pin: pin)
        transport = (pin, made)
        return made
    }

    private func remember(_ endpoint: DirectEndpoint) {
        guard var current = credential, current.lastAddress != endpoint.host || current.port != endpoint.port else { return }
        current.lastAddress = endpoint.host
        current.port = endpoint.port
        credential = current
        store.save(current)
    }

    /// 마지막 주소와 Bonjour를 함께 시도해 `/v1/info`가 페어링한 Mac의 것인 주소를 돌려준다.
    private func discover(_ credential: DirectCredential, host: PairedHost, client: ClientInfo) async -> DirectEndpoint? {
        let browser = browser
        let browseTimeout = timing.browseTimeout
        async let browsed = browser.find(directId: credential.directId, timeout: browseTimeout)
        let last = credential.lastAddress.map { DirectEndpoint(host: $0, port: credential.port) }
        if let last {
            switch await probe(last, credential: credential, host: host, client: client) {
            case .ok: return last  // 범위를 벗어나며 Bonjour 찾기는 취소된다.
            case .rejected: return nil
            case .unreachable: break
            }
        }
        guard let found = await browsed, found != last else { return nil }
        return await probe(found, credential: credential, host: host, client: client) == .ok ? found : nil
    }

    private func probe(_ endpoint: DirectEndpoint, credential: DirectCredential, host: PairedHost, client: ClientInfo) async -> Probe {
        let timeouts = HostAPI.Timeouts(request: timing.probeTimeout, createSession: timing.probeTimeout)
        guard let api = HostAPI(direct: endpoint, authorization: credential.authorization, transport: pinned(credential.spki), client: client, timeouts: timeouts) else {
            return .unreachable
        }
        do {
            let info = try await api.info()
            // 공개 키가 같아도 다른 Mac(같은 상태 폴더를 옮긴 경우 등)이면 쓰지 않는다.
            return info.hostId == host.hostId && info.protocolVersion == 1 ? .ok : .unreachable
        } catch let error as HostAPIError where error.code == "not_paired" || error.code == "too_many_attempts" {
            rejected()
            return .rejected
        } catch {
            return .unreachable
        }
    }
}

/// 메모리 보관(테스트·미리보기용).
public final class InMemoryDirectCredentialStore: DirectCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: DirectCredential?

    public init(_ value: DirectCredential? = nil) { self.value = value }

    public func load() -> DirectCredential? { lock.withLock { value } }
    public func save(_ credential: DirectCredential) { lock.withLock { value = credential } }
    public func clear() { lock.withLock { value = nil } }
}
