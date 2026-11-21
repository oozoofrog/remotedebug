import Foundation
import RDModels
import Testing
@testable import RDHostLogic

/// docs/protocol-addenda.md S: 같은 iPhone의 다른 tailnet 노드(공식 Tailscale 앱 등)를 기기 항목에 묶는다.
@Suite("다른 앱의 VPN 노드 묶기")
struct NodeLinkTests {
    static let login = "user@example.com"
    /// RemoteDebug 앱의 노드(허용 목록에 있는 기기).
    static let phone = HostPeer(stableID: "n_phone", nodeName: "rd-phone-00000001", loginName: login)
    /// 같은 iPhone의 공식 Tailscale 앱 노드.
    static let other = HostPeer(stableID: "n_other", nodeName: "iphone-1", loginName: login)
    static let path = "/v1/devices/self/nodes"

    /// 허용 목록에 `phone` 하나를 두고 직접 연결에 등록해 기기 토큰을 받는다.
    func enrolled() async throws -> (HostFixture, DirectEnrollment) {
        let fixture = try HostFixture(paired: false, direct: true)
        try fixture.host.setDevices([DeviceEntry(id: "d_1", name: "시험 iPhone", nodeStableId: Self.phone.stableID, nodeName: Self.phone.nodeName,
                                                 loginName: Self.login, pairedAt: fixture.clock.now())])
        let enrollment: DirectEnrollment = try decode(await fixture.request("POST", "/v1/direct/enroll", origin: .tailnet(Self.phone)))
        _ = fixture.drain()
        return (fixture, enrollment)
    }

    func link(_ fixture: HostFixture, _ authorization: String?, from peer: HostPeer = other) async -> HostResponse {
        await fixture.request("POST", Self.path, headers: authorization.map { [("authorization", $0)] } ?? [], origin: .tailnet(peer))
    }

    @Test("묶기 전에는 거절하고 묶은 뒤에는 원래 기기로 처리")
    func 묶기와처리() async throws {
        let (fixture, enrollment) = try await enrolled()
        let before = await fixture.request("GET", "/v1/builds", origin: .tailnet(Self.other))
        #expect(try before.status == 403 && errorCode(before) == "not_paired")

        let response = await link(fixture, auth(enrollment))
        #expect(response.status == 200)
        #expect(header(response, "Cache-Control") == "no-store")
        let linked: NodeLinkResponse = try decode(response)
        #expect(linked == NodeLinkResponse(deviceId: "d_1", nodeName: Self.other.nodeName))
        let device = try #require(fixture.host.locked { fixture.host.devices[Self.phone.stableID] })
        #expect(device.linkedNodes.map(\.nodeStableId) == [Self.other.stableID])
        #expect(device.linkedNodes.first?.loginName == Self.login)

        let events = fixture.drain()
        #expect(events.contains { if case .deviceUpdated(let d) = $0 { return d.linkedNodes.map(\.nodeStableId) == [Self.other.stableID] }; return false })
        for event in events {
            #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains(enrollment.token))
        }

        #expect(await fixture.request("GET", "/v1/builds", origin: .tailnet(Self.other)).status == 200)
        // 다시 묶어도 같은 결과이고 사건을 다시 내지 않는다.
        #expect(await link(fixture, auth(enrollment)).status == 200)
        #expect(!fixture.drain().contains { if case .deviceUpdated = $0 { return true }; return false })
    }

    @Test("토큰이 없거나 틀리면 묶지 않고 10번 틀리면 1분 동안 429")
    func 토큰검증() async throws {
        let (fixture, enrollment) = try await enrolled()
        let missing = await link(fixture, nil)
        #expect(try missing.status == 403 && errorCode(missing) == "not_paired")
        let other = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        for value in ["RD-Device d_1." + other, "RD-Device d_other." + enrollment.token, "Bearer d_1." + enrollment.token] {
            let response = await link(fixture, value)
            #expect(try response.status == 403 && errorCode(response) == "not_paired")
        }
        #expect(fixture.drain().contains { if case .denied(let d) = $0 { return d.path == Self.path && d.reason == "not_paired" }; return false })
        #expect(await fixture.request("GET", "/v1/builds", origin: .tailnet(Self.other)).status == 403)
        for _ in 0..<6 { _ = await link(fixture, "RD-Device d_1." + other) }
        let blocked = await link(fixture, auth(enrollment))
        #expect(try blocked.status == 429 && errorCode(blocked) == "too_many_attempts")
        // 다른 노드의 시도는 막히지 않는다.
        let stranger = HostPeer(stableID: "n_stranger", nodeName: "stranger", loginName: Self.login)
        #expect(await link(fixture, "RD-Device d_1." + other, from: stranger).status == 403)
        fixture.clock.advance(61)
        #expect(await link(fixture, auth(enrollment)).status == 200)
    }

    @Test("다른 로그인 계정이나 계정 없는 노드는 묶지 않음")
    func 로그인계정() async throws {
        let (fixture, enrollment) = try await enrolled()
        for login in ["someone@example.org", ""] {
            let peer = HostPeer(stableID: "n_foreign", nodeName: "foreign", loginName: login)
            let response = await link(fixture, auth(enrollment), from: peer)
            #expect(try response.status == 403 && errorCode(response) == "node_login_mismatch")
            #expect(await fixture.request("GET", "/v1/builds", origin: .tailnet(peer)).status == 403)
        }
        #expect(fixture.host.locked { fixture.host.devices[Self.phone.stableID]?.linkedNodes.isEmpty } == true)
    }

    @Test("허용 목록에 있는 노드는 묶을 것이 없음")
    func 이미허용() async throws {
        let (fixture, enrollment) = try await enrolled()
        let response = await link(fixture, auth(enrollment), from: Self.phone)
        #expect(try response.status == 200 && decode(response, as: NodeLinkResponse.self).deviceId == "d_1")
        #expect(fixture.host.locked { fixture.host.devices[Self.phone.stableID]?.linkedNodes.isEmpty } == true)
    }

    @Test("직접 연결 리스너에는 묶기 경로가 없음")
    func 직접연결() async throws {
        let (fixture, enrollment) = try await enrolled()
        let origin = HostOrigin.direct(remoteIP: "192.0.2.1")
        let response = await fixture.request("POST", Self.path, headers: [("authorization", auth(enrollment))], origin: origin)
        #expect(try response.status == 404 && errorCode(response) == "not_found")
        #expect(await fixture.request("POST", Self.path, origin: origin).status == 403)
    }

    @Test("묶은 노드로 설치 세션을 만들고 설치 파일을 받음")
    func 설치() async throws {
        let (fixture, enrollment) = try await enrolled()
        #expect(await link(fixture, auth(enrollment)).status == 200)
        let id = try fixture.host.publish(try fixture.writeBuild())
        let session: SessionResponse = try decode(await fixture.request("POST", "/v1/builds/" + id + "/sessions", origin: .tailnet(Self.other)))
        let manifest = try #require(URLComponents(url: session.manifestUrl, resolvingAgainstBaseURL: false)?.path)
        #expect(await fixture.request("GET", manifest, origin: .tailnet(Self.other)).status == 200)
        #expect(await fixture.request("GET", manifest.replacingOccurrences(of: "manifest.plist", with: "app.ipa"), origin: .tailnet(Self.other)).status == 200)
        // 세션은 기기 항목의 신원으로 만들어진다. 묶지 않은 노드는 받을 수 없다.
        let stranger = HostPeer(stableID: "n_stranger", nodeName: "stranger", loginName: Self.login)
        #expect(await fixture.request("GET", manifest, origin: .tailnet(stranger)).status == 403)
    }

    @Test("허용 목록을 다시 넣어도 묶인 노드가 남고 기기를 빼면 함께 빠짐")
    func 목록교체() async throws {
        let (fixture, enrollment) = try await enrolled()
        #expect(await link(fixture, auth(enrollment)).status == 200)
        let stored = try #require(fixture.host.locked { fixture.host.devices[Self.phone.stableID] })
        let saved = try JSONDecoder().decode(DeviceEntry.self, from: try JSONEncoder().encode(stored))
        #expect(saved == stored)
        try fixture.host.setDevices([saved])
        #expect(await fixture.request("GET", "/v1/builds", origin: .tailnet(Self.other)).status == 200)
        try fixture.host.setDevices([])
        #expect(await fixture.request("GET", "/v1/builds", origin: .tailnet(Self.other)).status == 403)
    }

    @Test("묶은 노드를 따로 페어링하면 원래 기기에서 빠짐")
    func 따로페어링() async throws {
        let (fixture, enrollment) = try await enrolled()
        #expect(await link(fixture, auth(enrollment)).status == 200)
        _ = fixture.drain()
        let code = try fixture.host.openPairing(ttlSeconds: 0)
        let body = try jsonText(["code": code.code, "deviceName": "다른 기기"])
        let request = await fixture.request("POST", "/v1/pair/request", body: body, origin: .tailnet(Self.other))
        let state: PairRequestState = try decode(request)
        let device = try #require(try fixture.host.decidePairing(requestID: state.requestId, allow: true))
        #expect(device.nodeStableId == Self.other.stableID && device.id != "d_1")
        #expect(fixture.host.locked { fixture.host.devices[Self.phone.stableID]?.linkedNodes.isEmpty } == true)
        #expect(fixture.drain().contains { if case .deviceUpdated(let d) = $0 { return d.id == "d_1" && d.linkedNodes.isEmpty }; return false })
        // 이제 그 노드는 따로 허용된 기기다. 원래 기기의 토큰으로 묶지 않는다.
        let again: NodeLinkResponse = try decode(await link(fixture, auth(enrollment)))
        #expect(again.deviceId == device.id)
    }

    @Test("기기 하나에 노드를 4개까지 두고 오래된 것부터 뺌")
    func 개수제한() async throws {
        let (fixture, enrollment) = try await enrolled()
        for index in 1...5 {
            fixture.clock.advance(1)
            let peer = HostPeer(stableID: "n_other\(index)", nodeName: "iphone-\(index)", loginName: Self.login)
            #expect(await link(fixture, auth(enrollment), from: peer).status == 200)
        }
        let nodes = fixture.host.locked { fixture.host.devices[Self.phone.stableID]?.linkedNodes.map(\.nodeStableId) }
        #expect(nodes == ["n_other2", "n_other3", "n_other4", "n_other5"])
        let first = HostPeer(stableID: "n_other1", nodeName: "iphone-1", loginName: Self.login)
        #expect(await fixture.request("GET", "/v1/builds", origin: .tailnet(first)).status == 403)
    }

    @Test("기기 목록 JSON과 사건 JSON이 묶인 노드를 그대로 옮김")
    func JSON왕복() async throws {
        let (fixture, enrollment) = try await enrolled()
        #expect(await link(fixture, auth(enrollment)).status == 200)
        let stored = try #require(fixture.host.locked { fixture.host.devices[Self.phone.stableID] })
        let event = HostLogic.EmittedEvent(event: .deviceUpdated(stored))
        let decoded = try JSONDecoder().decode(HostLogic.EmittedEvent.self, from: try JSONEncoder().encode(event))
        guard case .deviceUpdated(let device) = decoded.event else { Issue.record("device-updated가 아님"); return }
        #expect(device.linkedNodes == stored.linkedNodes)

        try fixture.host.setDevices([])
        let list = try JSONEncoder().encode(DeviceList(devices: [stored]))
        try fixture.host.setDevices(json: list)
        #expect(await fixture.request("GET", "/v1/builds", origin: .tailnet(Self.other)).status == 200)
        expectError("bad_request") {
            try fixture.host.setDevices(json: Data(#"{"devices":[{"id":"d_1","nodeStableId":"n_phone","linkedNodes":{}}]}"#.utf8))
        }
    }
}
