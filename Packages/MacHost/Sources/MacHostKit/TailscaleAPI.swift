import Foundation
import Security

/// Tailscale OAuth 클라이언트와 1회용 인증 키 발급의 화면 쪽 값. 발급 자체는 코어가 Swiftail `AuthKeyIssuer`로 한다
/// (`HostCore.openPairingOffer`). 이 모듈은 Swiftail을 링크하지 않는다. 비밀값·토큰·키는 로그에 남기지 않는다.
public enum TailscaleAPI {
    /// 관리 콘솔에서 만든 OAuth 클라이언트. `auth_keys` 쓰기 권한과 `tags`를 받은 클라이언트여야 한다.
    public struct OAuthClient: Codable, Sendable, Hashable, CustomStringConvertible {
        public var id: String
        public var secret: String
        /// 만드는 키에 붙일 태그. OAuth 클라이언트로 만드는 키는 태그가 꼭 있어야 한다.
        public var tags: [String]

        public init(id: String, secret: String, tags: [String]) {
            self.id = id
            self.secret = secret
            self.tags = tags
        }

        /// 비밀값을 가린다.
        public var description: String { "OAuthClient(id: \(id), secret: <가림>, tags: \(tags))" }
    }

    /// 키를 만들지 못한 까닭. Swiftail `AuthKeyIssueError`를 코어가 이 값으로 옮긴다. 비밀·토큰·서버 본문을 싣지 않는다.
    public enum Failure: Error, Hashable, Sendable {
        /// 클라이언트 ID·비밀값의 형식이 틀렸다(관리 API에 보내기 전에 걸렀다).
        case badClient
        case badTags
        /// 토큰 요청이 거절됐다: 클라이언트가 지워졌거나 비밀값이 틀렸다.
        case clientRejected
        /// 키 요청이 401로 거절됐다.
        case unauthorized
        /// 키 요청이 403으로 거절됐다: `auth_keys` 쓰기 권한이나 태그가 없다.
        case forbidden
        case http(Int)
        case invalidResponse
        case network
        case cancelled

        public var message: String {
            switch self {
            case .badClient: String(localized: "클라이언트 ID와 비밀값(tskey-client-…)을 확인하세요. 관리 콘솔에서 OAuth 클라이언트를 만들 때 한 번만 보여 줍니다.")
            case .badTags: String(localized: "태그는 tag:rd-phone처럼 tag:로 시작하고 영문 소문자·숫자·하이픈만 씁니다. 여러 개면 쉼표로 나눕니다.")
            case .clientRejected, .unauthorized: String(localized: "Tailscale이 OAuth 클라이언트를 받지 않았습니다. 클라이언트가 지워졌거나 비밀값이 틀렸을 수 있습니다.")
            case .forbidden: String(localized: "이 OAuth 클라이언트로는 인증 키를 만들 수 없습니다. 클라이언트에 Auth Keys 쓰기 권한(auth_keys)과 입력한 태그가 있는지 확인하세요.")
            case .http(let status): String(localized: "Tailscale API가 오류를 돌려줬습니다(HTTP \(String(status))). 태그가 클라이언트에 준 태그와 같은지 확인하세요.")
            case .invalidResponse: String(localized: "Tailscale API의 응답을 읽지 못했습니다.")
            case .network: String(localized: "Tailscale API에 연결하지 못했습니다. 인터넷 연결을 확인하세요.")
            case .cancelled: String(localized: "Tailscale 키 만들기를 멈췄습니다.")
            }
        }
    }

    public static let defaultTags = ["tag:rd-phone"]

    /// 쉼표·공백으로 나눈 태그. 하나도 없거나 형식이 틀리면 `nil`.
    public static func parseTags(_ text: String) -> [String]? {
        let tags = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map { $0.lowercased() }
        guard !tags.isEmpty else { return nil }
        for tag in tags {
            guard tag.hasPrefix("tag:"), tag.count > 4, tag.count <= 64,
                  tag.dropFirst(4).first.map({ ("a"..."z").contains($0) }) == true,
                  tag.dropFirst(4).unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
            else { return nil }
        }
        return Array(NSOrderedSet(array: tags)) as? [String]
    }

    /// 관리 API에 보내기 전의 형식 검사(Swiftail 계약 K4와 같은 규칙): ID와 비밀값은 1~512바이트이고 `A-Za-z0-9-_.~`만,
    /// 비밀값은 `tskey-client-`로 시작한다. 이 검사를 넘어야 저장한다. 클라이언트가 실제로 받아들여지는지는 키를 처음 만들 때 안다.
    public static func isWellFormed(id: String, secret: String) -> Bool {
        func credential(_ value: String) -> Bool {
            let bytes = value.utf8
            return !bytes.isEmpty && bytes.count <= 512 && bytes.allSatisfy { byte in
                (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
                    || byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x7E
            }
        }
        return credential(id) && credential(secret) && secret.hasPrefix("tskey-client-")
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

    public init(service: String = HostEdition.keychainService("com.oozoofrog.RemoteDebug.tailscale")) {
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
