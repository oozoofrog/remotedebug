import Foundation
import RDModels
import Testing
@testable import RDHostLogic

@Suite("요청 출처와 사건 한도")
struct HardeningTests {
    @Test("iPhone 요청 헤더와 같은 출처 웹 요청 허용")
    func 허용한출처() async throws {
        let fixture = try HostFixture(direct: true)
        let code = try fixture.host.openPairing(ttlSeconds: 30)
        let phone = try await fixture.request("POST", "/v1/pair/request", body: jsonText(["code": code.code]),
            headers: [("accept", "application/json"), ("x-rd-client", "iOS/26.1"), ("content-type", "application/json")])
        #expect(phone.status == 202)
        let tailnet = [("origin", "https://rd-mac-1.example.ts.net"), ("sec-fetch-site", "same-origin"), ("content-type", "application/json; charset=utf-8")]
        let web = await fixture.request("POST", "/v1/logs", body: #"{"entries":[{"message":"x"}]}"#, headers: tailnet)
        #expect(web.status == 202)
        for method in ["POST", "DELETE"] {
            let path = method == "POST" ? "/v1/direct/enroll" : "/v1/devices/self/push-token"
            #expect(await fixture.request(method, path, headers: [("content-type", "")]).status == 200)
        }
        let credentials = auth(try await fixture.enroll())
        let direct = await fixture.request("POST", "/v1/logs", body: #"{"entries":[{"message":"x"}]}"#,
            headers: [("authorization", credentials), ("host", "192.0.2.10:49152"), ("origin", "https://192.0.2.10:49152"), ("sec-fetch-site", "same-origin")],
            origin: .direct(remoteIP: "192.0.2.1"))
        #expect(direct.status == 202)
    }

    @Test("본문은 JSON 매체 형식이어야 함")
    func 본문매체검증() async throws {
        let fixture = try HostFixture(direct: true)
        let credentials = auth(try await fixture.enroll())
        for origin in [HostOrigin.tailnet(HostFixture.peer), .direct(remoteIP: "192.0.2.1")] {
            for type in ["", "text/plain", "application/x-www-form-urlencoded", "application/json-extra"] {
                let response = await fixture.request("POST", "/v1/logs", body: "{}",
                    headers: [("content-type", type), ("authorization", credentials)], origin: origin)
                #expect(try response.status == 415 && (errorCode(response)) == "unsupported_media_type")
                #expect(header(response, "X-RD-Protocol") == "1")
            }
        }
        #expect(fixture.drain().filter { $0.type == "device-log" }.isEmpty)
    }

    @Test("모든 변경 메서드의 출처와 Fetch 메타데이터 검증")
    func 출처검증() async throws {
        let fixture = try HostFixture(direct: true)
        let credentials = auth(try await fixture.enroll())
        let paths = [("POST", "/v1/direct/enroll"), ("PUT", "/v1/devices/self/push-token"), ("DELETE", "/v1/devices/self/push-token")]
        for origin in [HostOrigin.tailnet(HostFixture.peer), .direct(remoteIP: "192.0.2.1")] {
            for (method, path) in paths {
                for supplied in [[("sec-fetch-site", "cross-site")], [("origin", "https://other.example")], [("origin", "null")]] {
                    let response = await fixture.request(method, path,
                        headers: supplied + [("authorization", credentials), ("host", "192.0.2.10:49152")], origin: origin)
                    #expect(try response.status == 403 && (errorCode(response)) == "origin_not_allowed")
                }
            }
        }
        let direct = await fixture.request("DELETE", "/v1/devices/self/push-token",
            headers: [("authorization", credentials), ("origin", "https://rd-mac-1.example.ts.net"), ("host", "192.0.2.10:49152")],
            origin: .direct(remoteIP: "192.0.2.1"))
        #expect(direct.status == 403)
        let missingHost = await fixture.request("DELETE", "/v1/devices/self/push-token",
            headers: [("authorization", credentials), ("origin", "https://192.0.2.10:49152")], origin: .direct(remoteIP: "192.0.2.1"))
        #expect(missingHost.status == 403)
        #expect(await fixture.request("GET", "/v1/info", headers: [("origin", "https://other.example"), ("sec-fetch-site", "cross-site")]).status == 200)
    }

    @Test("크래시는 받은 시각을 보존하고 미래 시각을 제한")
    func 크래시수신시각() async throws {
        let fixture = try HostFixture()
        let received = fixture.clock.now()
        for reported in [received.addingTimeInterval(3600), received.addingTimeInterval(-3600)] {
            let body = try jsonText(["kind": "ips", "text": "x", "crashedAt": RDTimestamp.string(reported)])
            #expect(await fixture.request("POST", "/v1/crashes", body: body).status == 202)
            let emitted = try #require(fixture.events.nextEvent())
            #expect(emitted.receivedAt == received)
            guard case .deviceCrash(let event) = emitted.event else { Issue.record("크래시 사건 없음"); return }
            #expect(event.report.crashedAt == min(reported, received))
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(emitted)) as? [String: Any]
            #expect((encoded?["receivedAt"] as? String).flatMap(RDTimestamp.parse) == received)
            #expect(encoded?["type"] as? String == "device-crash")
        }
    }

    @Test("페이로드 바이트 제한은 큰 로그와 크래시보다 페어링을 보존")
    func 바이트한도() throws {
        let queue = HostEventQueue(capacity: 256, byteCapacity: 4096)
        let pair = CoreEvent.pairRequest(.init(requestId: "pr_1", deviceName: "시험", nodeName: "rd-phone-1", loginName: "", expiresAt: Date(timeIntervalSince1970: 0)))
        queue.push(pair)
        for _ in 0..<20 { queue.push(.log(.init(level: "info", message: String(repeating: "x", count: 1000)))) }
        let report = CrashReport(kind: .ips, name: "App.ips", bundleId: "com.example.app", appVersion: "1", crashedAt: Date(timeIntervalSince1970: 0), text: String(repeating: "x", count: 3000))
        queue.push(.deviceCrash(.init(deviceId: "d_1", deviceName: "시험", nodeName: "rd-phone-1", report: report)))
        #expect(queue.bufferedPayloadBytes <= 4096)
        #expect(queue.next()?.type == "log")
        #expect(queue.next() == pair)
        while queue.next() != nil {}
        #expect(queue.bufferedPayloadBytes == 0)
        let small = HostEventQueue(capacity: 1, byteCapacity: 4096)
        small.push(pair)
        small.push(.deviceCrash(.init(deviceId: "d_1", deviceName: "시험", nodeName: "rd-phone-1", report: report)))
        #expect(small.next()?.type == "log")
        #expect(small.next() == pair)
        let oversized = HostEventQueue(byteCapacity: 100)
        oversized.push(.log(.init(level: "info", message: String(repeating: "x", count: 101))))
        #expect(oversized.bufferedPayloadBytes == 0)
        #expect(oversized.next()?.type == "log")
        #expect(oversized.next() == nil)
    }
}
