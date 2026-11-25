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

    /// Read the fingerprint before asking the store for a private key.
    public static func open(_ sealed: Data, keys: any FeedbackKeyStoring) throws -> Data {
        let bytes = Data(sealed)
        guard bytes.count >= 64, bytes.prefix(8) == magic else { throw Failure.malformed }
        let header = bytes.prefix(16)
        let fingerprint = Data(header.suffix(8))
        guard let key = try keys.key(id: fingerprint), keyID(key.publicKey) == fingerprint else { throw Failure.unknownKey }
        do {
            var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: info,
                                               encapsulatedKey: bytes.subdata(in: 16..<48))
            let compressed = try recipient.open(bytes.subdata(in: 48..<bytes.count), authenticating: header)
            return try (compressed as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw Failure.damaged
        }
    }
}

/// Stores the private keys for encrypted feedback diagnostics.
public protocol FeedbackKeyStoring: Sendable {
    func key(id: Data) throws -> Curve25519.KeyAgreement.PrivateKey?
    func makeKey(account: String) throws -> Curve25519.KeyAgreement.PrivateKey
    func migrateLegacyKeys() throws -> Int
}

enum FeedbackKeyFailure: Error, Equatable {
    case accessGroupMissing
    case verificationFailed
    case keychain(OSStatus)

    var message: String {
        switch self {
        case .accessGroupMissing, .keychain(errSecMissingEntitlement):
            String(localized: "이 RemoteDebug 빌드에 진단 키체인 권한이 없습니다. 서명된 앱에서 다시 시도하세요.")
        case .verificationFailed:
            String(localized: "진단 키의 지문을 확인하지 못했습니다.")
        case .keychain(let status):
            String(localized: "진단 키체인에 접근하지 못했습니다(macOS 오류 \(status)).")
        }
    }
}

/// Injects SecItem operations so tests exercise the production queries without using a keychain.
struct FeedbackKeychain: Sendable {
    var accessGroup: @Sendable () -> String?
    var copy: @Sendable ([String: Any]) -> (OSStatus, Any?)
    var add: @Sendable ([String: Any]) -> OSStatus

    static let system = Self(
        accessGroup: {
            guard let task = SecTaskCreateFromSelf(nil) else { return nil }
            let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String]
            return groups?.first
        },
        copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) }
    )
}

public struct KeychainFeedbackKeyStore: FeedbackKeyStoring {
    private struct LegacyItem: Hashable {
        var service: String
        var account: String
    }

    private let service: String
    private let keychain: FeedbackKeychain

    public init(service: String = "RemoteDebug feedback diagnostics") {
        self.init(service: service, keychain: .system)
    }

    init(service: String = "RemoteDebug feedback diagnostics", keychain: FeedbackKeychain) {
        self.service = service
        self.keychain = keychain
    }

    public func key(id: Data) throws -> Curve25519.KeyAgreement.PrivateKey? {
        var query = try protectedQuery()
        query[kSecAttrGeneric as String] = id
        return try readProtected(query)
    }

    public func makeKey(account: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        let query = try protectedQuery(account)
        if let existing = try readProtected(query) { return existing }
        // A failed legacy read must never be treated as permission to generate a replacement.
        let legacy = try legacyKey(LegacyItem(service: service, account: account))
        return try copyToProtected(legacy ?? .init(), query: query, account: account, mustMatch: legacy != nil)
    }

    public func migrateLegacyKeys() throws -> Int {
        _ = try protectedQuery()
        var query = [kSecClass as String: kSecClassGenericPassword] as [String: Any]
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        guard let result = try matching(query) else { return 0 }
        guard let items = result as? [[String: Any]] else { throw FeedbackKeyFailure.verificationFailed }
        let candidates = Set(items.compactMap { item -> LegacyItem? in
            guard let name = item[kSecAttrService as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String else { return nil }
            return LegacyItem(service: name, account: account)
        })
        var copied = 0
        for item in candidates.sorted(by: { ($0.service, $0.account) < ($1.service, $1.account) }) {
            let isProjectKey = item.service == service
            // Some apps used the diagnostics script with an app-specific service and the public fingerprint as account.
            guard isProjectKey || (item.service.hasSuffix(" feedback diagnostics")
                && item.account.utf8.count == 16 && item.account.allSatisfy(\.isHexDigit)) else { continue }
            let account = isProjectKey ? item.account : "\(item.service) / \(item.account)"
            let destination = try protectedQuery(account)
            if try readProtected(destination) != nil { continue }
            guard let legacy = try legacyKey(item) else { continue }
            if !isProjectKey {
                let fingerprint = FeedbackEnvelope.keyID(legacy.publicKey).map { String(format: "%02x", $0) }.joined()
                guard fingerprint == item.account.lowercased() else { throw FeedbackKeyFailure.verificationFailed }
            }
            _ = try copyToProtected(legacy, query: destination, account: account, mustMatch: true)
            copied += 1
        }
        // Keep the original item for recovery and rollback.
        return copied
    }

    private func itemQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private func protectedQuery(_ account: String? = nil) throws -> [String: Any] {
        guard let group = keychain.accessGroup(), !group.isEmpty else { throw FeedbackKeyFailure.accessGroupMissing }
        var query = itemQuery(service: service, account: account)
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrAccessGroup as String] = group
        return query
    }

    private func matching(_ query: [String: Any]) throws -> Any? {
        let (status, result) = keychain.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FeedbackKeyFailure.keychain(status) }
        guard let result else { throw FeedbackKeyFailure.verificationFailed }
        return result
    }

    private func legacyKey(_ item: LegacyItem) throws -> Curve25519.KeyAgreement.PrivateKey? {
        var query = itemQuery(service: item.service, account: item.account)
        query[kSecReturnData as String] = true
        guard let item = try matching(query) else { return nil }
        guard let raw = item as? Data, let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            throw FeedbackKeyFailure.verificationFailed
        }
        return key
    }

    private func readProtected(_ query: [String: Any]) throws -> Curve25519.KeyAgreement.PrivateKey? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        guard let item = try matching(query) else { return nil }
        guard let attributes = item as? [String: Any],
              let raw = attributes[kSecValueData as String] as? Data,
              let fingerprint = attributes[kSecAttrGeneric as String] as? Data,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw),
              FeedbackEnvelope.keyID(key.publicKey) == fingerprint else {
            throw FeedbackKeyFailure.verificationFailed
        }
        return key
    }

    private func copyToProtected(_ key: Curve25519.KeyAgreement.PrivateKey, query: [String: Any], account: String,
                                 mustMatch: Bool) throws -> Curve25519.KeyAgreement.PrivateKey {
        let fingerprint = FeedbackEnvelope.keyID(key.publicKey)
        var item = query
        item[kSecAttrLabel as String] = "\(service) / \(account)"
        item[kSecAttrGeneric as String] = fingerprint
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecValueData as String] = key.rawRepresentation
        let status = keychain.add(item)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw FeedbackKeyFailure.keychain(status) }
        guard let saved = try readProtected(query),
              (!mustMatch && status == errSecDuplicateItem) || FeedbackEnvelope.keyID(saved.publicKey) == fingerprint else {
            throw FeedbackKeyFailure.verificationFailed
        }
        return saved
    }
}

public final class MemoryFeedbackKeyStore: FeedbackKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    public init() {}

    public func key(id: Data) -> Curve25519.KeyAgreement.PrivateKey? {
        lock.withLock { keys.values.first { FeedbackEnvelope.keyID($0.publicKey) == id } }
    }

    public func makeKey(account: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.withLock {
            if let existing = keys[account] { return existing }
            let made = Curve25519.KeyAgreement.PrivateKey()
            keys[account] = made
            return made
        }
    }

    public func migrateLegacyKeys() throws -> Int { 0 }
}
