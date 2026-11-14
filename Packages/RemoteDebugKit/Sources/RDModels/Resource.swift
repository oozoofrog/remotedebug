import CryptoKit
import Foundation

/// 파일·링크가 속한 프로젝트 구역(docs/protocol-addenda.md H.6). 없으면 공통 구역이다.
public struct ResourceProject: Codable, Sendable, Hashable, Identifiable {
    public static let maxIDBytes = 64
    public static let maxNameBytes = 255

    /// 프로젝트 폴더 경로의 짧은 해시. 경로를 iPhone에 보내지 않는다.
    public var id: String
    /// 화면에 보이는 프로젝트 이름.
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// 프로젝트 폴더에서 만든다. id는 표준화한 폴더 경로 SHA-256의 앞 6바이트(16진수 12자리)다.
    public init(name: String, folder: URL) {
        self.id = Self.makeID(folderPath: folder.standardizedFileURL.path)
        self.name = name
    }

    public static func makeID(folderPath: String) -> String {
        SHA256.hash(data: Data(folderPath.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// 코어가 받는 값인지: id는 1~64바이트의 영문자·숫자·`_`·`-`, 이름은 1~255바이트에 제어 문자 없음.
    public var isValid: Bool {
        guard !id.isEmpty, id.utf8.count <= Self.maxIDBytes, !name.isEmpty, name.utf8.count <= Self.maxNameBytes else { return false }
        let idOK = id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
        return idOK && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// 구역 하나에 든 파일·링크. `project`가 nil이면 공통 구역이다.
public struct ResourceArea: Sendable, Hashable, Identifiable {
    /// 공통 구역을 가리키는 이름. 에이전트 입력(MCP `project: "공통"`)과 비교하는 값이라 번역하지 않는다.
    public static let commonTitle = "공통"

    public var project: ResourceProject?
    public var resources: [ResourceDescriptor]

    public var id: String { project.map { "p:" + $0.id } ?? "common" }
    /// 화면에 보일 구역 이름. 공통 구역은 기기 언어로 번역해 보인다.
    public var title: String { project?.name ?? String(localized: "공통") }

    public init(project: ResourceProject?, resources: [ResourceDescriptor]) {
        self.project = project
        self.resources = resources
    }
}

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
    /// 속한 프로젝트 구역(addenda H.6). nil이면 공통이다.
    public var project: ResourceProject?

    public init(id: String, name: String, size: Int64, sha256: String, publishedAt: Date, link: String? = nil, project: ResourceProject? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.publishedAt = publishedAt
        self.link = link
        self.project = project
    }

    public var isLink: Bool { link != nil }

    enum CodingKeys: String, CodingKey { case id, name, size, sha256, publishedAt, link, project }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(Int64.self, forKey: .size)
        sha256 = try c.decode(String.self, forKey: .sha256)
        publishedAt = try c.decodeRDDate(forKey: .publishedAt)
        link = try c.decodeIfPresent(String.self, forKey: .link).flatMap { $0.isEmpty ? nil : $0 }
        // 모양이 맞지 않는 구역은 목록 전체를 버리지 않고 공통으로 본다.
        project = (try? c.decodeIfPresent(ResourceProject.self, forKey: .project)).flatMap { $0 }.flatMap { $0.isValid ? $0 : nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(size, forKey: .size)
        try c.encode(sha256, forKey: .sha256)
        try c.encodeRDDate(publishedAt, forKey: .publishedAt)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(project, forKey: .project)
    }

    /// 목록을 구역으로 나눈다. 프로젝트 구역을 이름순(같으면 id순)으로 놓고 공통을 마지막에 둔다.
    /// 구역 안의 순서는 받은 목록 그대로다. 항목이 없는 구역은 만들지 않는다.
    /// 같은 프로젝트 id의 이름이 다르면 가장 최근에 보낸 항목의 이름을 쓴다.
    public static func areas(_ list: [ResourceDescriptor]) -> [ResourceArea] {
        var order: [String] = []
        var grouped: [String: [ResourceDescriptor]] = [:]
        var common: [ResourceDescriptor] = []
        for r in list {
            guard let project = r.project else { common.append(r); continue }
            if grouped[project.id] == nil { order.append(project.id) }
            grouped[project.id, default: []].append(r)
        }
        var areas = order.compactMap { id -> ResourceArea? in
            guard let items = grouped[id], let newest = items.max(by: { $0.publishedAt < $1.publishedAt }), let project = newest.project else { return nil }
            return ResourceArea(project: project, resources: items)
        }
        areas.sort {
            let c = $0.title.localizedStandardCompare($1.title)
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
        if !common.isEmpty { areas.append(ResourceArea(project: nil, resources: common)) }
        return areas
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
