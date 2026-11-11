import Foundation

/// `GET /v1/info` (protocol §4.2)
public struct InfoResponse: Codable, Sendable, Hashable {
    public var hostId: String
    public var hostName: String
    public var fqdn: String
    /// JSON 키는 `protocol`.
    public var protocolVersion: Int
    public var appVersion: String
    public var buildCount: Int

    public init(hostId: String, hostName: String, fqdn: String, protocolVersion: Int, appVersion: String, buildCount: Int) {
        self.hostId = hostId
        self.hostName = hostName
        self.fqdn = fqdn
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.buildCount = buildCount
    }

    enum CodingKeys: String, CodingKey {
        case hostId, hostName, fqdn
        case protocolVersion = "protocol"
        case appVersion, buildCount
    }
}

/// `GET /v1/builds`. `builds` 키는 반드시 있어야 한다(`null`은 빈 목록). 오류 본문(`{"error":…}`)은 디코딩에 실패하므로
/// 호출자는 `APIErrorBody`로 다시 읽는다.
public struct BuildsResponse: Codable, Sendable, Hashable {
    public var builds: [BuildDescriptor]

    public init(builds: [BuildDescriptor]) {
        self.builds = builds
    }

    enum CodingKeys: String, CodingKey { case builds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.builds) else {
            throw DecodingError.keyNotFound(CodingKeys.builds, .init(codingPath: c.codingPath, debugDescription: "builds 키가 없습니다(오류 응답일 수 있음)"))
        }
        builds = try c.decodeNil(forKey: .builds) ? [] : c.decode([BuildDescriptor].self, forKey: .builds)
    }
}

/// `POST /v1/pair/request` 요청 본문 (protocol §4.3)
public struct PairRequestBody: Codable, Sendable, Hashable {
    public var code: String
    public var deviceName: String
    public var platform: String
    public var clientVersion: String

    public init(code: String, deviceName: String, platform: String, clientVersion: String) {
        self.code = code
        self.deviceName = deviceName
        self.platform = platform
        self.clientVersion = clientVersion
    }
}

public enum PairState: String, Codable, Sendable, Hashable {
    case pending, approved, denied, expired
}

/// `POST /v1/pair/request` 응답(202, `expiresAt` 있음)과
/// `GET /v1/pair/request/{requestId}` 응답(`approved`일 때 `host` 있음)을 함께 표현한다.
public struct PairRequestState: Codable, Sendable, Hashable {
    public var requestId: String
    public var state: PairState
    public var expiresAt: Date?
    public var host: HostSummary?

    public init(requestId: String, state: PairState, expiresAt: Date? = nil, host: HostSummary? = nil) {
        self.requestId = requestId
        self.state = state
        self.expiresAt = expiresAt
        self.host = host
    }

    enum CodingKeys: String, CodingKey { case requestId, state, expiresAt, host }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        state = try c.decode(PairState.self, forKey: .state)
        expiresAt = try c.decodeRDDateIfPresent(forKey: .expiresAt)
        host = try c.decodeIfPresent(HostSummary.self, forKey: .host)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(state, forKey: .state)
        if let expiresAt { try c.encodeRDDate(expiresAt, forKey: .expiresAt) }
        try c.encodeIfPresent(host, forKey: .host)
    }
}

public struct HostSummary: Codable, Sendable, Hashable {
    public var hostId: String
    public var hostName: String
    public var fqdn: String

    public init(hostId: String, hostName: String, fqdn: String) {
        self.hostId = hostId
        self.hostName = hostName
        self.fqdn = fqdn
    }
}

public enum SessionState: String, Codable, Sendable, Hashable {
    case created
    case manifestServed = "manifest_served"
    case downloading
    case completed
    case expired
    case failed
}

/// `POST /v1/builds/{id}/sessions` 응답(201) (protocol §4.4)
public struct SessionResponse: Codable, Sendable, Hashable {
    public var sessionId: String
    public var state: SessionState
    public var manifestUrl: URL
    public var installUrl: URL
    public var expiresAt: Date

    public init(sessionId: String, state: SessionState, manifestUrl: URL, installUrl: URL, expiresAt: Date) {
        self.sessionId = sessionId
        self.state = state
        self.manifestUrl = manifestUrl
        self.installUrl = installUrl
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case sessionId, state, manifestUrl, installUrl, expiresAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        state = try c.decode(SessionState.self, forKey: .state)
        manifestUrl = try c.decode(URL.self, forKey: .manifestUrl)
        installUrl = try c.decode(URL.self, forKey: .installUrl)
        expiresAt = try c.decodeRDDate(forKey: .expiresAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(state, forKey: .state)
        try c.encode(manifestUrl, forKey: .manifestUrl)
        try c.encode(installUrl, forKey: .installUrl)
        try c.encodeRDDate(expiresAt, forKey: .expiresAt)
    }
}

/// `GET /v1/sessions/{sessionId}` 응답
public struct SessionStatus: Codable, Sendable, Hashable {
    public var sessionId: String
    public var buildId: String
    public var state: SessionState
    public var bytesServed: Int64
    public var size: Int64
    public var expiresAt: Date

    public init(sessionId: String, buildId: String, state: SessionState, bytesServed: Int64, size: Int64, expiresAt: Date) {
        self.sessionId = sessionId
        self.buildId = buildId
        self.state = state
        self.bytesServed = bytesServed
        self.size = size
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case sessionId, buildId, state, bytesServed, size, expiresAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        buildId = try c.decode(String.self, forKey: .buildId)
        state = try c.decode(SessionState.self, forKey: .state)
        bytesServed = try c.decode(Int64.self, forKey: .bytesServed)
        size = try c.decode(Int64.self, forKey: .size)
        expiresAt = try c.decodeRDDate(forKey: .expiresAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(buildId, forKey: .buildId)
        try c.encode(state, forKey: .state)
        try c.encode(bytesServed, forKey: .bytesServed)
        try c.encode(size, forKey: .size)
        try c.encodeRDDate(expiresAt, forKey: .expiresAt)
    }
}

/// protocol §8 오류 본문.
public struct APIErrorBody: Codable, Sendable, Hashable, Error {
    public struct Detail: Codable, Sendable, Hashable {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public var error: Detail

    public init(code: String, message: String) {
        self.error = Detail(code: code, message: message)
    }

    public init(error: Detail) {
        self.error = error
    }
}
