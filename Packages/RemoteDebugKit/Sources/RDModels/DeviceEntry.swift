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

/// docs/protocol-addenda.md S: 기기 항목에 묶은 다른 tailnet 노드. 같은 iPhone에서 다른 앱(공식 Tailscale 앱 등)이
/// 켠 VPN의 노드다. 이 노드에서 온 요청은 그 기기 항목의 요청으로 처리한다.
public struct LinkedNode: Codable, Sendable, Hashable {
    public var nodeStableId: String
    public var nodeName: String
    public var loginName: String
    /// 마지막으로 묶은(다시 묶은) 시각.
    public var linkedAt: Date

    public init(nodeStableId: String, nodeName: String, loginName: String, linkedAt: Date) {
        self.nodeStableId = nodeStableId
        self.nodeName = nodeName
        self.loginName = loginName
        self.linkedAt = linkedAt
    }

    enum CodingKeys: String, CodingKey { case nodeStableId, nodeName, loginName, linkedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeStableId = try c.decode(String.self, forKey: .nodeStableId)
        nodeName = try c.decode(String.self, forKey: .nodeName)
        loginName = try c.decode(String.self, forKey: .loginName)
        linkedAt = try c.decodeRDDate(forKey: .linkedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nodeStableId, forKey: .nodeStableId)
        try c.encode(nodeName, forKey: .nodeName)
        try c.encode(loginName, forKey: .loginName)
        try c.encodeRDDate(linkedAt, forKey: .linkedAt)
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
    /// docs/protocol-addenda.md R: 이 기기가 처음 USB 케이블 설치를 요청했을 때 그 케이블에 꽂혀 있던 iPhone의 UDID.
    /// 그 뒤로 이 기기의 토큰으로는 그 iPhone에만 설치시킬 수 있다. 허용 목록에서 빼면 항목과 함께 사라진다. 없으면 아직 묶이지 않았다.
    public var cableUDID: String?
    /// docs/protocol-addenda.md S: 이 기기 항목에 묶은 다른 tailnet 노드. 다시 페어링하면 새 항목에는 없다.
    public var linkedNodes: [LinkedNode]

    /// 같은 네트워크 직접 연결에 등록한 기기인가.
    public var isDirectEnrolled: Bool { directTokenHash?.isEmpty == false }

    /// 알림 기기 토큰을 등록한 기기인가.
    public var isPushRegistered: Bool { push?.token.isEmpty == false }

    public init(id: String, name: String, nodeStableId: String, nodeName: String, loginName: String, pairedAt: Date, directTokenHash: String? = nil,
                push: PushRegistration? = nil, cableUDID: String? = nil, linkedNodes: [LinkedNode] = []) {
        self.cableUDID = cableUDID
        self.linkedNodes = linkedNodes
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
        case id, name, nodeStableId, nodeName, loginName, pairedAt, directTokenHash, push, cableUDID, linkedNodes
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
        cableUDID = (try? c.decodeIfPresent(String.self, forKey: .cableUDID)) ?? nil
        // 모양이 틀린 `linkedNodes`는 없는 것으로 읽는다(묶인 노드만 잃고 기기 항목은 남는다).
        linkedNodes = ((try? c.decodeIfPresent([LinkedNode].self, forKey: .linkedNodes)) ?? nil) ?? []
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
        if let cableUDID, !cableUDID.isEmpty { try c.encode(cableUDID, forKey: .cableUDID) }
        if !linkedNodes.isEmpty { try c.encode(linkedNodes, forKey: .linkedNodes) }
    }
}

/// 기기 목록 설정 입력(예전 Go 코어의 `rd_host_set_devices`와 같은 JSON).
public struct DeviceList: Codable, Sendable, Hashable {
    public var devices: [DeviceEntry]

    public init(devices: [DeviceEntry]) {
        self.devices = devices
    }
}

/// 알림의 `aps.category`(docs/protocol-addenda.md P.5). iPhone 앱이 이 값마다 동작 버튼을 등록한다.
/// 항목 하나를 가리키는 알림(`rd.id`가 있다)에만 붙는다.
public enum PushCategory: String, Sendable, Hashable, CaseIterable {
    case build = "rd.build"
    case link = "rd.link"
    case file = "rd.file"
}
