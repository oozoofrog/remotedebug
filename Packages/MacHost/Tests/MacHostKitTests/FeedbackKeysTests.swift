import CryptoKit
import Foundation
import Security
import Synchronization
import Testing
@testable import MacHostKit

@Suite struct FeedbackKeysTests {
    /// `RemoteDebugFeedback` 패키지의 `FeedbackSealing.seal`과 같은 방식으로 봉한다.
    private func seal(_ plaintext: Data, to key: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let compressed = try (plaintext as NSData).compressed(using: .lzfse) as Data
        let header = FeedbackEnvelope.magic + FeedbackEnvelope.keyID(key)
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: FeedbackEnvelope.suite, info: FeedbackEnvelope.info)
        let ciphertext = try sender.seal(compressed, authenticating: header)
        return header + sender.encapsulatedKey + ciphertext
    }

    @Test func 지문이_맞는_키만_읽는다() throws {
        let keychain = FeedbackKeychainDouble()
        let store = keychain.store
        _ = try store.makeKey(account: "Other v1")
        let mine = try store.makeKey(account: "Sample v1")
        let fingerprint = FeedbackEnvelope.keyID(mine.publicKey)
        let report = Data(#"{"diagnostics":{"event":"settingsOpened"},"format":1}"#.utf8)
        let sealed = try seal(report, to: mine.publicKey)

        keychain.resetReads()
        #expect(try FeedbackEnvelope.open(sealed, keys: store) == report)
        #expect(keychain.state.withLock { $0.fingerprintQueries } == [fingerprint])
        #expect(keychain.state.withLock { $0.protectedReads } == ["Sample v1"])
        #expect(keychain.state.withLock { $0.legacyReads.isEmpty })
    }

    @Test func 이미_만든_키를_다시_쓴다() throws {
        let store = FeedbackKeychainDouble().store
        let first = try store.makeKey(account: "Sample v1")
        #expect(try store.makeKey(account: "Sample v1").rawRepresentation == first.rawRepresentation)
    }

    @Test func 모르는_지문은_개인키를_읽지_않는다() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let keychain = FeedbackKeychainDouble(legacy: ["Sample v1": key.rawRepresentation])
        let store = keychain.store
        _ = try store.makeKey(account: "Other v1")
        let sealed = try seal(Data("{}".utf8), to: key.publicKey)

        keychain.resetReads()
        #expect(throws: FeedbackEnvelope.Failure.unknownKey) { try FeedbackEnvelope.open(sealed, keys: store) }
        #expect(keychain.state.withLock { $0.fingerprintQueries } == [FeedbackEnvelope.keyID(key.publicKey)])
        #expect(keychain.state.withLock { $0.legacyReads.isEmpty && $0.protectedReads.isEmpty })
    }

    @Test func 잘못된_헤더와_손상된_암호문을_구분한다() throws {
        let keychain = FeedbackKeychainDouble()
        let store = keychain.store
        let key = try store.makeKey(account: "Sample v1")
        var sealed = try seal(Data("{}".utf8), to: key.publicKey)
        keychain.resetReads()
        #expect(throws: FeedbackEnvelope.Failure.malformed) { try FeedbackEnvelope.open(Data("hello".utf8), keys: store) }
        #expect(keychain.state.withLock { $0.fingerprintQueries.isEmpty })
        sealed[sealed.count - 1] ^= 0x01
        #expect(throws: FeedbackEnvelope.Failure.damaged) { try FeedbackEnvelope.open(sealed, keys: store) }
    }

    @Test func 기존_키를_복사하고_다시_이전할_때는_읽지_않는다() throws {
        let first = Curve25519.KeyAgreement.PrivateKey()
        let second = Curve25519.KeyAgreement.PrivateKey()
        let originals = ["First v1": first.rawRepresentation, "Second v1": second.rawRepresentation]
        let keychain = FeedbackKeychainDouble(legacy: originals)
        let store = keychain.store
        #expect(try store.migrateLegacyKeys() == 2)
        #expect(keychain.state.withLock { $0.legacyReads } == ["First v1", "Second v1"])
        #expect(keychain.state.withLock { $0.legacy } == originals)
        let sealed = try seal(Data("{}".utf8), to: second.publicKey)
        keychain.resetReads()

        #expect(try store.migrateLegacyKeys() == 0)
        #expect(try FeedbackEnvelope.open(sealed, keys: store) == Data("{}".utf8))
        #expect(keychain.state.withLock { $0.legacyReads.isEmpty })
    }

    @Test func 지문_검증이_실패해도_원본을_보존한다() throws {
        let original = Curve25519.KeyAgreement.PrivateKey()
        let keychain = FeedbackKeychainDouble(legacy: ["Sample v1": original.rawRepresentation])
        keychain.state.withLock { $0.substituteRead = Curve25519.KeyAgreement.PrivateKey().rawRepresentation }
        let store = keychain.store

        #expect(throws: FeedbackKeyFailure.verificationFailed) { try store.migrateLegacyKeys() }
        #expect(keychain.state.withLock { $0.legacy["Sample v1"] } == original.rawRepresentation)
        keychain.state.withLock { $0.substituteRead = nil }
        #expect(try store.migrateLegacyKeys() == 0)
        #expect(try store.key(id: FeedbackEnvelope.keyID(original.publicKey))?.rawRepresentation == original.rawRepresentation)
    }

    @Test func 별도_서비스의_진단_키는_지문이_맞을_때만_이전한다() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let id = FeedbackEnvelope.keyID(key.publicKey)
        let account = id.map { String(format: "%02x", $0) }.joined()
        let keychain = FeedbackKeychainDouble()
        keychain.state.withLock {
            $0.otherLegacy["App feedback diagnostics"] = [account: key.rawRepresentation]
            $0.otherLegacy["Unrelated"] = [account: Data()]
            $0.otherLegacy["Another app feedback diagnostics"] = ["ordinary account": Data()]
        }
        let store = keychain.store
        #expect(try store.migrateLegacyKeys() == 1)
        #expect(try store.key(id: id)?.rawRepresentation == key.rawRepresentation)
        #expect(keychain.state.withLock { $0.legacyReads } == [account])
        #expect(keychain.state.withLock { $0.otherLegacy["App feedback diagnostics"]?[account] } == key.rawRepresentation)

        keychain.state.withLock { $0.otherLegacy["Invalid feedback diagnostics"] = ["0000000000000000": key.rawRepresentation] }
        #expect(throws: FeedbackKeyFailure.verificationFailed) { try store.migrateLegacyKeys() }
        #expect(try store.key(id: id)?.rawRepresentation == key.rawRepresentation)
        #expect(keychain.state.withLock { $0.protected.count } == 1)
    }

    @Test func 기존_키를_거부하면_대체_키를_생성하지_않는다() throws {
        let original = Curve25519.KeyAgreement.PrivateKey()
        let keychain = FeedbackKeychainDouble(legacy: ["Sample v1": original.rawRepresentation])
        keychain.state.withLock { $0.denyLegacy = true }
        let store = keychain.store
        #expect(throws: FeedbackKeyFailure.keychain(errSecUserCanceled)) { try store.migrateLegacyKeys() }
        #expect(throws: FeedbackKeyFailure.keychain(errSecUserCanceled)) { try store.makeKey(account: "Sample v1") }
        #expect(keychain.state.withLock { $0.protected.isEmpty })
        #expect(keychain.state.withLock { $0.legacy["Sample v1"] } == original.rawRepresentation)
        keychain.state.withLock { $0.denyLegacy = false }
        #expect(try store.makeKey(account: "Sample v1").rawRepresentation == original.rawRepresentation)
    }

    @Test func 저장이_실패하면_이전을_재시도할_수_있다() throws {
        let original = Curve25519.KeyAgreement.PrivateKey()
        let keychain = FeedbackKeychainDouble(legacy: ["Sample v1": original.rawRepresentation])
        let store = keychain.store
        keychain.state.withLock { $0.addStatus = errSecNotAvailable }
        #expect(throws: FeedbackKeyFailure.keychain(errSecNotAvailable)) { try store.migrateLegacyKeys() }
        #expect(keychain.state.withLock { $0.legacy["Sample v1"] } == original.rawRepresentation)
        keychain.state.withLock { $0.addStatus = errSecSuccess }
        #expect(try store.migrateLegacyKeys() == 1)
    }

    @Test func 권한_없는_빌드가_기존_개인키를_읽지_않는다() throws {
        let keychain = FeedbackKeychainDouble(accessGroup: nil)
        #expect(throws: FeedbackKeyFailure.accessGroupMissing) { try keychain.store.migrateLegacyKeys() }
        #expect(keychain.state.withLock { $0.legacyReads.isEmpty })
    }

    @MainActor @Test func 파일을_가져와_기록_id를_돌려준다() async throws {
        let folder = try TempDir("diagnostics")
        let paths = HostPaths(root: folder.path("state"))
        try paths.prepare()
        let keychain = MemoryFeedbackKeyStore()
        let key = try keychain.makeKey(account: "Sample v1")
        let host = HostModel(core: FakeHostCore(), paths: paths, bookmarks: FakeBookmarks(), id8: "00000000", feedbackKeys: keychain)
        let source = folder.path("피드백.AFDIAG")
        let sealed = try seal(Data(#"{"diagnostics":{"app":{"bundleId":"com.example.Sample","version":"1.2","build":"7"}}}"#.utf8), to: key.publicKey)
        try sealed.write(to: source)

        let index = paths.crashLogsDir.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let failed = await host.importDiagnostics(source)
        #expect(throws: DiagnosticsFailure.self) { try failed.get() }
        #expect(host.crashLogs.items.isEmpty)
        try FileManager.default.removeItem(at: index)

        let id = try await host.importDiagnostics(source).get()
        #expect(try await host.importDiagnostics(source).get() == id)
        let items = host.crashLogs.items
        #expect(items.count == 1)
        #expect(items.first?.isImported == true)
        #expect(items.first?.appVersion == "1.2 (7)")
        #expect(CrashLogStore.reportText(directory: paths.crashLogsDir, id: id)?.contains("com.example.Sample") == true)
    }
}

private final class FeedbackKeychainDouble: Sendable {
    private let defaultService = "RemoteDebug feedback diagnostics"

    struct ProtectedItem {
        let raw: Data
        let fingerprint: Data
    }

    struct State {
        var legacy: [String: Data]
        var otherLegacy: [String: [String: Data]] = [:]
        var protected: [String: ProtectedItem] = [:]
        var legacyReads: [String] = []
        var fingerprintQueries: [Data] = []
        var protectedReads: [String] = []
        var substituteRead: Data?
        var denyLegacy = false
        var addStatus = errSecSuccess
    }

    let state: Mutex<State>
    let accessGroup: String?

    init(legacy: [String: Data] = [:], accessGroup: String? = "TEAM.example.RemoteDebug") {
        state = Mutex(State(legacy: legacy))
        self.accessGroup = accessGroup
    }

    var store: KeychainFeedbackKeyStore {
        KeychainFeedbackKeyStore(keychain: FeedbackKeychain(
            accessGroup: { self.accessGroup },
            copy: { self.copy($0) },
            add: { self.add($0) }
        ))
    }

    func resetReads() {
        state.withLock {
            $0.legacyReads = []
            $0.fingerprintQueries = []
            $0.protectedReads = []
        }
    }

    private func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
        let service = query[kSecAttrService as String] as? String ?? defaultService
        let account = query[kSecAttrAccount as String] as? String
        let fingerprint = query[kSecAttrGeneric as String] as? Data
        return state.withLock { state in
            if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
                #expect(query[kSecAttrAccessGroup as String] as? String == accessGroup)
                if let fingerprint { state.fingerprintQueries.append(fingerprint) }
                let name = account ?? state.protected.first { $0.value.fingerprint == fingerprint }?.key
                guard let name, let item = state.protected[name] else { return (errSecItemNotFound, nil) }
                state.protectedReads.append(name)
                return (errSecSuccess, [
                    kSecValueData as String: state.substituteRead ?? item.raw,
                    kSecAttrGeneric as String: item.fingerprint,
                ])
            }
            if let account {
                state.legacyReads.append(account)
                if state.denyLegacy { return (errSecUserCanceled, nil) }
                let items = service == defaultService ? state.legacy : state.otherLegacy[service] ?? [:]
                guard let data = items[account] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            }
            #expect(query[kSecReturnData as String] == nil)
            var services = state.otherLegacy
            services[defaultService] = state.legacy
            let attributes = services.flatMap { name, accounts in
                accounts.keys.map { [kSecAttrService as String: name, kSecAttrAccount as String: $0] }
            }
            return (errSecSuccess, attributes)
        }
    }

    private func add(_ query: [String: Any]) -> OSStatus {
        guard query[kSecUseDataProtectionKeychain as String] as? Bool == true,
              query[kSecAttrAccessGroup as String] as? String == accessGroup,
              let account = query[kSecAttrAccount as String] as? String,
              let raw = query[kSecValueData as String] as? Data,
              let fingerprint = query[kSecAttrGeneric as String] as? Data else { return errSecParam }
        return state.withLock {
            guard $0.addStatus == errSecSuccess else { return $0.addStatus }
            guard $0.protected[account] == nil else { return errSecDuplicateItem }
            $0.protected[account] = ProtectedItem(raw: raw, fingerprint: fingerprint)
            return errSecSuccess
        }
    }
}
