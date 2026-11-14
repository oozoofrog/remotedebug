import CryptoKit
import Foundation
import Security

/// APNs 인증 키(.p8, PKCS#8 PEM) 보관. 키 내용은 이 Mac의 키체인에만 둔다.
public protocol APNsKeyStoring: Sendable {
    /// 저장된 PEM. 없으면 `nil`.
    func load() -> String?
    func save(_ pem: String) throws
    func clear()
}

public enum APNsKeyFailure: Error, Equatable, Sendable {
    case notP256Key
    case badKeyID
    case badTeamID
    case missingKey

    public var message: String {
        switch self {
        case .notP256Key: String(localized: "APNs 인증 키(.p8) 파일이 아닙니다. Apple Developer의 Keys에서 받은 AuthKey_….p8 파일을 고르세요.")
        case .badKeyID: String(localized: "Key ID는 영문 대문자와 숫자 10자입니다.")
        case .badTeamID: String(localized: "Team ID는 영문 대문자와 숫자 10자입니다.")
        case .missingKey: String(localized: "키 파일을 먼저 고르세요.")
        }
    }
}

public enum APNsKey {
    /// .p8 내용을 서명 키로 읽는다. 저장하기 전에 반드시 거친다.
    public static func parse(_ pem: String) throws(APNsKeyFailure) -> P256.Signing.PrivateKey {
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: pem.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw .notP256Key
        }
    }

    /// Key ID·Team ID: 앞뒤 공백을 빼고 대문자로 바꾼 10자 영숫자. 아니면 `nil`.
    public static func normalizedID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 10, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return value
    }
}

public struct KeychainAPNsKeyStore: APNsKeyStoring {
    let service: String
    let account: String

    public init(service: String = HostEdition.keychainService("RemoteDebug APNs key"), account: String = "p8") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let raw = item as? Data else { return nil }
        return String(data: raw, encoding: .utf8)
    }

    public func save(_ pem: String) throws {
        let data = Data(pem.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var q = query
        q[kSecAttrLabel as String] = service
        q[kSecValueData as String] = data
        let added = SecItemAdd(q as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// 시험·미리보기용.
public final class MemoryAPNsKeyStore: APNsKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pem: String?
    public init(pem: String? = nil) { self.pem = pem }
    public func load() -> String? { lock.withLock { pem } }
    public func save(_ pem: String) throws { lock.withLock { self.pem = pem } }
    public func clear() { lock.withLock { pem = nil } }
}

/// Key ID·Team ID·이름 숨김 설정(UserDefaults). 키 내용은 여기에 두지 않는다.
public struct APNsSettingsStore: @unchecked Sendable {
    static let keyIDKey = "RDAPNsKeyID"
    static let teamIDKey = "RDAPNsTeamID"
    static let hideNamesKey = "RDAPNsHideNames"

    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var keyID: String {
        get { defaults.string(forKey: Self.keyIDKey) ?? "" }
        nonmutating set { newValue.isEmpty ? defaults.removeObject(forKey: Self.keyIDKey) : defaults.set(newValue, forKey: Self.keyIDKey) }
    }

    public var teamID: String {
        get { defaults.string(forKey: Self.teamIDKey) ?? "" }
        nonmutating set { newValue.isEmpty ? defaults.removeObject(forKey: Self.teamIDKey) : defaults.set(newValue, forKey: Self.teamIDKey) }
    }

    public var hideNames: Bool {
        get { defaults.bool(forKey: Self.hideNamesKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hideNamesKey) }
    }
}
