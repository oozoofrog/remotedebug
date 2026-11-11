import Foundation
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

/// 설치 웹 페이지 주소(`https://<fqdn>/`, 코드를 넣으면 `#code=<코드>`).
extension HostModelTests {
    static let fqdn = "rd-mac-test.example.ts.net"

    func readyStatus(fqdn: String = HostModelTests.fqdn, tlsReady: Bool = true, listening: Bool = true, certificates: Bool = true) -> CoreStatus {
        CoreStatus(backendState: .running, hostname: "rd-mac-test", fqdn: fqdn,
                   certDomains: certificates ? [fqdn] : [], tlsReady: tlsReady, listening: listening)
    }

    /// 코어 `BaseURL`과 같은 규칙: TLS는 443이면 포트를 생략, 평문은 언제나 포트를 붙인다. 끝의 점은 뗀다.
    @Test func installPageURLFollowsTheCoreBaseURL() {
        func url(_ fqdn: String, tls: Bool, port: Int, code: String? = nil) -> String? {
            HostModel.installPageURL(fqdn: fqdn, tls: tls, port: port, code: code)?.absoluteString
        }
        #expect(url("h.example.ts.net", tls: true, port: 443) == "https://h.example.ts.net/")
        #expect(url("h.example.ts.net", tls: true, port: 443, code: "K7M29QXD") == "https://h.example.ts.net/#code=K7M29QXD")
        #expect(url("h.example.ts.net", tls: true, port: 8443) == "https://h.example.ts.net:8443/")
        #expect(url("h.example.ts.net", tls: false, port: 8080, code: "K7M29QXD") == "http://h.example.ts.net:8080/#code=K7M29QXD")
        #expect(url("h.example.ts.net", tls: false, port: 443) == "http://h.example.ts.net:443/")
        #expect(url("h.example.ts.net.", tls: true, port: 443) == "https://h.example.ts.net/")
        #expect(url("", tls: true, port: 443) == nil)
        #expect(url(".", tls: true, port: 443) == nil)
    }

    /// 페어링할 수 있을 때(공유 중·인증서·리스너·MagicDNS)만 주소가 있다. fqdn이 바뀌면 따라간다.
    @Test func installPageURLExistsOnlyWhilePairingIsAvailable() async throws {
        let h = try makeHarness("installpage")
        #expect(h.model.installPageURL == nil, "공유 전")
        await h.model.start()
        #expect(h.model.pairingAvailability == .ready)
        #expect(h.model.installPageURL?.absoluteString == "https://\(Self.fqdn)/")
        #expect(h.model.installPageLink == nil, "코드를 열기 전에는 코드 링크가 없다")

        h.model.handle(.state(readyStatus(tlsReady: false)))
        #expect(h.model.installPageURL == nil, "인증서 발급 중")
        h.model.handle(.state(readyStatus(certificates: false)))
        #expect(h.model.installPageURL == nil, "HTTPS 인증서 꺼짐")
        h.model.handle(.state(readyStatus(listening: false)))
        #expect(h.model.installPageURL == nil, "리스너가 아직 열리지 않음")
        h.model.handle(.state(readyStatus(fqdn: "")))
        #expect(h.model.installPageURL == nil, "MagicDNS 주소 없음")
        h.model.handle(.state(CoreStatus(backendState: .needsLogin, hostname: "rd-mac-test", fqdn: Self.fqdn)))
        #expect(h.model.installPageURL == nil, "로그인 필요")

        h.model.handle(.state(readyStatus(fqdn: "rd-mac-test-1.other.ts.net")))
        #expect(h.model.installPageURL?.absoluteString == "https://rd-mac-test-1.other.ts.net/")

        await h.model.stop()
        #expect(h.model.installPageURL == nil, "공유 중지")
    }

    /// 코드 링크는 지금 열린 코드로만 만든다. 쓰이거나 폐기되거나 만료되면 사라진다.
    @Test func installPageLinkCarriesOnlyTheOpenCode() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_900_000_000))
        let h = try makeHarness("installlink", clock: { clock.withLock { $0 } })
        let t0 = clock.withLock { $0 }
        h.core.state.withLock { $0.pairing = PairingCode(code: "K7M29QXD", expiresAt: t0.addingTimeInterval(300)) }
        await h.model.start()
        await h.model.beginPairing()
        let code = try #require(h.model.pairingCode)
        let link = "https://\(Self.fqdn)/#code=K7M29QXD"
        #expect(h.model.installPageLink?.absoluteString == link)
        #expect(h.model.installPageURL(code: code)?.absoluteString == link)
        #expect(h.model.installPageURL?.absoluteString == "https://\(Self.fqdn)/", "주소 줄에는 코드를 넣지 않는다")
        #expect(h.model.installPageURL(code: PairingCode(code: "AAAA1111", expiresAt: t0.addingTimeInterval(300))) == nil,
                "지금 열린 코드가 아니다")

        // 요청이 오면 코드는 쓰인 것이다.
        receive(h, pairRequest("pr_1", now: t0))
        #expect(h.model.installPageLink == nil)
        #expect(h.model.installPageURL(code: code) == nil)
        #expect(h.model.installPageURL != nil, "페이지 주소는 그대로")

        // 틀린 시도가 쌓여 코어가 폐기했다.
        await h.model.beginPairing()
        #expect(h.model.installPageLink?.absoluteString == link)
        h.model.handle(.denied(DeniedEvent(path: "/v1/pair/request", reason: "too_many_attempts", nodeName: "rd-phone-9")))
        #expect(h.model.installPageLink == nil)

        // 만료.
        await h.model.beginPairing()
        #expect(h.model.installPageLink != nil)
        clock.withLock { $0 = $0.addingTimeInterval(301) }
        #expect(h.model.installPageLink == nil)
        #expect(h.model.installPageURL(code: code) == nil)

        // 페어링할 수 없게 되면 코드가 열려 있어도 링크가 없다.
        clock.withLock { $0 = t0 }
        await h.model.beginPairing()
        h.model.handle(.state(readyStatus(tlsReady: false)))
        #expect(h.model.pairingCode != nil)
        #expect(h.model.installPageLink == nil)
        await h.model.stop()
    }

    /// 루프백 테스트 제어 서버면 코어가 평문으로 리스너 포트에서 서빙한다(E2E와 같은 설정).
    @Test func loopbackControlServerUsesPlainHTTPWithThePort() async throws {
        let h = try makeHarness("installloop", port: 8080)
        h.core.state.withLock { $0.status = readyStatus(tlsReady: false, certificates: false) }
        h.model.controlURL = "http://127.0.0.1:9999"
        await h.model.start()
        #expect(h.core.startConfigs.last?.listenTLS == false)
        #expect(h.model.pairingAvailability == .ready)
        #expect(h.model.installPageURL?.absoluteString == "http://\(Self.fqdn):8080/")
        await h.model.beginPairing()
        #expect(h.model.installPageLink?.absoluteString == "http://\(Self.fqdn):8080/#code=K7M29QXD")
        await h.model.stop()

        // 같은 모델을 TLS 설정으로 다시 시작하면 https로 바뀐다(포트 8080은 붙는다).
        h.model.controlURL = ""
        h.core.state.withLock { $0.status = readyStatus() }
        await h.model.start()
        #expect(h.model.installPageURL?.absoluteString == "https://\(Self.fqdn):8080/")
        await h.model.stop()
    }
}
