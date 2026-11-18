import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

// USB 케이블 직접 연결(docs/protocol-addenda.md Q): 케이블 인터페이스 고르기, 링크 로컬 주소, 경로 선택, 화면 문구.

private let cableAddress = "fe80::1c2d:3e4f:5a6b:7c8d%anpi0"
private let wifiAddress = "192.168.0.10"
private let directPort = 49152

@MainActor
@Suite("USB 케이블 직접 연결")
struct CableRouteTests {
    // MARK: 인터페이스와 주소

    @Test func cableInterfacesComeBeforeAnythingElse() {
        let found = [
            DirectInterface(name: "en0", kind: .wifi),
            DirectInterface(name: "utun3", kind: .other),
            DirectInterface(name: "en2", kind: .wired),
            DirectInterface(name: "anpi0", kind: .other),
            DirectInterface(name: "awdl0", kind: .other),
            DirectInterface(name: "pdp_ip0", kind: .cellular),
            DirectInterface(name: "lo0", kind: .loopback),
        ]
        #expect(DirectResolution.cableCandidates(found).map(\.name) == ["anpi0", "en2"])
        #expect(DirectResolution.cableCandidates([DirectInterface(name: "en0", kind: .wifi)]).isEmpty)
    }

    @Test func linkLocalAddressOnACableInterfaceIsACableEndpoint() {
        let cable = DirectInterface(name: "anpi0", kind: .other)
        let wired = DirectInterface(name: "en2", kind: .wired)
        #expect(DirectResolution.endpoint(address: "fe80::1c2d:3e4f:5a6b:7c8d", port: directPort, interface: cable)
            == DirectEndpoint(host: cableAddress, port: directPort, link: .cable))
        // 이미 붙어 온 인터페이스는 떼고 연결이 지난 인터페이스를 붙인다.
        #expect(DirectResolution.endpoint(address: "fe80::1%en9", port: directPort, interface: wired)?.host == "fe80::1%en2")
        #expect(DirectResolution.endpoint(address: "169.254.10.20", port: directPort, interface: wired)
            == DirectEndpoint(host: "169.254.10.20", port: directPort, link: .cable))
    }

    @Test func otherAddressesStayOnTheNetworkRules() {
        let wifi = DirectInterface(name: "en0", kind: .wifi)
        let wired = DirectInterface(name: "en2", kind: .wired)
        // 같은 네트워크는 이전처럼 IPv4만 쓴다.
        #expect(DirectResolution.endpoint(address: wifiAddress, port: directPort, interface: wifi)
            == DirectEndpoint(host: wifiAddress, port: directPort, link: .network))
        #expect(DirectResolution.endpoint(address: wifiAddress, port: directPort, interface: nil)?.link == .network)
        #expect(DirectResolution.endpoint(address: "fe80::1", port: directPort, interface: wifi) == nil)
        #expect(DirectResolution.endpoint(address: "fe80::1", port: directPort, interface: nil) == nil)
        // 유선 랜(USB 이더넷 어댑터)의 사설 주소는 케이블 경로가 아니다.
        #expect(DirectResolution.endpoint(address: "10.0.0.5", port: directPort, interface: wired)?.link == .network)
        // 셀룰러·루프백으로 닿은 주소, 이름이 이상한 인터페이스는 쓰지 않는다.
        #expect(DirectResolution.endpoint(address: wifiAddress, port: directPort, interface: DirectInterface(name: "pdp_ip0", kind: .cellular)) == nil)
        #expect(DirectResolution.endpoint(address: "fe80::1", port: directPort, interface: DirectInterface(name: "lo0", kind: .loopback)) == nil)
        #expect(DirectResolution.endpoint(address: "fe80::1", port: directPort, interface: DirectInterface(name: "en2]@x", kind: .wired)) == nil)
        #expect(DirectResolution.endpoint(address: wifiAddress, port: 0, interface: wifi) == nil)
    }

    @Test func scopedLinkLocalAddressBecomesAnRFC6874URL() {
        #expect(HostAPI.directAuthority(cableAddress) == "[fe80::1c2d:3e4f:5a6b:7c8d%25anpi0]")
        #expect(HostAPI.directAuthority("fe80::1") == "[fe80::1]")
        #expect(HostAPI.directAuthority(wifiAddress) == wifiAddress)
        // 인터페이스는 링크 로컬 IPv6에만 붙는다. 주소나 인터페이스에 다른 글자가 있으면 만들지 않는다.
        for bad in ["192.168.0.10%en0", "fd00::1%en0", "fe80::1%", "fe80::1%en0%en1", "fe80::1%en0/x", "fe80::1%en0]:1", "fe80::1]@example.com", "example.com", ""] {
            #expect(HostAPI.directAuthority(bad) == nil, "\(bad)")
        }
    }

    @Test func requestsOverTheCableCarryTheTokenToTheScopedAddress() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/v1/info", .json(Examples.info))
        let api = try #require(HostAPI(direct: DirectEndpoint(host: cableAddress, port: directPort, link: .cable), authorization: "RD-Device d.t",
                                       transport: transport, client: ClientInfo(osVersion: "26.1", appVersion: "0.1.0")))
        #expect(api.isDirect)
        #expect(api.directLink == .cable)
        _ = try await api.info()
        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://[fe80::1c2d:3e4f:5a6b:7c8d%25anpi0]:49152/v1/info")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "RD-Device d.t")
    }

    // MARK: 경로 선택

    @Test func cableWithoutWiFiReachesTheMacWithoutVPN() async {
        let h = DirectHarness(enrolled: credential(last: nil))
        h.network.isOnLocalNetwork = false
        h.network.isCablePlugged = true
        let mac = h.serveMac(at: cableAddress)
        h.browser.result = DirectEndpoint(host: cableAddress, port: directPort, link: .cable)
        await h.model.restore()

        #expect(h.model.builds.count == 1)
        #expect(h.model.directLink == .cable)
        #expect(h.tunnel.autoStartCount == 0)
        #expect(h.tailnet.requests.isEmpty)
        #expect(mac.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == DirectHarness.authorization })
        // 케이블만 있을 때는 짧게 찾는다(충전기일 수도 있다).
        #expect(h.browser.calls.map(\.timeout) == [.seconds(1)])
        // 다음에는 Bonjour를 기다리지 않게 주소와 길을 기억한다.
        #expect(h.credentials.load()?.lastAddress == cableAddress)
        #expect(h.credentials.load()?.lastLink == .cable)
        #expect(h.model.logBook.recent.contains { $0.message == "USB 케이블로 Mac에 직접 연결" })
    }

    @Test func pluggedCableIsPreferredOverTheKnownWiFiAddress() async {
        let h = DirectHarness()
        h.network.isCablePlugged = true
        let wifi = h.serveMac()
        let cable = h.serveMac(at: cableAddress)
        h.browser.result = DirectEndpoint(host: cableAddress, port: directPort, link: .cable)
        await h.model.restore()

        #expect(h.model.directLink == .cable)
        #expect(cable.count("GET", "/v1/builds") == 1)
        #expect(wifi.count("GET", "/v1/builds") == 0)
    }

    @Test func chargerWithoutAMacFallsBackToTheNetworkPath() async {
        // 케이블은 꽂혀 있지만 Mac이 아니다: Bonjour는 Wi-Fi의 광고만 찾는다.
        let h = DirectHarness()
        h.network.isCablePlugged = true
        h.serveMac()
        h.browser.result = DirectEndpoint(host: wifiAddress, port: directPort)
        await h.model.restore()

        #expect(h.model.directLink == .network)
        #expect(h.model.builds.count == 1)
        #expect(h.tunnel.autoStartCount == 0)
    }

    @Test func noCableAndNoWiFiGoesThroughTheVPN() async {
        let h = DirectHarness()
        h.network.isOnLocalNetwork = false
        h.serveTailnet()
        await h.model.restore()

        #expect(h.model.directLink == nil)
        #expect(h.browser.calls.isEmpty)
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.model.builds.count == 1)
    }

    @Test func unpluggingTheCableFindsTheNetworkPathAgain() async {
        let h = DirectHarness(enrolled: credential(last: nil))
        h.network.isCablePlugged = true
        h.serveMac(at: cableAddress)
        let wifi = h.serveMac()
        h.browser.result = DirectEndpoint(host: cableAddress, port: directPort, link: .cable)
        await h.model.restore()
        #expect(h.model.directLink == .cable)

        // 뽑았다: 앱이 경로가 바뀌었다고 알리고, 케이블 주소는 더 닿지 않는다.
        h.network.isCablePlugged = false
        h.lan.remove(cableAddress)
        h.browser.result = DirectEndpoint(host: wifiAddress, port: directPort)
        h.model.noteNetworkChange()
        #expect(h.model.directLink == nil)
        await h.model.refresh()

        #expect(h.model.directLink == .network)
        #expect(wifi.count("GET", "/v1/builds") == 1)
        #expect(h.credentials.load()?.lastLink == .network)
        #expect(h.tunnel.autoStartCount == 0)
    }

    @Test func cableEndpointWithAnotherKeyNeverGetsTheToken() async {
        // 케이블 건너편이 광고 이름만 흉내 낸 다른 기기다: 공개 키가 달라 TLS에서 끊기고 토큰은 나가지 않는다.
        let h = DirectHarness(enrolled: credential(last: nil))
        h.network.isOnLocalNetwork = false
        h.network.isCablePlugged = true
        let impostor = h.serveMac(at: cableAddress, spki: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        h.browser.result = DirectEndpoint(host: cableAddress, port: directPort, link: .cable)
        h.serveTailnet()
        await h.model.restore()

        #expect(impostor.requests.isEmpty)
        #expect(h.lan.rejectedHandshakes > 0)
        #expect(h.model.directLink == nil)
        #expect(h.model.builds.count == 1)
    }

    @Test func credentialSavedByAnOlderVersionStillDecodes() throws {
        let old = #"{"hostId":"h_4be0c7a1","directId":"0123456789abcdef","deviceId":"d_1a2b3c4d","token":"TOKEN-1","spki":"x","port":49152,"lastAddress":"192.168.0.10"}"#
        let decoded = try JSONDecoder().decode(DirectCredential.self, from: Data(old.utf8))
        #expect(decoded.lastLink == nil)
        #expect(decoded.lastAddress == wifiAddress)
    }

    // MARK: 화면

    @Test func statusTextNamesTheCable() {
        #expect(VPNStatusText.direct(.cable) == "USB 연결(케이블, VPN 없이)")
        #expect(VPNStatusText.direct(.network) == VPNStatusText.direct)
        #expect(VPNStatusText.directDetail(.cable) != VPNStatusText.directDetail)
        #expect(VPNStatusText.directWithVPNDetail(.network) == VPNStatusText.directWithVPNDetail)
    }

    private func credential(last: String?) -> DirectCredential {
        var value = DirectHarness.credential
        value.lastAddress = last
        return value
    }
}
