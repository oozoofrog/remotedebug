import CryptoKit
import Foundation
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

    @Test func 지문이_맞는_키로_연다() throws {
        let store = MemoryFeedbackKeyStore()
        let other = try store.makeKey(account: "Other v1")
        let mine = try store.makeKey(account: "Sample v1")
        #expect(other.rawRepresentation != mine.rawRepresentation)
        let report = Data(#"{"diagnostics":{"event":"settingsOpened"},"format":1}"#.utf8)
        let sealed = try seal(report, to: mine.publicKey)
        #expect(try FeedbackEnvelope.open(sealed, keys: store.allKeys()) == report)
    }

    @Test func 같은_이름의_키는_다시_만들지_않는다() throws {
        let store = MemoryFeedbackKeyStore()
        let first = try store.makeKey(account: "Sample v1")
        #expect(try store.makeKey(account: "Sample v1").rawRepresentation == first.rawRepresentation)
    }

    @Test func 키가_없거나_바뀐_파일은_열지_않는다() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        var sealed = try seal(Data("{}".utf8), to: key.publicKey)
        #expect(throws: FeedbackEnvelope.Failure.unknownKey) { try FeedbackEnvelope.open(sealed, keys: [Curve25519.KeyAgreement.PrivateKey()]) }
        #expect(throws: FeedbackEnvelope.Failure.malformed) { try FeedbackEnvelope.open(Data("hello".utf8), keys: [key]) }
        sealed[sealed.count - 1] ^= 0x01
        #expect(throws: FeedbackEnvelope.Failure.damaged) { try FeedbackEnvelope.open(sealed, keys: [key]) }
    }
}
