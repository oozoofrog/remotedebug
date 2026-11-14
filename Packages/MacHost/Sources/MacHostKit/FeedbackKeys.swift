import CryptoKit
import Foundation
import Security

/// 피드백 메일에 붙는 암호화된 진단 파일(`.afdiag`)의 키와 복호화.
/// 형식은 `RemoteDebugFeedback` 패키지의 `FeedbackSealing`과 같다: 머리말 8바이트, 키 지문 8바이트, 캡슐화 키 32바이트, 인증된 암호문.
public enum FeedbackEnvelope {
    public enum Failure: Error, Equatable, Sendable {
        case malformed
        case unknownKey
        case damaged

        public var message: String {
            switch self {
            case .malformed: String(localized: "RemoteDebug 피드백 진단 파일이 아닙니다.")
            case .unknownKey: String(localized: "이 Mac에 이 파일을 열 키가 없습니다. 키를 만든 Mac에서 여세요.")
            case .damaged: String(localized: "파일이 바뀌었거나 손상돼 열 수 없습니다.")
            }
        }
    }

    static let magic = Data("AFDIAG1\0".utf8)
    static let info = Data("AppFeedback diagnostics v1".utf8)
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    public static func keyID(_ key: Curve25519.KeyAgreement.PublicKey) -> Data {
        Data(SHA256.hash(data: key.rawRepresentation).prefix(8))
    }

    /// 지문이 맞는 키로 연다. 맞는 키가 없으면 `.unknownKey`.
    public static func open(_ sealed: Data, keys: [Curve25519.KeyAgreement.PrivateKey]) throws(Failure) -> Data {
        let bytes = Data(sealed)
        guard bytes.count >= 64, bytes.prefix(8) == magic else { throw .malformed }
        let header = bytes.prefix(16)
        guard let key = keys.first(where: { keyID($0.publicKey) == header.suffix(8) }) else { throw .unknownKey }
        do {
            var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: info,
                                               encapsulatedKey: bytes.subdata(in: 16..<48))
            let compressed = try recipient.open(bytes.subdata(in: 48..<bytes.count), authenticating: header)
            return try (compressed as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw .damaged
        }
    }
}

/// 진단 암호화 키 보관. 개인키는 이 Mac의 키체인에만 둔다.
public protocol FeedbackKeyStoring: Sendable {
    /// `account`의 키. 없으면 `nil`.
    func key(account: String) -> Curve25519.KeyAgreement.PrivateKey?
    /// 새 키를 만든다. 같은 `account`가 있으면 바꾸지 않고 있는 키를 돌려준다.
    func makeKey(account: String) throws -> Curve25519.KeyAgreement.PrivateKey
    func allKeys() -> [Curve25519.KeyAgreement.PrivateKey]
}

public struct KeychainFeedbackKeyStore: FeedbackKeyStoring {
    let service: String

    public init(service: String = HostEdition.keychainService("RemoteDebug feedback diagnostics")) {
        self.service = service
    }

    private func query(_ account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func key(account: String) -> Curve25519.KeyAgreement.PrivateKey? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let raw = item as? Data else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    public func makeKey(account: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = key(account: account) { return existing }
        let made = Curve25519.KeyAgreement.PrivateKey()
        var q = query(account)
        q[kSecAttrLabel as String] = "\(service) / \(account)"
        q[kSecValueData as String] = made.rawRepresentation
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return made
    }

    public func allKeys() -> [Curve25519.KeyAgreement.PrivateKey] {
        var q = query(nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &items) == errSecSuccess, let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(key(account:)) }
    }
}

/// 시험·미리보기용.
public final class MemoryFeedbackKeyStore: FeedbackKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    public init() {}
    public func key(account: String) -> Curve25519.KeyAgreement.PrivateKey? { lock.withLock { keys[account] } }
    public func makeKey(account: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.withLock {
            if let existing = keys[account] { return existing }
            let made = Curve25519.KeyAgreement.PrivateKey()
            keys[account] = made
            return made
        }
    }
    public func allKeys() -> [Curve25519.KeyAgreement.PrivateKey] { lock.withLock { Array(keys.values) } }
}
