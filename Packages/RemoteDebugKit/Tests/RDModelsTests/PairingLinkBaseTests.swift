import Foundation
import Testing
@testable import RDModels

/// 페어링 링크의 연결 도메인 주소(Info.plist `RDPairLinkBase`) 읽기와 링크 판정.
@Suite struct PairingLinkBaseTests {
    @Test func readsHTTPSBaseAndNormalizes() throws {
        let base = try #require(PairingLinkBase("https://Example.COM/remotedebug/pair/"))
        #expect(base.url.absoluteString == "https://example.com/remotedebug/pair")
        #expect(base.host == "example.com")
        #expect(base.path == "/remotedebug/pair")
        #expect(PairingLinkBase(" https://links.example.com/p ")?.url.absoluteString == "https://links.example.com/p")
    }

    @Test(arguments: [
        nil, "", "   ",
        // 빌드 설정의 호스트가 비었을 때 Info.plist에 들어가는 값.
        "https:///remotedebug/pair",
        "https://", "https://example.com", "https://example.com/",
        "http://example.com/remotedebug/pair",
        "remotedebug://pair",
        "https://user@example.com/pair",
        "https://user:pw@example.com/pair",
        "https://example.com:8443/pair",
        "https://example.com/pair?x=1",
        "https://example.com/pair#v=1",
        "https://example.com/pa%20ir",
        "https://example.com/a//b",
        "https://example/pair",
        "https://192.168.1.1/pair",
        "https://-bad.example.com/pair",
        "https://exa_mple.com/pair",
        "https://https://example.com/pair",
        "example.com/remotedebug/pair",
    ] as [String?])
    func rejectsInvalidBase(_ text: String?) {
        #expect(PairingLinkBase(text) == nil)
    }

    @Test func readsFromInfoDictionary() {
        #expect(PairingLinkBase.fromInfo(["RDPairLinkBase": "https://example.com/remotedebug/pair"])?.host == "example.com")
        #expect(PairingLinkBase.fromInfo(["RDPairLinkBase": ""]) == nil)
        #expect(PairingLinkBase.fromInfo([:]) == nil)
        #expect(PairingLinkBase.fromInfo(nil) == nil)
    }

    @Test func matchesOnlySameHostAndPath() throws {
        let base = try #require(PairingLinkBase("https://example.com/remotedebug/pair"))
        #expect(base.matches("https://example.com/remotedebug/pair#v=1&h=a.b.ts.net"))
        #expect(base.matches("HTTPS://EXAMPLE.com/remotedebug/pair/#v=1"))
        #expect(base.matches("https://example.com/remotedebug/pair"))
        #expect(!base.matches("http://example.com/remotedebug/pair#v=1"))
        #expect(!base.matches("https://other.example.com/remotedebug/pair#v=1"))
        #expect(!base.matches("https://example.com.evil.test/remotedebug/pair#v=1"))
        #expect(!base.matches("https://example.com/remotedebug/pair/x#v=1"))
        #expect(!base.matches("https://example.com/remotedebug/Pair#v=1"))
        #expect(!base.matches("https://example.com/remotedebug#v=1"))
        #expect(!base.matches("https://example.com/remotedebug/pair?x=1#v=1"))
        #expect(!base.matches("https://example.com:444/remotedebug/pair#v=1"))
        #expect(!base.matches("https://u@example.com/remotedebug/pair#v=1"))
        #expect(!base.matches("https://example.com/remotedebug/p%61ir#v=1"))
        #expect(!base.matches("remotedebug://pair#v=1"))
    }
}
