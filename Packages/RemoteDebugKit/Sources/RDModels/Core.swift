import Foundation

/// protocol §9 `rd_start` 설정(+ docs/tunnel.md의 터널 모드, docs/protocol-addenda.md A.1의 선택 필드).
///
/// 선택 필드는 값이 있을 때만 인코딩한다: `utunFd`·`mtu`는 nil이 아닐 때, `hostDisplayName`·`appVersion`은
/// nil도 빈 문자열도 아닐 때. 그래서 호스트·프록시 설정의 JSON은 §9 예시와 키가 같다.
public struct CoreConfig: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, Hashable {
        case host
        case proxy
        /// docs/tunnel.md: 패킷 터널 확장. `utunFd`가 필요하다.
        case tunnel
    }

    public var mode: Mode
    public var stateDir: String
    public var hostname: String
    public var authKey: String
    public var controlURL: String
    public var ephemeral: Bool
    public var listenTLS: Bool
    public var port: Int
    public var publishDir: String
    public var allowedTargets: [String]
    public var goMemLimitMiB: Int
    public var logPath: String
    /// 터널 모드: 터널 확장이 찾은 utun 소켓의 파일 디스크립터(코어가 소유권을 가져간다).
    public var utunFd: Int?
    /// 터널 모드: 인터페이스 MTU.
    public var mtu: Int?
    /// `/v1/info`의 `hostName`. 비면 코어가 `hostname`을 쓴다.
    public var hostDisplayName: String?
    /// `/v1/info`의 `appVersion`.
    public var appVersion: String?

    public init(
        mode: Mode,
        stateDir: String,
        hostname: String,
        authKey: String = "",
        controlURL: String = "",
        ephemeral: Bool = false,
        listenTLS: Bool = true,
        port: Int = 443,
        publishDir: String = "",
        allowedTargets: [String] = [],
        goMemLimitMiB: Int = 0,
        logPath: String = "",
        utunFd: Int? = nil,
        mtu: Int? = nil,
        hostDisplayName: String? = nil,
        appVersion: String? = nil
    ) {
        self.mode = mode
        self.stateDir = stateDir
        self.hostname = hostname
        self.authKey = authKey
        self.controlURL = controlURL
        self.ephemeral = ephemeral
        self.listenTLS = listenTLS
        self.port = port
        self.publishDir = publishDir
        self.allowedTargets = allowedTargets
        self.goMemLimitMiB = goMemLimitMiB
        self.logPath = logPath
        self.utunFd = utunFd
        self.mtu = mtu
        self.hostDisplayName = hostDisplayName
        self.appVersion = appVersion
    }

    enum CodingKeys: String, CodingKey {
        case mode, stateDir, hostname, authKey, controlURL, ephemeral, listenTLS, port
        case publishDir, allowedTargets, goMemLimitMiB, logPath
        case utunFd, mtu, hostDisplayName, appVersion
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(stateDir, forKey: .stateDir)
        try c.encode(hostname, forKey: .hostname)
        try c.encode(authKey, forKey: .authKey)
        try c.encode(controlURL, forKey: .controlURL)
        try c.encode(ephemeral, forKey: .ephemeral)
        try c.encode(listenTLS, forKey: .listenTLS)
        try c.encode(port, forKey: .port)
        try c.encode(publishDir, forKey: .publishDir)
        try c.encode(allowedTargets, forKey: .allowedTargets)
        try c.encode(goMemLimitMiB, forKey: .goMemLimitMiB)
        try c.encode(logPath, forKey: .logPath)
        try c.encodeIfPresent(utunFd, forKey: .utunFd)
        try c.encodeIfPresent(mtu, forKey: .mtu)
        if let hostDisplayName, !hostDisplayName.isEmpty { try c.encode(hostDisplayName, forKey: .hostDisplayName) }
        if let appVersion, !appVersion.isEmpty { try c.encode(appVersion, forKey: .appVersion) }
    }
}

/// `backendState`. 모르는 값도 그대로 담는다.
public struct BackendState: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let stopped: BackendState = "Stopped"
    public static let starting: BackendState = "Starting"
    public static let needsLogin: BackendState = "NeedsLogin"
    public static let needsMachineAuth: BackendState = "NeedsMachineAuth"
    public static let running: BackendState = "Running"
    public static let error: BackendState = "Error"
}

/// protocol §9 `rd_status` 출력. 코어가 `null`·누락으로 보낸 값은 빈 값으로 읽는다.
public struct CoreStatus: Codable, Sendable, Hashable {
    public var backendState: BackendState
    public var authURL: String
    public var hostname: String
    public var fqdn: String
    public var tailscaleIPs: [String]
    public var certDomains: [String]
    public var tlsReady: Bool
    public var listening: Bool
    public var publishedBuilds: Int
    public var pairedDevices: Int
    public var rssMiB: Double
    /// docs/protocol-addenda.md A.5: `backendState == Error`일 때만 있다.
    public var errorMessage: String?
    /// docs/tunnel.md: 터널 모드에서만 있다.
    public var tunnel: TunnelStatus?

    public init(
        backendState: BackendState,
        authURL: String = "",
        hostname: String = "",
        fqdn: String = "",
        tailscaleIPs: [String] = [],
        certDomains: [String] = [],
        tlsReady: Bool = false,
        listening: Bool = false,
        publishedBuilds: Int = 0,
        pairedDevices: Int = 0,
        rssMiB: Double = 0,
        errorMessage: String? = nil,
        tunnel: TunnelStatus? = nil
    ) {
        self.backendState = backendState
        self.authURL = authURL
        self.hostname = hostname
        self.fqdn = fqdn
        self.tailscaleIPs = tailscaleIPs
        self.certDomains = certDomains
        self.tlsReady = tlsReady
        self.listening = listening
        self.publishedBuilds = publishedBuilds
        self.pairedDevices = pairedDevices
        self.rssMiB = rssMiB
        self.errorMessage = errorMessage
        self.tunnel = tunnel
    }

    enum CodingKeys: String, CodingKey {
        case backendState, authURL, hostname, fqdn, tailscaleIPs, certDomains
        case tlsReady, listening, publishedBuilds, pairedDevices, rssMiB
        case errorMessage, tunnel
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backendState = try c.decode(BackendState.self, forKey: .backendState)
        authURL = try c.decodeIfPresent(String.self, forKey: .authURL) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        fqdn = try c.decodeIfPresent(String.self, forKey: .fqdn) ?? ""
        tailscaleIPs = try c.decodeIfPresent([String].self, forKey: .tailscaleIPs) ?? []
        certDomains = try c.decodeIfPresent([String].self, forKey: .certDomains) ?? []
        tlsReady = try c.decodeIfPresent(Bool.self, forKey: .tlsReady) ?? false
        listening = try c.decodeIfPresent(Bool.self, forKey: .listening) ?? false
        publishedBuilds = try c.decodeIfPresent(Int.self, forKey: .publishedBuilds) ?? 0
        pairedDevices = try c.decodeIfPresent(Int.self, forKey: .pairedDevices) ?? 0
        rssMiB = try c.decodeIfPresent(Double.self, forKey: .rssMiB) ?? 0
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        tunnel = try c.decodeIfPresent(TunnelStatus.self, forKey: .tunnel)
    }
}

/// docs/tunnel.md `rd_status.tunnel`. 코어가 `null`로 보낸 배열은 빈 배열로 읽는다.
public struct TunnelStatus: Codable, Sendable, Hashable {
    public var addresses: [String]
    public var routes: [String]
    public var dnsServers: [String]
    public var dnsMatchDomains: [String]
    public var mtu: Int
    public var peerCount: Int

    public init(addresses: [String] = [], routes: [String] = [], dnsServers: [String] = [], dnsMatchDomains: [String] = [], mtu: Int = 0, peerCount: Int = 0) {
        self.addresses = addresses
        self.routes = routes
        self.dnsServers = dnsServers
        self.dnsMatchDomains = dnsMatchDomains
        self.mtu = mtu
        self.peerCount = peerCount
    }

    enum CodingKeys: String, CodingKey { case addresses, routes, dnsServers, dnsMatchDomains, mtu, peerCount }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        routes = try c.decodeIfPresent([String].self, forKey: .routes) ?? []
        dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        dnsMatchDomains = try c.decodeIfPresent([String].self, forKey: .dnsMatchDomains) ?? []
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu) ?? 0
        peerCount = try c.decodeIfPresent(Int.self, forKey: .peerCount) ?? 0
    }
}

/// `rd_next_event`의 반환 래퍼: `{"event":{…}}` 또는 `{"event":null}`(시간 초과).
/// `event` 키는 반드시 있어야 한다. C API 오류 응답(`{"error":{…}}`)은 "이벤트 없음"으로 읽지 않고 디코딩에 실패한다.
/// 호출자는 그때 `APIErrorBody`로 다시 읽는다.
public struct NextEventResponse: Codable, Sendable, Hashable {
    public var event: CoreEvent?

    public init(event: CoreEvent?) { self.event = event }

    enum CodingKeys: String, CodingKey { case event }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.event) else {
            throw DecodingError.keyNotFound(CodingKeys.event, .init(codingPath: c.codingPath, debugDescription: "event 키가 없습니다(오류 응답일 수 있음)"))
        }
        event = try c.decodeNil(forKey: .event) ? nil : c.decode(CoreEvent.self, forKey: .event)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let event { try c.encode(event, forKey: .event) } else { try c.encodeNil(forKey: .event) }
    }
}
