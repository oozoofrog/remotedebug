import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

// 다른 앱의 VPN(공식 Tailscale 앱 등)으로 보낸 요청을 Mac이 `not_paired`로 거절하면
// 그 노드를 기기 토큰으로 이 기기 항목에 묶고 한 번 다시 보낸다(docs/protocol-addenda.md S).

private let linkPath = "/v1/devices/self/nodes"
private let linked = #"{"deviceId":"d_1a2b3c4d","nodeName":"iphone-1"}"#

@MainActor
@Suite("다른 앱의 VPN 노드 묶기")
struct OtherVPNLinkTests {
    /// 셀룰러에서 다른 앱의 VPN이 켜져 있다. 직접 경로는 쓰지 않는다.
    func harness(enrolled: DirectCredential? = DirectHarness.credential, holder: VPNHolder = .other) -> DirectHarness {
        let h = DirectHarness(tunnel: .connected, enrolled: enrolled)
        h.network.isOnLocalNetwork = false
        h.tunnel.holder = holder
        h.serveTailnet()
        h.tailnet.set("GET", "/v1/info", .error("not_paired", status: 403), .json(Examples.info))
        return h
    }

    @Test func notPairedOverOtherVPNLinksTheNodeAndRetries() async {
        let h = harness()
        h.tailnet.set("POST", linkPath, .json(linked))
        await h.model.restore()

        #expect(h.model.refreshError == nil)
        #expect(h.model.builds.count == 1)
        #expect(h.tailnet.count("POST", linkPath) == 1)
        #expect(h.tailnet.count("GET", "/v1/info") == 2)
        // 기기 토큰은 묶기 요청에만, 페어링한 Mac의 tailnet 이름으로만 나간다.
        for request in h.tailnet.requests {
            #expect(request.url?.host == hostFQDN)
            let expected = request.url?.path == linkPath ? DirectHarness.authorization : nil
            #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        }
        #expect(h.tunnel.autoStartCount == 0)
    }

    @Test func withoutDeviceTokenShowsTheTakeOverGuidance() async {
        let h = harness(enrolled: nil)
        h.tailnet.set("GET", "/v1/info", .error("not_paired", status: 403))
        await h.model.restore()

        #expect(h.tailnet.count("POST", linkPath) == 0)
        let expected = HostAPIError(status: 403, code: HostAPIError.otherVPNUnlinkedCode, message: "").userMessage
        #expect(h.model.refreshError == expected)
        #expect(expected.contains("이 앱으로 VPN 가져오기"))
    }

    @Test func rejectedLinkShowsTheTakeOverGuidance() async {
        let h = harness()
        h.tailnet.set("POST", linkPath, .error("not_paired", status: 403))
        h.tailnet.set("GET", "/v1/info", .error("not_paired", status: 403))
        await h.model.restore()

        #expect(h.tailnet.count("POST", linkPath) == 1)
        #expect(h.model.refreshError == HostAPIError(status: 403, code: HostAPIError.otherVPNUnlinkedCode, message: "").userMessage)
    }

    @Test func otherTailscaleAccountIsExplained() async {
        let h = harness()
        h.tailnet.set("POST", linkPath, .error("node_login_mismatch", status: 403))
        h.tailnet.set("GET", "/v1/info", .error("not_paired", status: 403))
        await h.model.restore()

        #expect(h.model.refreshError == HostAPIError(status: 403, code: "node_login_mismatch", message: "").userMessage)
        #expect(h.model.refreshError?.contains("다른 Tailscale 계정") == true)
    }

    @Test func ownVPNNeverLinks() async {
        let h = harness(holder: .thisApp)
        h.tailnet.set("GET", "/v1/info", .error("not_paired", status: 403))
        h.tailnet.set("POST", linkPath, .json(linked))
        await h.model.restore()

        #expect(h.tailnet.count("POST", linkPath) == 0)
        #expect(h.model.refreshError == HostAPIError(status: 403, code: "not_paired", message: "").userMessage)
    }

    @Test func installSessionOverOtherVPNLinksAndRetries() async throws {
        let h = harness()
        h.tailnet.set("GET", "/v1/info", .json(Examples.info))
        await h.model.restore()
        #expect(h.model.builds.count == 1)

        let createPath = "/v1/builds/b_9f3a1c2e/sessions"
        h.tailnet.set("POST", createPath, .error("not_paired", status: 403), .json(Examples.sessionCreated, status: 201))
        h.tailnet.set("POST", linkPath, .json(linked))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()

        #expect(h.tailnet.count("POST", linkPath) == 1)
        #expect(h.tailnet.count("POST", createPath) == 2)
        #expect(!h.opener.opened.isEmpty)
    }
}
