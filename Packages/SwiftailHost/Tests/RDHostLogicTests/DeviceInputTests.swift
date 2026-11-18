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
    @Test("첨부: 새 모양을 받고 이름을 고친다")
    func 첨부() async throws {
        let fixture = try HostFixture()
        let body = try jsonText(["kind": "feedback", "text": "첨부가 있어요", "attachments": [
            ["name": "../../photo-1.jpg", "type": "image/jpeg", "base64": Data("jpeg".utf8).base64EncodedString()],
            ["name": "", "base64": Data("raw".utf8).base64EncodedString()],
        ]])
        #expect(await fixture.request("POST", "/v1/crashes", body: body).status == 202)
        guard case .deviceCrash(let event) = fixture.events.next() else { Issue.record("크래시 사건 없음"); return }
        #expect(event.report.attachments.map(\.name) == ["photo-1.jpg", "attachment"])
        #expect(event.report.attachments.map(\.type) == ["image/jpeg", "application/octet-stream"])
        #expect(event.report.attachments.first?.data == Data("jpeg".utf8) && event.report.image == nil)
        // 옛 클라이언트의 `image`와 함께 와도 받는다.
        let both = try jsonText(["kind": "feedback", "text": "둘 다", "image": "aGVsbG8=",
                                 "attachments": [["name": "a.txt", "base64": "aGVsbG8="]]])
        #expect(await fixture.request("POST", "/v1/crashes", body: both).status == 202)
    }
    @Test("첨부 한도: 수, 하나의 크기, 합계, 종류")
    func 첨부한도() async throws {
        let fixture = try HostFixture()
        func attachment(_ bytes: Int) -> [String: Any] { ["name": "f.bin", "base64": Data(repeating: 1, count: bytes).base64EncodedString()] }
        let invalid = try [
            jsonText(["kind": "feedback", "text": "x", "attachments": Array(repeating: attachment(1), count: CrashReport.maxAttachments + 1)]),
            jsonText(["kind": "feedback", "text": "x", "attachments": [attachment(CrashReport.maxAttachmentBytes + 1)]]),
            jsonText(["kind": "feedback", "text": "x", "attachments": [attachment(CrashReport.maxAttachmentBytes), attachment(CrashReport.maxAttachmentBytes)]]),
            jsonText(["kind": "feedback", "text": "x", "attachments": [["name": "a", "base64": "not base64!"]]]),
            jsonText(["kind": "feedback", "text": "x", "attachments": [["name": "a", "base64": ""]]]),
            jsonText(["kind": "feedback", "text": "x", "attachments": "nope"]),
            jsonText(["kind": "ips", "text": "x", "attachments": [attachment(1)]]),
        ]
        for body in invalid { #expect(await fixture.request("POST", "/v1/crashes", body: body).status == 400) }
        // 한도를 꽉 채운 첨부와 글이 본문 한도(4MiB) 안에 들어간다.
        let full = try jsonText(["kind": "feedback", "text": String(repeating: "x", count: 1536 << 10),
                                 "attachments": [attachment(CrashReport.maxAttachmentBytes), attachment(CrashReport.maxAttachmentTotalBytes - CrashReport.maxAttachmentBytes)]])
        #expect(full.utf8.count < 4 << 20)
        #expect(await fixture.request("POST", "/v1/crashes", body: full).status == 202)
    }
    @Test("확인 목록의 답: 피드백에만 받고 길이를 자른다")
    func 확인답() async throws {
        let fixture = try HostFixture()
        let long = String(repeating: "가", count: 1000)
        let body = try jsonText(["kind": "feedback", "text": "답이 있어요", "checks": [
            ["id": "pay.sheet", "title": "결제 화면이 열린다", "answer": "보임", "note": long, "build": "59", "answeredAt": "2026-11-13T05:05:01.000Z"],
            ["id": "launch"],
        ]])
        #expect(await fixture.request("POST", "/v1/crashes", body: body).status == 202)
        guard case .deviceCrash(let event) = fixture.events.next() else { Issue.record("크래시 사건 없음"); return }
        #expect(event.report.checks.map(\.id) == ["pay.sheet", "launch"])
        #expect(event.report.checks[0].answer == "보임" && event.report.checks[0].build == "59")
        #expect(event.report.checks[0].note.utf8.count <= 800 && event.report.checks[1].answer.isEmpty)
        let invalid = try [
            jsonText(["kind": "ips", "text": "x", "checks": [["id": "a"]]]),
            jsonText(["kind": "feedback", "text": "x", "checks": [["title": "id 없음"]]]),
            jsonText(["kind": "feedback", "text": "x", "checks": "nope"]),
            jsonText(["kind": "feedback", "text": "x", "checks": (0...FeedbackChecklist.maxItems).map { ["id": "i\($0)"] }]),
        ]
        for body in invalid { #expect(await fixture.request("POST", "/v1/crashes", body: body).status == 400) }
    }
    @Test("확인 목록: 페어링한 기기만 받고, 없으면 빈 목록")
    func 확인목록() async throws {
        let unpaired = try HostFixture(paired: false)
        #expect(await unpaired.request("/v1/feedback/checklist/com.example.app").status == 403)

        let fixture = try HostFixture()
        let empty = await fixture.request("/v1/feedback/checklist/com.example.app")
        #expect(empty.status == 200)
        let emptyBody = String(decoding: try responseData(empty), as: UTF8.self)
        #expect(emptyBody == #"{"bundleId":"com.example.app","items":[]}"#)

        let stored = #"{"bundleId":"com.example.app","items":[{"id":"launch","title":"앱이 켜진다","choices":["통과","실패"],"expect":[]}],"updatedAt":"2026-11-13T05:05:01Z"}"#
        try Data(stored.utf8).write(to: fixture.directory.appendingPathComponent("checklist-com.example.app.json"))
        let found = await fixture.request("/v1/feedback/checklist/com.example.app")
        let foundBody = String(decoding: try responseData(found), as: UTF8.self)
        #expect(found.status == 200 && foundBody == stored)
        #expect(await fixture.request("/v1/feedback/checklist/other.app").status == 200)
        #expect(await fixture.request("/v1/feedback/checklist/bad%20id").status == 400)
        #expect(await fixture.request("POST", "/v1/feedback/checklist/com.example.app", body: "{}").status == 405)
        // 저장된 것이 JSON 객체가 아니면 빈 목록으로 답한다.
        try Data("broken".utf8).write(to: fixture.directory.appendingPathComponent("checklist-com.example.app.json"))
        let broken = await fixture.request("/v1/feedback/checklist/com.example.app")
        let brokenBody = String(decoding: try responseData(broken), as: UTF8.self)
        #expect(brokenBody.contains(#""items":[]"#))
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
