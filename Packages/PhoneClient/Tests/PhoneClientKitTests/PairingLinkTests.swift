import Foundation
import Testing

@testable import PhoneClientKit

@Suite struct PairingLinkTests {
    @Test func parsesValidLink() throws {
        let link = try #require(PairingLink(url: URL(string: "remotedebug://pair?host=\(hostFQDN)&code=K7M29QXD")!))
        #expect(link.host == hostFQDN)
        #expect(link.code.normalized == "K7M29QXD")
        #expect(link.code.display == "K7M2-9QXD")
    }

    @Test func readsOptionalAuthKey() throws {
        let link = try #require(PairingLink(url: URL(string: "remotedebug://pair?host=\(hostFQDN)&code=K7M29QXD&key=tskey-auth-kAbc123CNTRL-xyz789")!))
        #expect(link.authKey == "tskey-auth-kAbc123CNTRL-xyz789")
        #expect(link.url.absoluteString.hasSuffix("&key=tskey-auth-kAbc123CNTRL-xyz789"))
        #expect(!link.description.contains("tskey"))
        #expect(PairingLink(url: URL(string: "remotedebug://pair?host=\(hostFQDN)&code=K7M29QXD")!)?.authKey == nil)
        #expect(throws: PairingLinkError.invalidAuthKey) {
            try PairingLink.parse(text: "remotedebug://pair?host=\(hostFQDN)&code=K7M29QXD&key=tskey-api-secret")
        }
        #expect(throws: PairingLinkError.invalidAuthKey) {
            try PairingLink.parse(text: "remotedebug://pair?host=\(hostFQDN)&code=K7M29QXD&key=tskey-auth-a%20b")
        }
        #expect(throws: PairingLinkError.notPairingLink) {
            try PairingLink.parse(text: "remotedebug://pair?host=\(hostFQDN)&code=K7M29QXD&key=tskey-auth-a&key=tskey-auth-b")
        }
    }

    @Test func ignoresHyphensCaseAndWhitespace() throws {
        let link = try #require(PairingLink(text: "  remotedebug://pair?host=RD-MAC-AB12CD34.Example-Tailnet.TS.NET.&code=k7m2-9qxd\n"))
        #expect(link.host == hostFQDN)
        #expect(link.code.normalized == "K7M29QXD")
    }

    @Test func crockfordAliases() throws {
        #expect(PairingCode("o1il-abcd")?.normalized == "0111ABCD")
        #expect(PairingCode("K7M2-9QXU") == nil)  // U는 Crockford 글자가 아니다
        #expect(PairingCode("K7M2-9QX") == nil)
        #expect(PairingCode("K7M2-9QXDE") == nil)
        #expect(PairingCode("K7M2_9QXD") == nil)
    }

    @Test(arguments: [
        "https://pair?host=\(hostFQDN)&code=K7M29QXD",
        "remotedebug://unpair?host=\(hostFQDN)&code=K7M29QXD",
        "remotedebug://pair/extra?host=\(hostFQDN)&code=K7M29QXD",
        "remotedebug://pair?host=\(hostFQDN)&host=evil.ts.net&code=K7M29QXD",
    ])
    func rejectsNonPairingLinks(_ text: String) {
        #expect(throws: PairingLinkError.notPairingLink) { try PairingLink.parse(text: text) }
        #expect(PairingLink(text: text) == nil)
    }

    @Test func reportsMissingPartsAndBadCode() {
        #expect(throws: PairingLinkError.missingHost) { try PairingLink.parse(text: "remotedebug://pair?code=K7M29QXD") }
        #expect(throws: PairingLinkError.invalidCodeLength) { try PairingLink.parse(text: "remotedebug://pair?host=\(hostFQDN)") }
        #expect(throws: PairingLinkError.invalidCodeLength) { try PairingLink.parse(text: "remotedebug://pair?host=\(hostFQDN)&code=ABC") }
        #expect(throws: PairingLinkError.invalidCodeCharacters) { try PairingLink.parse(text: "remotedebug://pair?host=\(hostFQDN)&code=K7M2-9QXU") }
        #expect(throws: PairingLinkError.invalidCodeCharacters) { try PairingCode.parse("K7M2_9QXD") }
        #expect(throws: PairingLinkError.invalidCodeCharacters) { try PairingCode.parse("K7M2-9QXé") }
        #expect(throws: PairingLinkError.invalidCodeLength) { try PairingCode.parse("K7M2-9QXDE") }
    }

    @Test func errorMessagesNameTheProblem() {
        #expect(PairingLinkError.invalidCodeLength.userMessage == "페어링 코드는 8자입니다. Mac에 표시된 코드를 다시 확인하세요.")
        #expect(PairingLinkError.invalidCodeCharacters.userMessage == "페어링 코드에 쓰지 않는 글자가 들어 있습니다. Mac에 표시된 코드를 다시 확인하세요.")
        #expect(PairingLinkError.hostNotAllowed.userMessage == "Mac 주소는 .ts.net으로 끝나는 이름이어야 합니다. Mac에 표시된 링크나 주소를 사용하세요.")
    }

    @Test(arguments: [
        "example.com", "evil.com.ts.net.example.com", "evil.ts.net.attacker.com", "ts.net", "xts.net", "a.xts.net",
        "example.ts.net", "8.8.8.8", "100.128.0.1", "100.63.255.255", "100.64.0.10", "100.127.255.254",
        "fd7a:115c:a1e0::53", "[FD7A:115C:A1E0::1]", "fd7a:115c:a1e1::1", "localhost", "127.0.0.1", "::1",
        "bad_name.ts.net", "-x.example.ts.net", "100.064.0.1", "node.example.ts.net..", ".node.example.ts.net",
        "node..example.ts.net", "node.example.ts.net:443",
    ])
    func rejectsHostsOutsideTailnet(_ host: String) {
        #expect(throws: PairingLinkError.hostNotAllowed) {
            try PairingLink(host: host, code: "K7M29QXD")
        }
    }

    @Test(arguments: [
        ("node.example.ts.net", "node.example.ts.net"),
        ("NODE.Example.TS.NET.", "node.example.ts.net"),
        (" rd-mac-ab12cd34.example-tailnet.ts.net ", "rd-mac-ab12cd34.example-tailnet.ts.net"),
    ])
    func acceptsTailnetHosts(_ host: String, _ expected: String) throws {
        #expect(try PairingLink(host: host, code: "K7M29QXD").host == expected)
    }

    @Test func loopbackOnlyWithTestPolicy() throws {
        for host in ["localhost", "127.0.0.1", "::1"] {
            #expect(HostPolicy.tailnetOnly.validatedHost(host) == nil)
            #expect(HostPolicy.allowingLoopbackForTesting.validatedHost(host) == host)
        }
        #expect(HostPolicy.allowingLoopbackForTesting.validatedHost("[::1]") == "::1")
        #expect(HostPolicy.allowingLoopbackForTesting.validatedHost("example.com") == nil)
        #expect(HostPolicy.allowingLoopbackForTesting.validatedHost("100.64.0.10") == nil)
        #expect(HostPolicy.allowingLoopbackForTesting.validatedHost(hostFQDN) == hostFQDN)
    }

    @Test func descriptionHidesCode() throws {
        let link = try PairingLink(host: hostFQDN, code: "K7M29QXD")
        #expect(!String(describing: link).contains("K7M2"))
        #expect(!String(reflecting: link.code).contains("K7M2"))
        #expect(link.url.absoluteString == "remotedebug://pair?host=\(hostFQDN)&code=K7M29QXD")
    }
}
