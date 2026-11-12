import CryptoKit
import Foundation

/// Mac이 페어링한 기기에 보내는 파일 하나(docs/protocol-addenda.md H).
public struct ResourceDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// 파일 이름(경로 없이 한 단계).
    public var name: String
    public var size: Int64
    public var sha256: String
    public var publishedAt: Date
    /// 링크면 그 주소(addenda H.5). 파일 내용이 없고 `size`는 0, `sha256`은 주소 글자의 SHA-256이다.
    public var link: String?

    public init(id: String, name: String, size: Int64, sha256: String, publishedAt: Date, link: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.publishedAt = publishedAt
        self.link = link
    }

    public var isLink: Bool { link != nil }

    enum CodingKeys: String, CodingKey { case id, name, size, sha256, publishedAt, link }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(Int64.self, forKey: .size)
        sha256 = try c.decode(String.self, forKey: .sha256)
        publishedAt = try c.decodeRDDate(forKey: .publishedAt)
        link = try c.decodeIfPresent(String.self, forKey: .link).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(size, forKey: .size)
        try c.encode(sha256, forKey: .sha256)
        try c.encodeRDDate(publishedAt, forKey: .publishedAt)
        try c.encodeIfPresent(link, forKey: .link)
    }

    /// 링크 글자의 SHA-256(소문자 16진수). 링크의 `sha256` 값이다.
    public static func linkHash(_ link: String) -> String {
        SHA256.hash(data: Data(link.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 코어와 같은 규칙: `"r_"` + `sha256("rd-resource\n" + name + "\n" + sha256)`의 앞 8자리 16진수.
    public static func makeID(name: String, sha256: String) -> String {
        let digest = SHA256.hash(data: Data(("rd-resource\n" + name + "\n" + sha256).utf8))
        return "r_" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    /// 코어가 받는 파일 이름인지: 1~255바이트, `/ \ :`과 제어 문자 없음, `.`·`..` 아님.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else { return false }
        return !name.unicodeScalars.contains { "/\\:".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}

/// `rd_host_publish_resource` 입력: 설명 + `publishDir` 안의 파일 경로.
public struct ResourcePublishRequest: Codable, Sendable, Hashable {
    public var resource: ResourceDescriptor
    public var path: String

    public init(resource: ResourceDescriptor, path: String) {
        self.resource = resource
        self.path = path
    }

    enum CodingKeys: String, CodingKey { case path }

    public init(from decoder: any Decoder) throws {
        resource = try ResourceDescriptor(from: decoder)
        path = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .path)
    }

    public func encode(to encoder: any Encoder) throws {
        try resource.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
    }
}

/// `GET /v1/resources` 응답.
public struct ResourcesResponse: Codable, Sendable, Hashable {
    public var resources: [ResourceDescriptor]

    public init(resources: [ResourceDescriptor]) {
        self.resources = resources
    }

    enum CodingKeys: String, CodingKey { case resources }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.resources) else {
            throw DecodingError.keyNotFound(CodingKeys.resources, .init(codingPath: c.codingPath, debugDescription: "resources 키가 없습니다(오류 응답일 수 있음)"))
        }
        resources = try c.decodeNil(forKey: .resources) ? [] : c.decode([ResourceDescriptor].self, forKey: .resources)
    }
}
