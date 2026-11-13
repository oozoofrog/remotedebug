import Foundation

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

    /// 같은 네트워크 직접 연결에 등록한 기기인가.
    public var isDirectEnrolled: Bool { directTokenHash?.isEmpty == false }

    public init(id: String, name: String, nodeStableId: String, nodeName: String, loginName: String, pairedAt: Date, directTokenHash: String? = nil) {
        self.id = id
        self.name = name
        self.nodeStableId = nodeStableId
        self.nodeName = nodeName
        self.loginName = loginName
        self.pairedAt = pairedAt
        self.directTokenHash = directTokenHash
    }

    enum CodingKeys: String, CodingKey {
        case id, name, nodeStableId, nodeName, loginName, pairedAt, directTokenHash
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
    }
}

/// `rd_host_set_devices` 입력.
public struct DeviceList: Codable, Sendable, Hashable {
    public var devices: [DeviceEntry]

    public init(devices: [DeviceEntry]) {
        self.devices = devices
    }
}
