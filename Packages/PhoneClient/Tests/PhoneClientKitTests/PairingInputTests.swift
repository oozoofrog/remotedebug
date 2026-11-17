import Foundation
import Testing

@testable import PhoneClientKit

/// 링크·QR 글자 읽기, 호스트 정책, 기기 이름.
@Suite struct PairingInputTests {
    private let service = FakePairing()

    private func read(_ text: String, policy: HostPolicy = .tailnetOnly) throws(PairingOfferIssue) -> PairingProposal {
        try PairingInput.read(text, with: service, policy: policy)
    }

    // MARK: 새 링크

    @Test func readsTheLinkAndKeepsTheKey() throws {
        let proposal = try read(pairingLink(key: "tskey-auth-kTest1CNTRL-abc"))
        #expect(proposal.host == hostFQDN)
        #expect(proposal.expires == t0.addingTimeInterval(300))
        #expect(proposal.authKey == "tskey-auth-kTest1CNTRL-abc")
        let withoutKey = try read(pairingLink())
        #expect(withoutKey.authKey == nil)
    }

    @Test func trimsWhitespaceAndAcceptsSchemeInAnyCase() throws {
        let padded = try read("  \(pairingLink())\n")
        let upper = try read(pairingLink().replacingOccurrences(of: "remotedebug://pair", with: "RemoteDebug://PAIR"))
        let slash = try read(pairingLink().replacingOccurrences(of: "pair#", with: "pair/#"))
        #expect([padded.host, upper.host, slash.host] == [hostFQDN, hostFQDN, hostFQDN])
    }

    @Test func sameLinkIsTheSameProposalAndOtherLinksAreNot() throws {
        let first = try read(pairingLink())
        let again = try read(pairingLink())
        let other = try read(pairingLink(secret: "s2"))
        #expect(first == again)
        #expect(first != other)
    }

    // MARK: 예전 꼴과 잘못된 링크

    @Test(arguments: [
        "remotedebug://pair?host=rd-mac-ab12cd34.example-tailnet.ts.net&code=K7M29QXD",
        "remotedebug://pair?host=rd-mac-ab12cd34.example-tailnet.ts.net&code=K7M29QXD&key=tskey-auth-a",
        "remotedebug://pair/?code=K7M29QXD",
    ])
    func oldLinkAsksForANewerMacApp(_ text: String) {
        #expect(throws: PairingOfferIssue.legacyLink) { try read(text) }
        #expect(!PairingOfferIssue.legacyLink.userMessage.isEmpty)
    }

    @Test(arguments: [
        "https://pair#h=a.b.ts.net",
        "remotedebug://unpair#h=a.b.ts.net",
        "remotedebug://pair/extra#h=a.b.ts.net",
        "remotedebug://pairing#h=a.b.ts.net",
        "remotedebug://pair",
        "remotedebug://pair?x=1",
        "remotedebug://pair?host=a.b.ts.net#h=a.b.ts.net",  // 조각이 있으면 쿼리는 받지 않는다
        "hello",
        "",
    ])
    func rejectsWhatIsNotAPairingLink(_ text: String) {
        #expect(throws: PairingOfferIssue.notAnOffer) { try read(text) }
    }

    @Test func offerErrorsPassThroughFromTheService() {
        #expect(throws: PairingOfferIssue.invalidSecret) { try read(pairingLink(bad: "secret")) }
        #expect(throws: PairingOfferIssue.invalidAuthKey) { try read(pairingLink(bad: "authkey")) }
        #expect(throws: PairingOfferIssue.wrappedAuthKey) { try read(pairingLink(bad: "wrapped")) }
        #expect(throws: PairingOfferIssue.invalidHost) { try read(pairingLink(bad: "host")) }
    }

    @Test func addressCheckIsOnlyAboutTheBase() {
        #expect(PairingInput.isPairingAddress("remotedebug://pair#x"))
        #expect(PairingInput.isPairingAddress("remotedebug://pair"))
        #expect(PairingInput.isPairingAddress("remotedebug://pair?host=a"))
        #expect(PairingInput.isPairingAddress(" remotedebug://pair/ "))
        #expect(!PairingInput.isPairingAddress("remotedebug://pairing"))
        #expect(!PairingInput.isPairingAddress("remotedebug://test?probe=on"))
        #expect(!PairingInput.isPairingAddress("remotedebug-vpn://open"))
        #expect(!PairingInput.isPairingAddress("https://example.com"))
    }

    @Test(arguments: ["example.com", "100.64.0.10", "127.0.0.1", "example.ts.net", "evil.ts.net.attacker.com"])
    func hostOutsideThePolicyIsRefused(_ host: String) {
        #expect(throws: PairingOfferIssue.hostNotAllowed) { try read(pairingLink(host: host)) }
    }

    @Test func loopbackOnlyWithTheTestPolicy() throws {
        #expect(throws: PairingOfferIssue.hostNotAllowed) { try read(pairingLink(host: "localhost")) }
        let loopback = try read(pairingLink(host: "localhost"), policy: .allowingLoopbackForTesting)
        #expect(loopback.host == "localhost")
    }

    @Test func everyIssueAndFailureHasAMessage() {
        let issues: [PairingOfferIssue] = [.legacyLink, .notAnOffer, .invalidHost, .invalidPort, .invalidSecret, .invalidExpiry,
                                           .invalidAuthKey, .wrappedAuthKey, .hostNotAllowed]
        #expect(issues.allSatisfy { !$0.userMessage.isEmpty })
        let failures: [PairingFailure] = [.unreachable, .notOnTailnet, .rejected, .denied, .timedOut, .hostNotVerified,
                                          .protocolViolation, .unexpected]
        let messages = failures.compactMap(\.userMessage)
        #expect(messages.count == failures.count)
        #expect(Set(messages).count == messages.count)  // 오류마다 문구가 다르다
        #expect(PairingFailure.cancelled.userMessage == nil)
    }

    @Test func messagesPointToTheNextStep() throws {
        #expect(try #require(PairingFailure.unreachable.userMessage).contains("VPN"))
        #expect(try #require(PairingFailure.unreachable.userMessage).contains("Tailnet Lock"))
        #expect(try #require(PairingFailure.rejected.userMessage).contains("QR"))
        #expect(PairingOfferIssue.legacyLink.userMessage.contains("최신"))
    }

    // MARK: 비밀 가림

    @Test func proposalHidesSecretAndKeyEverywhere() throws {
        let key = "tskey-auth-kTest1CNTRL-abc"
        let proposal = try read(pairingLink(secret: "TopSecretValue", key: key))
        var dumped = ""
        dump(proposal, to: &dumped)
        for text in [String(describing: proposal), String(reflecting: proposal), "\(proposal)", dumped] {
            #expect(!text.contains(key))
            #expect(!text.contains("TopSecretValue"))
            #expect(!text.contains("tskey"))
        }
        #expect(String(describing: proposal).contains(hostFQDN))
    }

    // MARK: 기기 이름

    @Test(arguments: [
        ("내 iPhone", "내 iPhone"),
        ("  홍길동의 iPhone  ", "홍길동의 iPhone"),
        ("iPhone\u{202E}evil", "iPhoneevil"),          // 방향 바꿈(Cf)
        ("iPhone\u{0007}\u{0000}", "iPhone"),           // 제어 문자(Cc)
        ("a\u{200B}b", "ab"),                            // 폭 없는 공백(Cf)
        ("", "iPhone"),
        ("   ", "iPhone"),
        ("\u{202E}", "iPhone"),
    ])
    func deviceNameFollowsTheLibraryRules(_ input: String, _ expected: String) {
        #expect(PairingDeviceName.sanitized(input) == expected)
    }

    @Test func deviceNameKeepsJoinersOfEmojiSequences() {
        let family = "👨‍👩‍👧"  // U+200D로 이은 이모지
        #expect(PairingDeviceName.sanitized(family) == family)
        #expect(PairingDeviceName.sanitized("می\u{200C}خواهم") == "می\u{200C}خواهم")
    }

    @Test func deviceNameIsCutAtCharacterBoundaryTo64Bytes() {
        let long = String(repeating: "가", count: 40)  // 120바이트
        let cut = PairingDeviceName.sanitized(long)
        #expect(cut.utf8.count <= PairingDeviceName.maxBytes)
        #expect(cut == String(repeating: "가", count: 21))  // 63바이트
        let emoji = String(repeating: "👨‍👩‍👧", count: 5)  // 한 글자가 18바이트
        let emojiCut = PairingDeviceName.sanitized(emoji)
        #expect(emojiCut.utf8.count <= PairingDeviceName.maxBytes)
        #expect(emojiCut == String(repeating: "👨‍👩‍👧", count: 3))
    }

    // MARK: 예전 코드 경로가 쓰는 코드와 호스트 정책

    @Test func crockfordAliases() throws {
        #expect(PairingCode("o1il-abcd")?.normalized == "0111ABCD")
        #expect(PairingCode("K7M2-9QXU") == nil)  // U는 Crockford 글자가 아니다
        #expect(PairingCode("K7M2-9QX") == nil)
        #expect(PairingCode("K7M2-9QXDE") == nil)
        #expect(PairingCode("K7M2_9QXD") == nil)
        #expect(throws: PairingCodeError.invalidCodeCharacters) { try PairingCode.parse("K7M2-9QXé") }
        #expect(throws: PairingCodeError.invalidCodeLength) { try PairingCode.parse("K7M2-9QXDE") }
        #expect(!String(reflecting: try PairingCode.parse("K7M2-9QXD")).contains("K7M2"))
    }

    @Test(arguments: [
        "example.com", "evil.com.ts.net.example.com", "evil.ts.net.attacker.com", "ts.net", "xts.net", "a.xts.net",
        "example.ts.net", "8.8.8.8", "100.128.0.1", "100.63.255.255", "100.64.0.10", "100.127.255.254",
        "fd7a:115c:a1e0::53", "[FD7A:115C:A1E0::1]", "fd7a:115c:a1e1::1", "localhost", "127.0.0.1", "::1",
        "bad_name.ts.net", "-x.example.ts.net", "100.064.0.1", "node.example.ts.net..", ".node.example.ts.net",
        "node..example.ts.net", "node.example.ts.net:443",
    ])
    func rejectsHostsOutsideTailnet(_ host: String) {
        #expect(HostPolicy.tailnetOnly.validatedHost(host) == nil)
    }

    @Test(arguments: [
        ("node.example.ts.net", "node.example.ts.net"),
        ("NODE.Example.TS.NET.", "node.example.ts.net"),
        (" rd-mac-ab12cd34.example-tailnet.ts.net ", "rd-mac-ab12cd34.example-tailnet.ts.net"),
    ])
    func acceptsTailnetHosts(_ host: String, _ expected: String) {
        #expect(HostPolicy.tailnetOnly.validatedHost(host) == expected)
    }

    @Test func loopbackOnlyWithTestPolicy() {
        for host in ["localhost", "127.0.0.1", "::1"] {
            #expect(HostPolicy.tailnetOnly.validatedHost(host) == nil)
            #expect(HostPolicy.allowingLoopbackForTesting.validatedHost(host) == host)
        }
        #expect(HostPolicy.allowingLoopbackForTesting.validatedHost("[::1]") == "::1")
        #expect(HostPolicy.allowingLoopbackForTesting.validatedHost("example.com") == nil)
        #expect(HostPolicy.allowingLoopbackForTesting.validatedHost("100.64.0.10") == nil)
        #expect(HostPolicy.allowingLoopbackForTesting.validatedHost(hostFQDN) == hostFQDN)
    }
}
