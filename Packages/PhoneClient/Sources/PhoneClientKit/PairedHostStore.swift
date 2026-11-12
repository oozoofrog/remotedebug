import Foundation
import RDModels

/// 페어링을 마친 호스트. `fqdn`은 페어링 요청을 보낸(정책을 통과한) 주소이며, 이후 모든 요청은 이 주소로만 간다.
public struct PairedHost: Codable, Hashable, Sendable {
    public var hostId: String
    public var hostName: String
    public var fqdn: String
    public var pairedAt: Date
    /// 이 앱 자신의 업데이트 페이지(공식 Tailscale 주소). Mac이 마지막으로 알려 준 값.
    public var updatePage: URL?

    public init(hostId: String, hostName: String, fqdn: String, pairedAt: Date, updatePage: URL? = nil) {
        self.hostId = hostId
        self.hostName = hostName
        self.fqdn = fqdn
        self.pairedAt = pairedAt
        self.updatePage = updatePage
    }

    enum CodingKeys: String, CodingKey { case hostId, hostName, fqdn, pairedAt, updatePage }

    /// https 주소만 받는다.
    public static func validUpdatePage(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostId = try c.decode(String.self, forKey: .hostId)
        hostName = try c.decode(String.self, forKey: .hostName)
        fqdn = try c.decode(String.self, forKey: .fqdn)
        let text = try c.decode(String.self, forKey: .pairedAt)
        guard let date = RDTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: .pairedAt, in: c, debugDescription: "ISO-8601 시각이 아닙니다")
        }
        pairedAt = date
        updatePage = Self.validUpdatePage(try c.decodeIfPresent(String.self, forKey: .updatePage))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hostId, forKey: .hostId)
        try c.encode(hostName, forKey: .hostName)
        try c.encode(fqdn, forKey: .fqdn)
        try c.encode(RDTimestamp.string(pairedAt), forKey: .pairedAt)
        try c.encodeIfPresent(updatePage?.absoluteString, forKey: .updatePage)
    }
}

/// 페어링한 호스트 하나를 보관한다.
@MainActor
public protocol PairedHostStoring: AnyObject {
    func load() -> PairedHost?
    func save(_ host: PairedHost) throws
    func clear()
}

/// `UserDefaults`에 JSON으로 저장한다(비밀이 아니므로 Keychain을 쓰지 않는다).
@MainActor
public final class UserDefaultsPairedHostStore: PairedHostStoring {
    public static let defaultKey = "RemoteDebug.pairedHost"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsPairedHostStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PairedHost? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? RDJSON.decoder().decode(PairedHost.self, from: data)
    }

    public func save(_ host: PairedHost) throws {
        defaults.set(try RDJSON.encoder().encode(host), forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// 메모리 보관(테스트·미리보기용).
@MainActor
public final class InMemoryPairedHostStore: PairedHostStoring {
    public private(set) var host: PairedHost?

    public init(host: PairedHost? = nil) {
        self.host = host
    }

    public func load() -> PairedHost? { host }
    public func save(_ host: PairedHost) throws { self.host = host }
    public func clear() { host = nil }
}
