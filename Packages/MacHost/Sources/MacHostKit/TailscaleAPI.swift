import Foundation
import Security

/// Tailscale 관리 API(`https://api.tailscale.com/api/v2/`). 사용자가 넣은 OAuth 클라이언트로
/// 1시간짜리 API 토큰을 받아 iPhone용 1회용 인증 키를 만든다. 비밀값·토큰·키는 로그에 남기지 않는다.
public struct TailscaleAPI: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 관리 콘솔에서 만든 OAuth 클라이언트. `auth_keys` 쓰기 권한과 `tags`를 받은 클라이언트여야 한다.
    public struct OAuthClient: Codable, Sendable, Hashable {
        public var id: String
        public var secret: String
        /// 만드는 키에 붙일 태그. OAuth 클라이언트로 만드는 키는 태그가 꼭 있어야 한다.
        public var tags: [String]

        public init(id: String, secret: String, tags: [String]) {
            self.id = id
            self.secret = secret
            self.tags = tags
        }
    }

    public struct AccessToken: Sendable, Hashable {
        public var token: String
        public var expires: Date
    }

    public struct Device: Sendable, Hashable {
        /// MagicDNS 이름(`rd-mac-….tailnet.ts.net`).
        public var name: String
    }

    public struct AuthKey: Sendable, Hashable {
        public var key: String
        public var expires: Date?
    }

    public enum Failure: Error, Equatable, Sendable {
        case badClient
        case badTags
        case unauthorized
        case forbidden
        case http(Int)
        case invalidResponse
        case network

        public var message: String {
            switch self {
            case .badClient: "클라이언트 ID와 비밀값(tskey-client-…)을 확인하세요. 관리 콘솔에서 OAuth 클라이언트를 만들 때 한 번만 보여 줍니다."
            case .badTags: "태그는 tag:rd-phone처럼 tag:로 시작하고 영문 소문자·숫자·하이픈만 씁니다. 여러 개면 쉼표로 나눕니다."
            case .unauthorized: "Tailscale이 OAuth 클라이언트를 받지 않았습니다. 클라이언트가 지워졌거나 비밀값이 틀렸을 수 있습니다."
            case .forbidden: "이 OAuth 클라이언트로는 인증 키를 만들 수 없습니다. 클라이언트에 Auth Keys 쓰기 권한(auth_keys)과 입력한 태그가 있는지 확인하세요."
            case .http(let status): "Tailscale API가 오류를 돌려줬습니다(HTTP \(status)). 태그가 클라이언트에 준 태그와 같은지 확인하세요."
            case .invalidResponse: "Tailscale API의 응답을 읽지 못했습니다."
            case .network: "Tailscale API에 연결하지 못했습니다. 인터넷 연결을 확인하세요."
            }
        }
    }

    public static let base = URL(string: "https://api.tailscale.com/api/v2/")!
    /// 페어링 QR에 넣는 키의 수명(초). 페어링 코드(5분)보다 넉넉하게 둔다.
    public static let pairingKeyLifetime: TimeInterval = 900
    public static let defaultTags = ["tag:rd-phone"]

    let send: Send

    public init(send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        self.send = send
    }

    /// 쉼표·공백으로 나눈 태그. 하나도 없거나 형식이 틀리면 `nil`.
    public static func parseTags(_ text: String) -> [String]? {
        let tags = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map { $0.lowercased() }
        guard !tags.isEmpty else { return nil }
        for tag in tags {
            guard tag.hasPrefix("tag:"), tag.count > 4, tag.count <= 64,
                  tag.dropFirst(4).unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
            else { return nil }
        }
        return Array(NSOrderedSet(array: tags)) as? [String]
    }

    static func isPlainToken(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 512 && text.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    /// OAuth 클라이언트 자격 증명으로 API 토큰(1시간)을 받는다.
    public func accessToken(for client: OAuthClient, now: Date = Date()) async throws(Failure) -> AccessToken {
        guard Self.isPlainToken(client.id), client.secret.hasPrefix("tskey-client-"), Self.isPlainToken(client.secret) else {
            throw .badClient
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "client_secret", value: client.secret),
        ]
        var request = URLRequest(url: Self.base.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await perform(request, authFailure: .badClient)
        struct Reply: Decodable { var access_token: String?; var expires_in: Double? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let token = reply.access_token, Self.isPlainToken(token) else {
            throw .invalidResponse
        }
        // 만료 1분 전에 새로 받는다.
        return AccessToken(token: token, expires: now.addingTimeInterval(max(60, (reply.expires_in ?? 3600) - 60)))
    }

    /// 토큰이 속한 tailnet의 기기 이름. 클라이언트에 기기 읽기 권한이 없으면 `.forbidden`.
    public func devices(token: String) async throws(Failure) -> [Device] {
        struct Body: Decodable {
            struct Item: Decodable { var name: String? }
            var devices: [Item]
        }
        let data = try await call("GET", "tailnet/-/devices", token: token, body: nil)
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw .invalidResponse }
        return body.devices.compactMap { $0.name.map { Device(name: Self.normalized($0)) } }
    }

    /// 한 번만 쓸 수 있고 미리 승인된, 태그가 붙은 키를 만든다.
    public func createAuthKey(token: String, tags: [String], lifetime: TimeInterval = pairingKeyLifetime) async throws(Failure) -> AuthKey {
        guard !tags.isEmpty else { throw .badTags }
        let request: [String: Any] = [
            "capabilities": ["devices": ["create": ["reusable": false, "ephemeral": false, "preauthorized": true, "tags": tags]]],
            "expirySeconds": Int(lifetime),
            "description": "RemoteDebug iPhone pairing",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { throw .invalidResponse }
        let data = try await call("POST", "tailnet/-/keys", token: token, body: body)
        struct Reply: Decodable { var key: String?; var expires: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let key = reply.key, key.hasPrefix("tskey-auth-") else {
            throw .invalidResponse
        }
        let expires = reply.expires.flatMap { try? Date($0, strategy: Date.ISO8601FormatStyle()) }
        return AuthKey(key: key, expires: expires)
    }

    static func normalized(_ name: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        return n
    }

    private func call(_ method: String, _ path: String, token: String, body: Data?) async throws(Failure) -> Data {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request, authFailure: .unauthorized)
    }

    private func perform(_ request: URLRequest, authFailure: Failure) async throws(Failure) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            throw .network
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 400, 401: throw authFailure
        case 403: throw .forbidden
        default: throw .http(http.statusCode)
        }
    }
}

/// Tailscale OAuth 클라이언트 보관(키체인).
public protocol TailscaleClientStoring: Sendable {
    func load() -> TailscaleAPI.OAuthClient?
    func save(_ client: TailscaleAPI.OAuthClient) throws
    func clear()
}

public struct KeychainTailscaleClientStore: TailscaleClientStoring {
    let service: String
    let account = "tailscale-oauth-client"

    public init(service: String = "com.oozoofrog.RemoteDebug.tailscale") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> TailscaleAPI.OAuthClient? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TailscaleAPI.OAuthClient.self, from: data)
    }

    public func save(_ client: TailscaleAPI.OAuthClient) throws {
        clear()
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(client)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
        // 이전 버전이 저장한 API 액세스 토큰도 지운다.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: "tailscale-api-access-token"] as CFDictionary)
    }
}

/// 시험·미리보기용.
public final class MemoryTailscaleClientStore: TailscaleClientStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var client: TailscaleAPI.OAuthClient?
    public init(_ client: TailscaleAPI.OAuthClient? = nil) { self.client = client }
    public func load() -> TailscaleAPI.OAuthClient? { lock.withLock { client } }
    public func save(_ client: TailscaleAPI.OAuthClient) throws { lock.withLock { self.client = client } }
    public func clear() { lock.withLock { client = nil } }
}
