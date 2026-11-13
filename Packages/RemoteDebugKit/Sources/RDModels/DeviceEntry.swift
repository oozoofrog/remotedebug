import Foundation

/// docs/protocol-addenda.md P: iPhone이 등록한 APNs 기기 토큰. Mac이 새 빌드·파일 알림을 보낼 때 쓴다.
public struct PushRegistration: Codable, Sendable, Hashable {
    /// 기기 토큰(16진수 소문자).
    public var token: String
    /// 알림을 받을 앱(`apns-topic`).
    public var bundleId: String
    /// APNs 환경. 지금은 `"development"`만 쓴다.
    public var environment: String

    public init(token: String, bundleId: String, environment: String) {
        self.token = token
        self.bundleId = bundleId
        self.environment = environment
    }
}

/// protocol §5. 허용 목록 항목.
public struct DeviceEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var nodeStableId: String
    public var nodeName: String
    public var loginName: String
    public var pairedAt: Date
    /// docs/protocol-addenda.md O: 이 기기의 직접 연결 토큰의 SHA-256(16진수). 기기가 등록하기 전에는 없다.
    /// 토큰 자체는 Mac에 저장하지 않는다.
    public var directTokenHash: String?
    /// docs/protocol-addenda.md P: 알림 기기 토큰. 등록하지 않았으면 없다.
    public var push: PushRegistration?

    /// 같은 네트워크 직접 연결에 등록한 기기인가.
    public var isDirectEnrolled: Bool { directTokenHash?.isEmpty == false }

    /// 알림 기기 토큰을 등록한 기기인가.
    public var isPushRegistered: Bool { push?.token.isEmpty == false }

    public init(id: String, name: String, nodeStableId: String, nodeName: String, loginName: String, pairedAt: Date, directTokenHash: String? = nil,
                push: PushRegistration? = nil) {
        self.id = id
        self.name = name
        self.nodeStableId = nodeStableId
        self.nodeName = nodeName
        self.loginName = loginName
        self.pairedAt = pairedAt
        self.directTokenHash = directTokenHash
        self.push = push
    }

    enum CodingKeys: String, CodingKey {
        case id, name, nodeStableId, nodeName, loginName, pairedAt, directTokenHash, push
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        nodeStableId = try c.decode(String.self, forKey: .nodeStableId)
        nodeName = try c.decode(String.self, forKey: .nodeName)
        loginName = try c.decode(String.self, forKey: .loginName)
        pairedAt = try c.decodeRDDate(forKey: .pairedAt)
        directTokenHash = try c.decodeIfPresent(String.self, forKey: .directTokenHash)
        // 모양이 틀린 `push`는 없는 것으로 읽는다(항목 전체를 버리지 않는다).
        push = (try? c.decodeIfPresent(PushRegistration.self, forKey: .push)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(nodeStableId, forKey: .nodeStableId)
        try c.encode(nodeName, forKey: .nodeName)
        try c.encode(loginName, forKey: .loginName)
        try c.encodeRDDate(pairedAt, forKey: .pairedAt)
        if let directTokenHash, !directTokenHash.isEmpty { try c.encode(directTokenHash, forKey: .directTokenHash) }
        if let push { try c.encode(push, forKey: .push) }
    }
}

/// `rd_host_set_devices` 입력.
public struct DeviceList: Codable, Sendable, Hashable {
    public var devices: [DeviceEntry]

    public init(devices: [DeviceEntry]) {
        self.devices = devices
    }
}
