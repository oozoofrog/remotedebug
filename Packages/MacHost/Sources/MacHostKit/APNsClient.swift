import CryptoKit
import Foundation
import RDModels

/// APNs에 보낼 알림 하나(docs/protocol-addenda.md P).
public struct APNsNotification: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case build
        case resource
        case test
    }

    public var title: String
    public var body: String
    public var kind: Kind
    /// 빌드 id 또는 리소스 id. 여러 항목을 묶었거나 이름을 숨기면 없다.
    public var id: String?
    /// iPhone이 동작 버튼을 고르는 분류. `id`가 있을 때만 넣는다.
    public var category: PushCategory?

    public init(title: String, body: String, kind: Kind, id: String? = nil, category: PushCategory? = nil) {
        self.title = title
        self.body = body
        self.kind = kind
        self.id = id
        self.category = id == nil ? nil : category
    }

    /// `{"aps":{"alert":{"title","body"},"category","sound":"default"},"rd":{"kind","id"}}`
    public func payload() -> Data {
        struct Alert: Encodable { var title: String; var body: String }
        struct APS: Encodable { var alert: Alert; var category: String?; var sound = "default" }
        struct RD: Encodable { var kind: String; var id: String? }
        struct Payload: Encodable { var aps: APS; var rd: RD }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let value = Payload(aps: APS(alert: Alert(title: title, body: body), category: category?.rawValue), rd: RD(kind: kind.rawValue, id: id))
        return (try? encoder.encode(value)) ?? Data()
    }
}

/// APNs 응답을 나눈 결과.
public enum APNsResult: Sendable, Hashable {
    case sent
    /// 기기 토큰이 더는 쓸 수 없다(410, 또는 400 BadDeviceToken). 그 기기의 등록을 지운다.
    case invalidToken(reason: String)
    /// APNs가 거절했다(키·주제·본문 문제 등).
    case rejected(status: Int, reason: String)
    /// APNs에 닿지 못했다.
    case networkFailure(String)
}

/// APNs HTTP/2 요청을 보내는 길. 시험은 가짜로 바꾼다.
public protocol APNsTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// URLSession(HTTP/2)으로 보낸다. 쿠키·캐시를 남기지 않는다.
public struct URLSessionAPNsTransport: APNsTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// APNs 토큰 인증 키(.p8)로 서명한 JWT를 붙여 개발(sandbox) 환경에 알림을 보낸다.
public actor APNsClient {
    /// 디버그 빌드만 다루므로 개발 환경만 쓴다.
    public static let endpoint = "https://api.sandbox.push.apple.com/3/device/"
    /// Apple은 JWT를 20분~60분 사이에 새로 만들라고 한다.
    public static let tokenLifetime: TimeInterval = 50 * 60

    private let keyID: String
    private let teamID: String
    private let privateKey: P256.Signing.PrivateKey
    private let transport: any APNsTransport
    private let now: @Sendable () -> Date
    private var cached: (jwt: String, issuedAt: Date)?

    public init(keyID: String, teamID: String, privateKey: P256.Signing.PrivateKey,
                transport: any APNsTransport = URLSessionAPNsTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.keyID = keyID
        self.teamID = teamID
        self.privateKey = privateKey
        self.transport = transport
        self.now = now
    }

    /// 지금 쓸 JWT. 만든 지 50분이 지났거나 시계가 거꾸로 갔으면 새로 만든다.
    func authorizationToken(forceNew: Bool = false) -> String {
        let t = now()
        if !forceNew, let cached {
            let age = t.timeIntervalSince(cached.issuedAt)
            if age >= 0, age < Self.tokenLifetime { return cached.jwt }
        }
        let jwt = Self.makeJWT(keyID: keyID, teamID: teamID, issuedAt: t, key: privateKey)
        cached = (jwt, t)
        return jwt
    }

    /// 머리 `{"alg":"ES256","kid":…}`, 본문 `{"iss":…,"iat":…}`, 서명은 r||s 원시 표현. 모두 base64url(채움 없음).
    static func makeJWT(keyID: String, teamID: String, issuedAt: Date, key: P256.Signing.PrivateKey) -> String {
        func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }
        let header = base64URL(json(["alg": "ES256", "kid": keyID]))
        let claims = base64URL(json(["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)]))
        let input = "\(header).\(claims)"
        let signature = (try? key.signature(for: Data(input.utf8)).rawRepresentation) ?? Data()
        return "\(input).\(base64URL(signature))"
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 기기 토큰은 16진수만 받는다(주소에 그대로 들어간다).
    static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.count.isMultiple(of: 2) && token.allSatisfy(\.isHexDigit)
    }

    func request(_ notification: APNsNotification, to registration: PushRegistration, jwt: String) -> URLRequest? {
        guard Self.isValidToken(registration.token), let url = URL(string: Self.endpoint + registration.token.lowercased()) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(registration.bundleId, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = notification.payload()
        return request
    }

    /// 한 기기에 보낸다. 403 ExpiredProviderToken이면 JWT를 새로 만들어 한 번만 다시 보낸다.
    public func send(_ notification: APNsNotification, to registration: PushRegistration) async -> APNsResult {
        var result = await attempt(notification, to: registration, forceNewToken: false)
        if case .rejected(403, "ExpiredProviderToken") = result {
            result = await attempt(notification, to: registration, forceNewToken: true)
        }
        return result
    }

    private func attempt(_ notification: APNsNotification, to registration: PushRegistration, forceNewToken: Bool) async -> APNsResult {
        let jwt = authorizationToken(forceNew: forceNewToken)
        guard let request = request(notification, to: registration, jwt: jwt) else { return .invalidToken(reason: "BadDeviceToken") }
        let response: (status: Int, body: Data)
        do {
            response = try await transport.send(request)
        } catch {
            return .networkFailure(HostErrorText.message(for: error))
        }
        return Self.classify(status: response.status, body: response.body)
    }

    static func classify(status: Int, body: Data) -> APNsResult {
        if status == 200 { return .sent }
        let reason = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["reason"] as? String ?? ""
        if status == 410 || (status == 400 && reason == "BadDeviceToken") { return .invalidToken(reason: reason) }
        return .rejected(status: status, reason: reason)
    }
}
