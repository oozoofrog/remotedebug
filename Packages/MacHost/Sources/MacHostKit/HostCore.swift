import Foundation
import RDModels

/// `rd_host_pairing_open`의 결과(protocol §2, §9).
public struct PairingCode: Codable, Sendable, Hashable {
    /// 8자 Crockford base32 코드(구분자 없음).
    public var code: String
    public var expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case code, expiresAt
    }

    /// 코어 JSON `{"code":"K7M29QXD","expiresAt":"2026-11-11T09:07:00Z"}`(RFC 3339 문자열)을 읽는다.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        let text = try c.decode(String.self, forKey: .expiresAt)
        guard let date = RDTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: c, debugDescription: "ISO-8601 시각이 아닙니다: \(text)")
        }
        expiresAt = date
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(RDTimestamp.string(expiresAt), forKey: .expiresAt)
    }

    /// 화면 표시용 `K7M2-9QXD`.
    public var displayCode: String {
        guard code.count == 8 else { return code }
        return code.prefix(4) + "-" + code.suffix(4)
    }

    /// `remotedebug://pair?host=<fqdn>&code=<code>`. fqdn이 비면 nil.
    public func link(fqdn: String) -> URL? {
        guard !fqdn.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "remotedebug"
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "host", value: fqdn), URLQueryItem(name: "code", value: code)]
        return c.url
    }
}

/// 호스트 모드 코어(RDNode)의 추상화. 실제 어댑터는 C API를 이 프로토콜로 감싼다.
public protocol HostCore: Sendable {
    func start(_ config: CoreConfig) async throws
    func stop() async
    func status() async throws -> CoreStatus
    /// 실패는 `APIErrorBody`(protocol §8·§9 코드)로 던진다.
    func publish(_ request: PublishRequest) async throws
    /// 코어에 없는 id면 `APIErrorBody(code: "build_not_found")`를 던진다(라이브러리는 성공으로 본다).
    func unpublish(buildID: String) async throws
    /// 허용 목록 전체를 바꾼다. 모델은 이 호출을 한 번에 하나씩 순서대로 보낸다(앞 호출이 끝난 뒤 다음 호출).
    func setDevices(_ devices: [DeviceEntry]) async throws
    func openPairing(ttlSeconds: Int) async throws -> PairingCode
    /// 승인하면 허용 목록에 들어간 기기, 거절하면 nil.
    func decidePairing(requestID: String, allow: Bool) async throws -> DeviceEntry?
    /// `start` 이후의 코어 이벤트. `stop`하면 끝난다.
    func events() -> AsyncStream<CoreEvent>
}
