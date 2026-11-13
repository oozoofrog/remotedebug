import Foundation
import RDModels
import Security
import Synchronization
import Testing

@testable import PhoneClientKit

// 같은 네트워크 직접 연결(docs/protocol-addenda.md O): 경로 선택 순서, 제한 시간, VPN 경로로 넘어가기,
// 공개 키 고정, 다시 등록하기.

private let macAddress = "192.168.0.10"
private let otherAddress = "192.168.0.11"
private let directPort = 49152
private let macSPKI = "osttffDAAJlYFwYJ11w2e1IXS9QCkb4bHAYhXUVjsek="
private let directID = "0123456789abcdef"

/// 같은 네트워크의 주소마다 서버 하나. 전송은 고정 값이 서버의 공개 키와 같을 때만 요청을 넘긴다.
final class FakeLAN: DirectTransportMaking {
    private struct State {
        var servers: [String: (spki: String, transport: FakeTransport)] = [:]
        var pins: [String] = []
        var rejectedHandshakes = 0
    }
    private let state = Mutex(State())

    /// 이 주소에 서버를 둔다.
    @discardableResult
    func serve(_ address: String, spki: String = macSPKI) -> FakeTransport {
        let transport = FakeTransport()
        state.withLock { $0.servers[address] = (spki, transport) }
        return transport
    }

    func remove(_ address: String) { state.withLock { $0.servers[address] = nil } }
    func server(_ address: String) -> FakeTransport? { state.withLock { $0.servers[address]?.transport } }
    var pins: [String] { state.withLock { $0.pins } }
    var rejectedHandshakes: Int { state.withLock { $0.rejectedHandshakes } }

    func transport(pin: String) -> any HTTPTransport {
        state.withLock { $0.pins.append(pin) }
        return Pinned(lan: self, pin: pin)
    }

    private struct Pinned: HTTPTransport {
        let lan: FakeLAN
        let pin: String

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let server = lan.state.withLock { $0.servers[request.url?.host ?? ""] }
            guard let server else { throw URLError(.cannotConnectToHost) }
            guard server.spki == pin else {
                // TLS 연결 단계에서 끊는다: 요청은 서버에 닿지 않는다.
                lan.state.withLock { $0.rejectedHandshakes += 1 }
                throw URLError(.serverCertificateUntrusted)
            }
            return try await server.transport.send(request)
        }
    }
}

final class FakeBrowser: DirectBrowsing {
    private struct State {
        var result: DirectEndpoint?
        var calls: [(id: String, timeout: Duration)] = []
    }
    private let state = Mutex(State())

    var result: DirectEndpoint? {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }
    var calls: [(id: String, timeout: Duration)] { state.withLock { $0.calls } }

    func find(directId: String, timeout: Duration) async -> DirectEndpoint? {
        state.withLock { s in
            s.calls.append((directId, timeout))
            return s.result
        }
    }
}

final class FakeNetwork: LocalNetworkChecking {
    private let value = Mutex(true)
    var isOnLocalNetwork: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

@MainActor
struct DirectHarness {
    let tailnet = FakeTransport()
    let lan = FakeLAN()
    let browser = FakeBrowser()
    let network = FakeNetwork()
    let credentials: InMemoryDirectCredentialStore
    let opener = FakeOpener()
    let tunnel: FakeTunnel
    let clock = TestClock()
    let route: DirectRoute
    let model: ClientModel

    static let credential = DirectCredential(hostId: "h_4be0c7a1", directId: directID, deviceId: "d_1a2b3c4d", token: "TOKEN-1",
                                             spki: macSPKI, port: directPort, lastAddress: macAddress)
    static let authorization = "RD-Device d_1a2b3c4d.TOKEN-1"

    init(tunnel state: TunnelState = .off, enrolled: DirectCredential? = DirectHarness.credential, autoStart: Bool = true,
         push: PushSetup? = nil) {
        tunnel = FakeTunnel(state)
        if autoStart { tunnel.autoStartConfiguration = .ready }
        credentials = InMemoryDirectCredentialStore(enrolled)
        route = DirectRoute(store: credentials, browser: browser, network: network, transports: lan, clock: clock)
        model = ClientModel(
            deviceName: "내 iPhone",
            client: ClientInfo(osVersion: "26.1", appVersion: "0.1.0"),
            transport: tailnet,
            store: InMemoryPairedHostStore(host: Harness.pairedHost),
            opener: opener,
            tunnel: tunnel,
            clock: clock,
            direct: route,
            push: push
        )
    }

    /// Mac의 직접 연결 리스너가 이 주소에서 빌드 목록을 낸다.
    @discardableResult
    func serveMac(at address: String = macAddress, spki: String = macSPKI, info: String = Examples.info) -> FakeTransport {
        let server = lan.serve(address, spki: spki)
        server.on("GET", "/v1/info", .json(info))
        server.on("GET", "/v1/builds", .json(Examples.builds))
        server.on("GET", "/v1/resources", .json(#"{"resources":[]}"#))
        server.on("POST", "/v1/logs", .json(#"{"accepted":1}"#, status: 202))
        return server
    }

    func serveTailnet() {
        tailnet.on("GET", "/v1/info", .json(Examples.info))
        tailnet.on("GET", "/v1/builds", .json(Examples.builds))
        tailnet.on("GET", "/v1/resources", .json(#"{"resources":[]}"#))
        tailnet.on("POST", "/v1/logs", .json(#"{"accepted":1}"#, status: 202))
    }

    func serveEnroll(token: String = "TOKEN-2") {
        tailnet.set("POST", "/v1/direct/enroll", .json(#"{"directId":"\#(directID)","port":\#(directPort),"tlsSPKI":"\#(macSPKI)","deviceId":"d_1a2b3c4d","token":"\#(token)"}"#))
    }
}

@MainActor
@Suite("직접 연결 경로")
struct DirectRouteTests {
    // MARK: 경로 선택

    @Test func sameNetworkUsesTheDirectPathWithoutVPN() async {
        let h = DirectHarness()
        let mac = h.serveMac()
        await h.model.restore()

        #expect(h.model.builds.count == 1)
        #expect(h.model.isDirectConnected)
        #expect(h.model.refreshError == nil)
        // VPN은 켜지 않았고 tailnet 주소로는 아무것도 보내지 않았다.
        #expect(h.tunnel.autoStartCount == 0)
        #expect(h.tunnel.state == .off)
        #expect(h.tailnet.requests.isEmpty)
        // 모든 요청이 https://<LAN IP>:<포트>로, 기기 토큰과 함께 갔다.
        #expect(!mac.requests.isEmpty)
        for request in mac.requests {
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == macAddress)
            #expect(request.url?.port == directPort)
            #expect(request.value(forHTTPHeaderField: "Authorization") == DirectHarness.authorization)
        }
        #expect(h.lan.pins.allSatisfy { $0 == macSPKI })
    }

    @Test func probeUsesOneSecondAndBrowseTwoSeconds() async {
        let h = DirectHarness()
        let mac = h.serveMac()
        await h.model.restore()
        // 첫 요청은 마지막 주소 확인이다: /v1/info, 제한 시간 1초.
        let probe = mac.requests.first
        #expect(probe?.url?.path == "/v1/info")
        #expect(probe?.timeoutInterval == 1)
        // 그 뒤의 요청은 보통 제한 시간을 쓴다.
        #expect(mac.requests.last?.timeoutInterval == HostAPI.Timeouts.standard.request)
        // Bonjour는 저장해 둔 식별자만, 2초 동안 찾는다.
        #expect(h.browser.calls.count == 1)
        #expect(h.browser.calls.first?.id == directID)
        #expect(h.browser.calls.first?.timeout == .seconds(2))
    }

    @Test func staleAddressFallsBackToBonjourAndIsRemembered() async {
        let h = DirectHarness()
        // Mac의 주소가 바뀌었다: 마지막 주소에는 아무도 없고 광고는 새 주소를 가리킨다.
        let mac = h.serveMac(at: otherAddress)
        h.browser.result = DirectEndpoint(host: otherAddress, port: directPort + 1)
        await h.model.restore()

        #expect(h.model.isDirectConnected)
        #expect(h.model.builds.count == 1)
        #expect(mac.requests.allSatisfy { $0.url?.port == directPort + 1 })
        #expect(h.credentials.load()?.lastAddress == otherAddress)
        #expect(h.credentials.load()?.port == directPort + 1)
        #expect(h.tunnel.autoStartCount == 0)
    }

    @Test func cellularSkipsDiscoveryAndUsesTheVPN() async {
        let h = DirectHarness()
        h.serveMac()
        h.serveTailnet()
        h.network.isOnLocalNetwork = false
        await h.model.restore()

        #expect(h.browser.calls.isEmpty)
        #expect(h.lan.server(macAddress)?.requests.isEmpty == true)
        #expect(!h.model.isDirectConnected)
        // phase 1 경로: VPN을 자동으로 켜고 tailnet 주소로 받는다.
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.model.builds.count == 1)
        #expect(h.tailnet.requests.allSatisfy { $0.url?.host == hostFQDN })
        #expect(h.tailnet.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func notEnrolledNeverTouchesTheLAN() async {
        let h = DirectHarness(enrolled: nil)
        h.serveMac()
        h.serveTailnet()
        await h.model.restore()
        #expect(h.browser.calls.isEmpty)
        #expect(h.lan.pins.isEmpty)
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.model.builds.count == 1)
    }

    // MARK: 공개 키 고정

    @Test func spoofedAdvertisementGetsNoToken() async {
        let h = DirectHarness()
        // 같은 식별자를 광고하는 다른 기기: 공개 키가 다르다.
        let impostor = h.serveMac(at: otherAddress, spki: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        h.browser.result = DirectEndpoint(host: otherAddress, port: directPort)
        h.serveTailnet()
        await h.model.restore()

        // TLS 연결에서 끊겨 요청(토큰)이 가지 않았다.
        #expect(impostor.requests.isEmpty)
        #expect(h.lan.rejectedHandshakes >= 1)
        #expect(!h.model.isDirectConnected)
        // VPN 경로로 넘어가 목록을 받았다.
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.model.builds.count == 1)
        #expect(h.credentials.load()?.lastAddress == macAddress, "틀린 주소를 저장하지 않는다")
    }

    @Test func anotherMacWithTheSameKeyIsNotUsed() async {
        let h = DirectHarness()
        let other = h.serveMac(info: Examples.info.replacingOccurrences(of: "h_4be0c7a1", with: "h_00000000"))
        h.serveTailnet()
        await h.model.restore()
        #expect(other.count("GET", "/v1/builds") == 0)
        #expect(!h.model.isDirectConnected)
        #expect(h.model.builds.count == 1)
    }

    @Test func directAPIRefusesPublicAddresses() {
        let client = ClientInfo(osVersion: "26.1", appVersion: "0.1.0")
        func make(_ host: String, port: Int = directPort) -> HostAPI? {
            HostAPI(direct: DirectEndpoint(host: host, port: port), authorization: "RD-Device d.t", transport: FakeTransport(), client: client)
        }
        #expect(make("192.168.0.10") != nil)
        #expect(make("10.1.2.3") != nil)
        #expect(make("169.254.7.7") != nil)
        #expect(make("fe80::1") != nil)
        for host in ["203.0.113.7", "100.64.0.1", "rd-mac-1a2b3c4d.tail0001.ts.net", "example.com", "127.0.0.1", ""] {
            #expect(make(host) == nil, "\(host)")
        }
        #expect(make("192.168.0.10", port: 0) == nil)
    }

    @Test func pinHashMatchesTheStandardSPKIDigest() throws {
        // openssl로 만든 P-256 자체 서명 인증서와, openssl이 계산한 SubjectPublicKeyInfo SHA-256.
        let der = try #require(Data(base64Encoded: "MIIBmjCCAT+gAwIBAgIUSn1eiLZPUIOz2pwuTGmv1OnZCT0wCgYIKoZIzj0EAwIwIjEgMB4GA1UEAwwXUmVtb3RlRGVidWcgZGlyZWN0IHRlc3QwHhcNMjYxMTEzMTE0MzAyWhcNNDYxMTA4MTE0MzAyWjAiMSAwHgYDVQQDDBdSZW1vdGVEZWJ1ZyBkaXJlY3QgdGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPUWI/nXeS4wMDjdLuU/7soKPcrdOpBADlqcDlzHG/RjfLBpajImMUM01yKdJh2z0PBYXJfohikBr13KNogKYESjUzBRMB0GA1UdDgQWBBT2F6O+3KX769iIvNgsEKSmRgCxUzAfBgNVHSMEGDAWgBT2F6O+3KX769iIvNgsEKSmRgCxUzAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDeegN4CqvUArGwnF08P3mMcJg0zvjgNLCTq3bIC5f2CQIhAMLJhxMbBDsqd8ZD0E2wlhWuWJOBhfKtfRiBrk+cxu2P"))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SPKIPin.hash(of: certificate) == macSPKI)

        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let made = try #require(trust)
        #expect(SPKIPin.matches(made, pin: macSPKI))
        #expect(!SPKIPin.matches(made, pin: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
        #expect(!SPKIPin.matches(made, pin: ""))
    }

    // MARK: 넘어가기

    @Test func connectionErrorRediscoversOnceThenFallsBackToTheVPN() async {
        // VPN은 사용자가 켜 둔 상태다(자동 켜기·끄기가 가상 시계를 움직이지 않게 한다).
        let h = DirectHarness(tunnel: .connected)
        h.serveMac()
        h.serveTailnet()
        await h.model.restore()
        #expect(h.model.isDirectConnected)
        let browsesBefore = h.browser.calls.count

        // Mac이 네트워크에서 사라졌다.
        h.lan.remove(macAddress)
        await h.model.refresh()

        // 한 번 다시 찾고(Bonjour 한 번 더), 없으니 VPN 경로로 받았다.
        #expect(h.browser.calls.count == browsesBefore + 1)
        #expect(!h.model.isDirectConnected)
        #expect(h.model.refreshError == nil)
        #expect(h.tailnet.count("GET", "/v1/builds") == 1)

        // 60초 안에는 다시 찾지 않는다.
        h.serveMac()
        h.clock.advance(by: 59)
        await h.model.refresh()
        #expect(h.browser.calls.count == browsesBefore + 1)
        #expect(!h.model.isDirectConnected)

        // 60초가 지나면 다음 요청에서 다시 찾아 직접 경로로 돌아온다.
        h.clock.advance(by: 2)
        let tailnetBuilds = h.tailnet.count("GET", "/v1/builds")
        await h.model.refresh()
        #expect(h.model.isDirectConnected)
        #expect(h.tailnet.count("GET", "/v1/builds") == tailnetBuilds)
    }

    @Test func networkChangeAndForegroundProbeAgainAtOnce() async {
        let h = DirectHarness()
        h.serveTailnet()
        await h.model.restore()  // Mac이 없다 → VPN 경로, 60초 쉼
        #expect(!h.model.isDirectConnected)
        let browses = h.browser.calls.count

        h.serveMac()
        h.model.noteNetworkChange()
        await h.model.refresh()
        #expect(h.browser.calls.count == browses + 1)
        #expect(h.model.isDirectConnected)

        // 앱이 다시 활성이 될 때도 다시 찾는다.
        h.lan.remove(macAddress)
        h.model.resumePolling()
        #expect(!h.model.isDirectConnected)
        await h.model.refresh()
        #expect(h.tailnet.count("GET", "/v1/builds") == 2)
    }

    @Test func httpErrorsFromTheMacDoNotSwitchPaths() async {
        let h = DirectHarness()
        let mac = h.serveMac()
        mac.set("GET", "/v1/builds", .error("internal", status: 500))
        h.serveTailnet()
        await h.model.restore()
        // Mac의 오류 응답은 경로 문제가 아니다: VPN을 켜지 않고 오류를 그대로 알린다.
        #expect(h.tunnel.autoStartCount == 0)
        #expect(h.tailnet.requests.isEmpty)
        #expect(h.model.refreshError != nil)
    }

    // MARK: 등록

    @Test func rejectedTokenReEnrollsOverTheTailnet() async {
        let h = DirectHarness()
        let mac = h.serveMac()
        // Mac이 지금 토큰을 모른다(Mac에서 기기를 지웠다가 다시 페어링했다). 다시 등록한 뒤에는 받는다.
        mac.set("GET", "/v1/info", .error("not_paired", status: 403), .json(Examples.info))
        h.serveTailnet()
        h.serveEnroll(token: "TOKEN-2")
        await h.model.restore()

        // VPN 경로로 목록을 받고 다시 등록했다.
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.model.builds.count == 1)
        #expect(h.tailnet.count("POST", "/v1/direct/enroll") == 1)
        #expect(h.credentials.load()?.token == "TOKEN-2")
        #expect(h.credentials.load()?.lastAddress == macAddress)

        // 다음 요청은 새 토큰으로 직접 간다.
        await h.model.refresh()
        #expect(h.model.isDirectConnected)
        #expect(mac.requests.last?.value(forHTTPHeaderField: "Authorization") == "RD-Device d_1a2b3c4d.TOKEN-2")
        #expect(h.tailnet.count("POST", "/v1/direct/enroll") == 1)
    }

    @Test func firstTailnetRequestEnrollsOnce() async {
        let h = DirectHarness(tunnel: .connected, enrolled: nil)
        h.serveTailnet()
        h.serveEnroll(token: "TOKEN-9")
        h.serveMac()
        h.browser.result = DirectEndpoint(host: macAddress, port: directPort)
        await h.model.restore()

        #expect(h.tailnet.count("POST", "/v1/direct/enroll") == 1)
        let saved = h.credentials.load()
        #expect(saved?.hostId == "h_4be0c7a1")
        #expect(saved?.token == "TOKEN-9")
        #expect(saved?.spki == macSPKI)
        // 등록 요청은 tailnet 주소로만 갔고, 본문이 없다.
        let enroll = h.tailnet.requests.first { $0.url?.path == "/v1/direct/enroll" }
        #expect(enroll?.url?.host == hostFQDN)
        #expect(enroll?.httpBody == nil)

        // 다음 요청부터 직접 경로(Bonjour로 주소를 찾는다).
        await h.model.refresh()
        #expect(h.model.isDirectConnected)
        #expect(h.tailnet.count("POST", "/v1/direct/enroll") == 1)
    }

    @Test func olderMacWithoutEnrollmentIsAskedRarely() async {
        let h = DirectHarness(tunnel: .connected, enrolled: nil)
        h.serveTailnet()  // 등록 경로가 없다 → 404 not_found
        await h.model.restore()
        await h.model.refresh()
        await h.model.refresh()
        #expect(h.tailnet.count("POST", "/v1/direct/enroll") == 1)
        #expect(h.model.builds.count == 1)
        #expect(h.model.refreshError == nil)
        // 10분 뒤에는 다시 물어본다(Mac 앱을 업데이트했을 수 있다).
        h.clock.advance(by: 601)
        await h.model.refresh()
        #expect(h.tailnet.count("POST", "/v1/direct/enroll") == 2)
    }

    @Test func tokenFromThePairedAppIsAdoptedInsteadOfRotating() async {
        let h = DirectHarness()
        let mac = h.serveMac()
        mac.set("GET", "/v1/info", .error("not_paired", status: 403), .json(Examples.info))
        h.serveTailnet()
        h.serveEnroll(token: "TOKEN-X")
        // 짝 앱이 이미 다시 등록해 공용 보관소에 새 토큰을 넣어 두었다.
        var fresh = DirectHarness.credential
        fresh.token = "TOKEN-PAIRED"
        h.credentials.save(fresh)
        await h.model.restore()
        // 또 등록하지 않는다(등록하면 짝 앱의 토큰이 무효가 된다).
        #expect(h.tailnet.count("POST", "/v1/direct/enroll") == 0)
        await h.model.refresh()
        #expect(mac.requests.last?.value(forHTTPHeaderField: "Authorization") == "RD-Device d_1a2b3c4d.TOKEN-PAIRED")
    }

    @Test func freshTokenRejectedAgainDoesNotLoopEnrolling() async {
        let h = DirectHarness(tunnel: .connected)
        let mac = h.serveMac()
        // Mac이 방금 준 토큰도 받지 않는다(해시를 저장하지 못하는 Mac).
        mac.set("GET", "/v1/info", .error("not_paired", status: 403))
        h.serveTailnet()
        h.serveEnroll(token: "TOKEN-2")
        await h.model.restore()
        await h.model.refresh()
        await h.model.refresh()
        // 한 번만 다시 등록하고, 그 뒤로는 VPN 경로만 쓴다.
        #expect(h.tailnet.count("POST", "/v1/direct/enroll") == 1)
        #expect(h.model.refreshError == nil)
        #expect(h.model.builds.count == 1)
    }

    @Test func forgettingTheMacClearsTheCredential() async {
        let h = DirectHarness()
        h.serveMac()
        await h.model.restore()
        await h.model.forgetHost()
        #expect(h.credentials.load() == nil)
        #expect(!h.model.isDirectConnected)
    }

    // MARK: 설치와 VPN

    @Test func installAlwaysGoesThroughTheVPN() async throws {
        let h = DirectHarness()
        let mac = h.serveMac()
        await h.model.restore()
        #expect(h.model.isDirectConnected)
        #expect(h.tunnel.autoStartCount == 0)

        h.tailnet.on("POST", "/v1/builds/b_9f3a1c2e/sessions", .json(Examples.sessionCreated, status: 201))
        h.tailnet.on("GET", "/v1/sessions/s_52d9a07e", .json(try Examples.sessionStatus(.completed, served: 52_428_800)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()

        // 설치 세션과 진행 확인은 tailnet 이름으로, VPN을 자동으로 켠 뒤에 갔다.
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.tailnet.count("POST", "/v1/builds/b_9f3a1c2e/sessions") == 1)
        #expect(mac.requests.allSatisfy { $0.url?.path.contains("sessions") == false })
        #expect(h.opener.opened.first?.absoluteString.contains(hostFQDN.replacingOccurrences(of: ".", with: ".")) == true)
        #expect(h.opener.opened.first?.scheme == "itms-services")
    }

    @Test func logsGoDirectAndKeepTheVPNOff() async {
        let h = DirectHarness()
        let mac = h.serveMac()
        await h.model.restore()
        h.model.log(.info, "test", "hello")
        await h.model.sendLogs()
        #expect(mac.count("POST", "/v1/logs") >= 1)
        #expect(h.model.logSendError == nil)
        #expect(h.tunnel.autoStartCount == 0)
        #expect(h.model.canReachHost)
    }

    // MARK: 알림 등록 지우기

    /// 같은 Wi-Fi에서 등록한 뒤 직접 경로가 끊겼다: 알림 지우기는 이미 연결된 VPN으로 넘어간다.
    private func registeredDirectly() async -> (DirectHarness, InMemoryPushSettingsStore) {
        let store = InMemoryPushSettingsStore(enabled: true)
        let h = DirectHarness(tunnel: .connected, push: PushSetup(store: store, bundleId: phoneBundleID))
        let mac = h.serveMac()
        mac.on("PUT", "/v1/devices/self/push-token", .json(#"{"registered":true}"#))
        h.tailnet.on("DELETE", "/v1/devices/self/push-token", .json(#"{"registered":false}"#))
        await h.model.receivePushToken(fakePushToken)
        await h.model.restore()
        #expect(mac.count("PUT", "/v1/devices/self/push-token") == 1)
        #expect(store.record != nil)
        h.lan.remove(macAddress)
        return (h, store)
    }

    @Test func pushRemovalFallsBackToTheConnectedVPN() async {
        let (h, store) = await registeredDirectly()
        await h.model.setPushEnabled(false)
        #expect(h.tailnet.count("DELETE", "/v1/devices/self/push-token") == 1)
        #expect(store.record == nil)
        #expect(store.pendingRemoval == nil)
    }

    @Test func forgetHostRemovesPushOverTheConnectedVPN() async {
        let (h, store) = await registeredDirectly()
        await h.model.forgetHost()
        #expect(h.tailnet.count("DELETE", "/v1/devices/self/push-token") == 1)
        #expect(store.record == nil)
        #expect(h.model.host == nil)
    }

    @Test func statusTextNamesTheDirectPath() {
        #expect(VPNStatusText.direct == "직접 연결(같은 Wi-Fi, VPN 없이)")
    }
}
