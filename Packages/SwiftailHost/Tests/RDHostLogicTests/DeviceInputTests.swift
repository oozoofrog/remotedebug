import Foundation
import RDModels
import Testing
@testable import RDHostLogic

@Suite("에이전트 요청")
struct AgentTests {
    @Test("기본 상태는 꺼짐")
    func 기본상태() async throws {
        let fixture = try HostFixture()
        let board = await fixture.request("/v1/agent")
        #expect(board.status == 200)
        #expect(String(decoding: try responseData(board), as: UTF8.self).contains(#""enabled":false"#))
        let response = await fixture.request("POST", "/v1/agent/requests", body: #"{"text":"hi"}"#)
        #expect(try response.status == 403 && (errorCode(response)) == "agent_disabled")
    }
    @Test("모든 에이전트 경로는 페어링 필요")
    func 인증() async throws {
        let fixture = try HostFixture(paired: false)
        try fixture.host.setAgentBoard(Data(#"{"enabled":true}"#.utf8))
        for (method, path) in [("GET", "/v1/agent"), ("POST", "/v1/agent/requests"), ("POST", "/v1/agent/requests/a_1/cancel")] {
            let response = await fixture.request(method, path, body: #"{"text":"hi"}"#)
            #expect(try response.status == 403 && (errorCode(response)) == "not_paired")
        }
    }
    @Test("상태는 원문 보존하고 요청과 취소는 사건으로 전달")
    func 요청과취소() async throws {
        let fixture = try HostFixture()
        let board = #"{"enabled":true,"projects":[{"id":"p1","name":"App"}],"agents":["claude"],"requests":[]}"#
        try fixture.host.setAgentBoard(Data(board.utf8))
        #expect(try responseData(await fixture.request("/v1/agent")) == Data(board.utf8))
        let response = await fixture.request("POST", "/v1/agent/requests", body: #"{"text":"  테스트를 고쳐줘 ","project":"p1","agent":"claude"}"#)
        #expect(response.status == 202)
        let result = try JSONSerialization.jsonObject(with: responseData(response)) as? [String: String]
        let id = try #require(result?["id"])
        #expect(id.hasPrefix("a_"))
        guard case .agentRequest(let event) = fixture.events.next() else { Issue.record("요청 사건 없음"); return }
        #expect(event.requestId == id && event.text == "테스트를 고쳐줘" && event.project == "p1" && event.deviceId == "d_1")
        let cancel = await fixture.request("POST", "/v1/agent/requests/" + id + "/cancel")
        #expect(cancel.status == 202)
        guard case .agentCancel(let event) = fixture.events.next() else { Issue.record("취소 사건 없음"); return }
        #expect(event.requestId == id)
    }
    @Test("입력과 상태 문서 크기 및 자료형 검증")
    func 입력검증() async throws {
        let fixture = try HostFixture()
        try fixture.host.setAgentBoard(Data(#"{"enabled":true}"#.utf8))
        let cases = try [#"{"text":"   "}"#, "not json", jsonText(["text": String(repeating: "a", count: (16 << 10) + 1)]),
                         jsonText(["text": "hi", "project": String(repeating: "p", count: 200)]), #"{"text":4}"#,
                         jsonText(["text": "hi", "agent": String(repeating: "a", count: 129)]),
                         jsonText(["text": "hi", "continues": String(repeating: "a", count: 129)])]
        for body in cases { #expect(await fixture.request("POST", "/v1/agent/requests", body: body).status == 400) }
        for bad in ["nope", #"{"enabled":"yes"}"#, "[]", String(repeating: " ", count: (2 << 20) + 1)] {
            expectError("bad_request") { try fixture.host.setAgentBoard(Data(bad.utf8)) }
        }
        let unchanged = await fixture.request("/v1/agent")
        #expect(try responseData(unchanged) == Data(#"{"enabled":true}"#.utf8))
    }
}

@Suite("크래시 기록")
struct CrashTests {
    @Test("페어링 필요")
    func 인증() async throws {
        let fixture = try HostFixture(paired: false)
        let response = await fixture.request("POST", "/v1/crashes", body: #"{"kind":"ips","text":"x"}"#)
        #expect(try response.status == 403 && (errorCode(response)) == "not_paired")
    }
    @Test("크래시 본문 종류 내용과 사진 검증")
    func 본문검증() async throws {
        let fixture = try HostFixture()
        let invalid = try [#"{"kind":"other","text":"x"}"#, #"{"kind":"ips","text":"  "}"#,
                           jsonText(["kind": "ips", "text": String(repeating: "x", count: (1536 << 10) + 1)]), "not json",
                           #"{"kind":"feedback","text":"x","image":"not base64!"}"#, #"{"kind":"ips","text":"x","image":"aGVsbG8="}"#]
        for body in invalid { #expect(await fixture.request("POST", "/v1/crashes", body: body).status == 400) }
        let valid = [#"{"kind":"ips","name":"App.ips","bundleId":"com.example.app","crashedAt":"soon","text":"{\"bug_type\":\"309\"}"}"#,
                     #"{"kind":"feedback","bundleId":"com.example.app","text":"버튼이 눌리지 않아요"}"#,
                     #"{"kind":"feedback","text":"화면이 깨져요","image":"aGVsbG8="}"#]
        for body in valid {
            let response = await fixture.request("POST", "/v1/crashes", body: body)
            #expect(response.status == 202)
            #expect(String(decoding: try responseData(response), as: UTF8.self).contains(#""accepted":1"#))
        }
        let events = fixture.drain()
        #expect(events.count == 3)
        guard case .deviceCrash(let first) = events[0], case .deviceCrash(let last) = events[2] else { Issue.record("크래시 사건 없음"); return }
        #expect(first.report.crashedAt == fixture.clock.now())
        #expect(first.report.name == "App.ips" && first.deviceId == "d_1")
        #expect(last.report.image == Data("hello".utf8))
    }
    @Test("사진 한도와 UTF-8 필드 잘라내기")
    func 사진과문자열() async throws {
        let fixture = try HostFixture()
        let tooLarge = try jsonText(["kind": "feedback", "text": "x", "image": Data(repeating: 1, count: (1 << 20) + 1).base64EncodedString()])
        #expect(await fixture.request("POST", "/v1/crashes", body: tooLarge).status == 400)
        let text = String(repeating: "한", count: 100)
        let body = try jsonText(["kind": "metrickit", "text": "x", "name": text, "bundleId": text, "appVersion": text])
        #expect(await fixture.request("POST", "/v1/crashes", body: body).status == 202)
        guard case .deviceCrash(let event) = fixture.events.next() else { Issue.record("크래시 사건 없음"); return }
        #expect(event.report.name.utf8.count == 198 && event.report.bundleId.utf8.count == 198 && event.report.appVersion.utf8.count == 198)
    }
}

@Suite("기기 로그")
struct LogTests {
    @Test("기본값 시각 정규화와 UTF-8 자르기")
    func 정리() async throws {
        let fixture = try HostFixture()
        let body = try jsonText(["entries": [["at": "bad", "level": "unknown", "source": String(repeating: "한", count: 20), "message": String(repeating: "글", count: 1500)],
                                                  ["at": "2026-11-11T18:00:00.250+09:00", "level": "warning", "source": "app", "message": "hello"]]])
        #expect(await fixture.request("POST", "/v1/logs", body: body, chunkSize: 7).status == 202)
        guard case .deviceLog(let event) = fixture.events.next() else { Issue.record("로그 사건 없음"); return }
        #expect(event.deviceId == "d_1" && event.nodeName == HostFixture.peer.nodeName)
        #expect(event.entries.count == 2 && event.entries[0].level == .info)
        #expect(event.entries[0].at == fixture.clock.now())
        #expect(event.entries[0].source.utf8.count == 39 && event.entries[0].message.utf8.count == 4095)
        #expect(event.entries[1].at == RDTimestamp.parse("2026-11-11T09:00:00.250Z"))
    }
    @Test("배열 본문 한도와 인증")
    func 검증() async throws {
        let fixture = try HostFixture()
        for body in [#"{"entries":[]}"#, #"{"entries":null}"#, #"{"entries":4}"#, "invalid", String(repeating: " ", count: (128 << 10) + 1)] {
            #expect(await fixture.request("POST", "/v1/logs", body: body).status == 400)
        }
        let body = try jsonText(["entries": Array(repeating: ["message": "x"], count: 201)])
        #expect(await fixture.request("POST", "/v1/logs", body: body).status == 400)
        try fixture.host.setDevices([])
        #expect(await fixture.request("POST", "/v1/logs", body: "{}").status == 403)
    }
}
