import Foundation

public struct PairRequestEvent: Codable, Sendable, Hashable {
    public var requestId: String
    public var deviceName: String
    public var nodeName: String
    public var loginName: String
    public var expiresAt: Date

    public init(requestId: String, deviceName: String, nodeName: String, loginName: String, expiresAt: Date) {
        self.requestId = requestId
        self.deviceName = deviceName
        self.nodeName = nodeName
        self.loginName = loginName
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case requestId, deviceName, nodeName, loginName, expiresAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        nodeName = try c.decode(String.self, forKey: .nodeName)
        loginName = try c.decode(String.self, forKey: .loginName)
        expiresAt = try c.decodeRDDate(forKey: .expiresAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(nodeName, forKey: .nodeName)
        try c.encode(loginName, forKey: .loginName)
        try c.encodeRDDate(expiresAt, forKey: .expiresAt)
    }
}

public struct PairDecidedEvent: Codable, Sendable, Hashable {
    public var requestId: String
    public var state: PairState

    public init(requestId: String, state: PairState) {
        self.requestId = requestId
        self.state = state
    }
}

public struct DeniedEvent: Codable, Sendable, Hashable {
    public var path: String
    public var reason: String
    public var nodeName: String?
    /// docs/protocol-addenda.md D.1: 속도 제한으로 이 이벤트 전에 생략한 같은 노드·경로의 `denied` 수. 생략이 없으면 없다.
    public var suppressed: Int?

    public init(path: String, reason: String, nodeName: String? = nil, suppressed: Int? = nil) {
        self.path = path
        self.reason = reason
        self.nodeName = nodeName
        self.suppressed = suppressed
    }
}

/// docs/tunnel.md `network-settings` 이벤트. 터널 확장이 `NEPacketTunnelNetworkSettings`로 바꿔 적용한다.
/// 코어가 `null`로 보낸 배열은 빈 배열로 읽는다.
public struct NetworkSettingsEvent: Codable, Sendable, Hashable {
    public var addresses: [String]
    public var routes: [String]
    public var dnsServers: [String]
    public var dnsMatchDomains: [String]
    public var mtu: Int

    public init(addresses: [String], routes: [String], dnsServers: [String], dnsMatchDomains: [String], mtu: Int) {
        self.addresses = addresses
        self.routes = routes
        self.dnsServers = dnsServers
        self.dnsMatchDomains = dnsMatchDomains
        self.mtu = mtu
    }

    enum CodingKeys: String, CodingKey { case addresses, routes, dnsServers, dnsMatchDomains, mtu }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        routes = try c.decodeIfPresent([String].self, forKey: .routes) ?? []
        dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        dnsMatchDomains = try c.decodeIfPresent([String].self, forKey: .dnsMatchDomains) ?? []
        mtu = try c.decode(Int.self, forKey: .mtu)
    }
}

public struct SessionEvent: Codable, Sendable, Hashable {
    public var sessionId: String
    public var buildId: String
    public var nodeName: String
    public var state: SessionState
    public var userAgent: String
    public var bytesServed: Int64

    public init(sessionId: String, buildId: String, nodeName: String, state: SessionState, userAgent: String, bytesServed: Int64) {
        self.sessionId = sessionId
        self.buildId = buildId
        self.nodeName = nodeName
        self.state = state
        self.userAgent = userAgent
        self.bytesServed = bytesServed
    }
}

public struct LogEvent: Codable, Sendable, Hashable {
    public var level: String
    public var message: String

    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }
}

/// protocol §10. `type` 필드로 구분하며 모르는 type은 `.unknown`으로 읽는다.
public enum CoreEvent: Codable, Sendable, Hashable {
    case state(CoreStatus)
    case pairRequest(PairRequestEvent)
    case pairDecided(PairDecidedEvent)
    case deviceAdded(DeviceEntry)
    case denied(DeniedEvent)
    case session(SessionEvent)
    case log(LogEvent)
    /// docs/tunnel.md
    case networkSettings(NetworkSettingsEvent)
    /// docs/protocol-addenda.md G.
    case deviceLog(DeviceLogEvent)
    /// docs/protocol-addenda.md L.
    case deviceCrash(DeviceCrashEvent)
    /// 허용 목록의 기기가 에이전트에 보낸 요청(addenda K).
    case agentRequest(AgentRequestEvent)
    case agentCancel(AgentCancelEvent)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey {
        case type, status, device
    }

    public var type: String {
        switch self {
        case .state: "state"
        case .pairRequest: "pair-request"
        case .pairDecided: "pair-decided"
        case .deviceAdded: "device-added"
        case .denied: "denied"
        case .session: "session"
        case .log: "log"
        case .networkSettings: "network-settings"
        case .deviceLog: "device-log"
        case .deviceCrash: "device-crash"
        case .agentRequest: "agent-request"
        case .agentCancel: "agent-cancel"
        case .unknown(let type): type
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "state": self = .state(try c.decode(CoreStatus.self, forKey: .status))
        case "pair-request": self = .pairRequest(try PairRequestEvent(from: decoder))
        case "pair-decided": self = .pairDecided(try PairDecidedEvent(from: decoder))
        case "device-added": self = .deviceAdded(try c.decode(DeviceEntry.self, forKey: .device))
        case "denied": self = .denied(try DeniedEvent(from: decoder))
        case "session": self = .session(try SessionEvent(from: decoder))
        case "log": self = .log(try LogEvent(from: decoder))
        case "network-settings": self = .networkSettings(try NetworkSettingsEvent(from: decoder))
        case "device-log": self = .deviceLog(try DeviceLogEvent(from: decoder))
        case "device-crash": self = .deviceCrash(try DeviceCrashEvent(from: decoder))
        case "agent-request": self = .agentRequest(try AgentRequestEvent(from: decoder))
        case "agent-cancel": self = .agentCancel(try AgentCancelEvent(from: decoder))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .state(let s): try c.encode(s, forKey: .status)
        case .pairRequest(let e): try e.encode(to: encoder)
        case .pairDecided(let e): try e.encode(to: encoder)
        case .deviceAdded(let d): try c.encode(d, forKey: .device)
        case .denied(let e): try e.encode(to: encoder)
        case .session(let e): try e.encode(to: encoder)
        case .log(let e): try e.encode(to: encoder)
        case .networkSettings(let e): try e.encode(to: encoder)
        case .deviceLog(let e): try e.encode(to: encoder)
        case .deviceCrash(let e): try e.encode(to: encoder)
        case .agentRequest(let e): try e.encode(to: encoder)
        case .agentCancel(let e): try e.encode(to: encoder)
        case .unknown: break
        }
    }
}
