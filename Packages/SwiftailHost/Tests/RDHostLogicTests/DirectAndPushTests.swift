import Foundation
import RDModels
import Testing
@testable import RDHostLogic

@Suite("직접 연결 인증")
struct DirectTests {
    @Test("등록은 리스너 정보와 토큰을 돌려주고 해시만 저장")
    func 등록과해시() async throws {
        let fixture = try HostFixture(direct: true)
        let enrollment = try await fixture.enroll()
        #expect(enrollment.directId == "0123456789abcdef" && enrollment.port == 49152)
        #expect(enrollment.tlsSPKI == "c3BraQ==" && enrollment.deviceId == "d_1")
        let hash = HostIDs.directTokenHash(enrollment.token)
        #expect(hash.count == 64)
        let device = try #require(fixture.host.locked { fixture.host.devices[HostFixture.peer.stableID] })
        #expect(device.directTokenHash == hash)
        let events = fixture.drain()
        #expect(events.contains { if case .deviceUpdated(let d) = $0 { return d.directTokenHash == hash }; return false })
        for event in events {
            #expect(!String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains(enrollment.token))
        }
    }

    @Test("등록에는 페어링과 실행 중인 리스너 필요")
    func 등록인증() async throws {
        let unpaired = try HostFixture(paired: false, direct: true)
        let denied = await unpaired.request("POST", "/v1/direct/enroll")
        #expect(try denied.status == 403 && (errorCode(denied)) == "not_paired")
        let off = try HostFixture()
        let response = await off.request("POST", "/v1/direct/enroll")
        #expect(try response.status == 404 && (errorCode(response)) == "direct_off")
    }

    @Test("없는 토큰 틀린 토큰 회전과 철회")
    func 토큰검증() async throws {
        let fixture = try HostFixture(direct: true)
        let enrollment = try await fixture.enroll()
        let good = auth(enrollment)
        let origin = HostOrigin.direct(remoteIP: "192.0.2.1")
        #expect(await fixture.request("GET", "/v1/info", headers: [("authorization", good)], origin: origin).status == 200)
        let other = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        for value in ["", "RD-Device d_1." + other, "RD-Device d_other." + enrollment.token,
                      "Bearer d_1." + enrollment.token, "RD-Device " + enrollment.token, "RD-Device d_1.abc"] {
            let response = await fixture.request("GET", "/v1/info", headers: [("authorization", value)], origin: origin)
            #expect(try response.status == 403 && (errorCode(response)) == "not_paired")
            #expect(header(response, "X-RD-Protocol") == "1")
        }
        #expect(fixture.drain().contains { if case .denied(let d) = $0 { return d.path == "/v1/info" && d.reason == "not_paired" }; return false })
        let rotated = try await fixture.enroll()
        #expect(rotated.token != enrollment.token)
        #expect(await fixture.request("GET", "/v1/info", headers: [("authorization", good)], origin: origin).status == 403)
        #expect(await fixture.request("GET", "/v1/info", headers: [("authorization", auth(rotated))], origin: origin).status == 200)
        try fixture.host.setDevices([])
        #expect(await fixture.request("GET", "/v1/info", headers: [("authorization", auth(rotated))], origin: origin).status == 403)
        try fixture.host.setDevices([fixture.device()])
        #expect(await fixture.request("GET", "/v1/info", headers: [("authorization", "RD-Device d_1.")], origin: origin).status == 403)
    }

    @Test("직접 리스너는 기기용 경로만 제공하고 인증 먼저")
    func 경로제한() async throws {
        let fixture = try HostFixture(direct: true)
        let credentials = auth(try await fixture.enroll())
        let paths = [("GET", "/"), ("GET", "/assets/app.js"), ("POST", "/v1/pair/request"), ("GET", "/v1/pair/request/pr_1"),
                     ("POST", "/v1/direct/enroll"), ("POST", "/v1/builds/b_1/sessions"), ("GET", "/v1/sessions/s_1"),
                     ("GET", "/i/TOKEN/manifest.plist"), ("GET", "/i/TOKEN/app.ipa")]
        let origin = HostOrigin.direct(remoteIP: "192.0.2.1")
        for (method, path) in paths {
            let response = await fixture.request(method, path, headers: [("authorization", credentials)], origin: origin)
            #expect(try response.status == 404 && (errorCode(response)) == "not_found")
            #expect(await fixture.request(method, path, origin: origin).status == 403)
        }
        for path in ["/v1/info", "/v1/builds", "/v1/resources", "/v1/agent"] {
            #expect(await fixture.request("GET", path, headers: [("authorization", credentials)], origin: origin).status == 200)
        }
        #expect(await fixture.request("POST", "/v1/info", headers: [("authorization", credentials)], origin: origin).status == 405)
    }

    @Test("로그는 인증한 기기의 허용 목록 정보를 사용")
    func 기기신원() async throws {
        let fixture = try HostFixture(direct: true)
        let credentials = auth(try await fixture.enroll())
        _ = fixture.drain()
        let body = #"{"entries":[{"at":"2026-11-11T09:00:00Z","level":"info","source":"app","message":"hello"}]}"#
        let response = await fixture.request("POST", "/v1/logs", body: body, headers: [("authorization", credentials)], origin: .direct(remoteIP: "192.0.2.1"))
        #expect(response.status == 202)
        guard case .deviceLog(let event) = fixture.events.next() else { Issue.record("로그 사건이 없습니다"); return }
        #expect(event.deviceId == "d_1" && event.deviceName == "시험 iPhone" && event.nodeName == HostFixture.peer.nodeName)
    }

    @Test("주소마다 열 번 실패하면 일 분까지 올바른 토큰도 차단")
    func 실패차단() async throws {
        let fixture = try HostFixture(direct: true)
        let credentials = auth(try await fixture.enroll())
        let origin = HostOrigin.direct(remoteIP: "192.0.2.1")
        for _ in 0..<10 { #expect(await fixture.request("GET", "/v1/info", origin: origin).status == 403) }
        let blocked = await fixture.request("GET", "/v1/info", headers: [("authorization", credentials)], origin: origin)
        #expect(try blocked.status == 429 && (errorCode(blocked)) == "too_many_attempts")
        #expect(await fixture.request("GET", "/v1/info", headers: [("authorization", credentials)], origin: .direct(remoteIP: "192.0.2.2")).status == 200)
        fixture.clock.advance(60)
        #expect(await fixture.request("GET", "/v1/info", headers: [("authorization", credentials)], origin: origin).status == 200)
    }

    @Test("tailnet에서는 직접 연결 토큰을 무시")
    func tailnet신원() async throws {
        let fixture = try HostFixture(direct: true)
        let credentials = auth(try await fixture.enroll())
        let unknown = HostPeer(stableID: "", nodeName: "", loginName: "")
        #expect(await fixture.request("GET", "/v1/info", headers: [("authorization", credentials)], origin: .tailnet(unknown)).status == 403)
    }

    @Test("직접 연결 파일 받기를 요청 단위로 검증")
    func 파일통합() async throws {
        let fixture = try HostFixture(direct: true)
        let id = try fixture.host.publishResource(fixture.writeResource("notes.txt", "direct bytes"))
        let credentials = auth(try await fixture.enroll())
        let response = await fixture.request("GET", "/v1/resources/" + id, headers: [("authorization", credentials)], origin: .direct(remoteIP: "192.0.2.1"))
        #expect(try response.status == 200 && (responseData(response)) == Data("direct bytes".utf8))
    }
}

@Suite("기기 푸시 토큰")
struct PushTests {
    static let token = String(repeating: "0123abcd", count: 8)
    func body(_ token: String = Self.token, bundle: String = "com.example.phone", environment: String = "development") throws -> String {
        try jsonText(["token": token, "bundleId": bundle, "environment": environment])
    }

    @Test("등록 소문자화 중복 생략과 멱등 삭제")
    func 등록과삭제() async throws {
        let fixture = try HostFixture()
        let path = "/v1/devices/self/push-token"
        let response = try await fixture.request("PUT", path, body: body(Self.token.uppercased()))
        #expect(response.status == 200)
        #expect(fixture.host.locked { fixture.host.devices[HostFixture.peer.stableID]?.push?.token } == Self.token)
        let events = fixture.drain()
        #expect(events.count == 1 && events[0].type == "device-updated")
        #expect(String(decoding: try JSONEncoder().encode(events[0]), as: UTF8.self).contains(Self.token))
        #expect(try await fixture.request("PUT", path, body: body()).status == 200)
        #expect(fixture.drain().isEmpty)
        let deleted = await fixture.request("DELETE", path)
        #expect(deleted.status == 200)
        #expect(fixture.host.locked { fixture.host.devices[HostFixture.peer.stableID]?.push } == nil)
        #expect(fixture.drain().count == 1)
        #expect(await fixture.request("DELETE", path).status == 200)
        #expect(fixture.drain().isEmpty)
    }

    @Test("토큰 본문 검증 실패는 상태를 바꾸지 않음")
    func 잘못된본문() async throws {
        let fixture = try HostFixture()
        let cases = try [body(String(repeating: "zz", count: 32)), body(Self.token + "a"), body(String(repeating: "ab", count: 31)),
                         body(String(repeating: "ab", count: 257)), body(bundle: ""), body(bundle: "com/evil"), body(environment: "production"),
                         "nope", body() + "garbage", body(bundle: String(repeating: "a", count: 5000))]
        for body in cases {
            let response = await fixture.request("PUT", "/v1/devices/self/push-token", body: body)
            #expect(try response.status == 400 && (errorCode(response)) == "bad_request")
        }
        #expect(fixture.host.locked { fixture.host.devices[HostFixture.peer.stableID]?.push } == nil)
        #expect(fixture.drain().isEmpty)
    }

    @Test("등록과 삭제 모두 페어링 필요")
    func 인증() async throws {
        let fixture = try HostFixture(paired: false)
        for method in ["PUT", "DELETE"] {
            let response = try await fixture.request(method, "/v1/devices/self/push-token", body: body())
            #expect(try response.status == 403 && (errorCode(response)) == "not_paired")
        }
    }

    @Test("직접 연결에서도 등록과 삭제 가능")
    func 직접연결() async throws {
        let fixture = try HostFixture(direct: true)
        let credentials = auth(try await fixture.enroll())
        _ = fixture.drain()
        for method in ["PUT", "DELETE"] {
            let response = try await fixture.request(method, "/v1/devices/self/push-token", body: body(), headers: [("authorization", credentials)], origin: .direct(remoteIP: "192.0.2.1"))
            #expect(response.status == 200 && fixture.drain().count == 1)
        }
        #expect(try await fixture.request("PUT", "/v1/devices/self/push-token", body: body(), origin: .direct(remoteIP: "192.0.2.1")).status == 403)
    }

    @Test("목록 복원은 푸시를 보존하고 기기 제거는 함께 삭제")
    func 목록복원() throws {
        let fixture = try HostFixture(paired: false)
        let registration = PushRegistration(token: Self.token, bundleId: "com.example.phone", environment: "development")
        try fixture.host.setDevices([fixture.device(push: registration)])
        #expect(fixture.host.locked { fixture.host.devices[HostFixture.peer.stableID]?.push } == registration)
        let other = fixture.device(id: "d_2", stableID: "n_other")
        try fixture.host.setDevices([other])
        #expect(!fixture.host.deviceStableIDs().contains(HostFixture.peer.stableID))
        #expect(!String(decoding: try JSONEncoder().encode(other), as: UTF8.self).contains("push"))
    }
}
