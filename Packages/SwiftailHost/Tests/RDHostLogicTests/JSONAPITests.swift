import Foundation
import RDModels
import Testing
@testable import RDHostLogic

@Suite("호스트 JSON 입력")
struct JSONAPITests {
    @Test("devices 배열이 없거나 잘못되면 목록 유지")
    func 기기배열() throws {
        let fixture = try HostFixture(paired: false)
        try fixture.host.setDevices(json: Data(#"{"devices":[{"id":"d_1","name":"p","nodeStableId":"nSTABLE1","nodeName":"rd-phone-1"}]}"#.utf8))
        #expect(fixture.host.counts().devices == 1)
        for bad in ["{}", "null", #"{"devices":null}"#, #"{"deviceList":[]}"#, #"{"devices":{}}"#, "[]"] {
            expectError("bad_request") { try fixture.host.setDevices(json: Data(bad.utf8)) }
            #expect(fixture.host.counts().devices == 1)
        }
        try fixture.host.setDevices(json: Data(#"{"devices":[]}"#.utf8))
        #expect(fixture.host.counts().devices == 0)
    }

    @Test("빌드 JSON은 빠진 필드 기본값과 문자열 메타데이터를 보존")
    func 빌드문자열() async throws {
        let fixture = try HostFixture()
        let request = try fixture.writeBuild()
        let body: [String: Any] = ["bundleId": "com.example.app", "debug": true, "configurationEvidence": "future-value",
            "signing": ["getTaskAllow": true, "profileExpires": "unparsed"], "ipa": ["size": request.build.ipa.size, "sha256": request.build.ipa.sha256],
            "ipaPath": request.ipaPath, "publishedAt": "opaque-time", "releaseNotes": "첫 줄\n둘째 줄 "]
        let id = try fixture.host.publish(json: Data(jsonText(body).utf8))
        let response = await fixture.request("/v1/builds")
        let raw = try JSONSerialization.jsonObject(with: responseData(response)) as? [String: [[String: Any]]]
        let build = try #require(raw?["builds"]?.first)
        #expect(build["id"] as? String == id)
        #expect(build["configurationEvidence"] as? String == "future-value")
        #expect(build["publishedAt"] as? String == "opaque-time")
        #expect((build["signing"] as? [String: Any])?["profileExpires"] as? String == "unparsed")
        #expect(build["displayName"] as? String == "")
        #expect(build["releaseNotes"] as? String == "첫 줄\n둘째 줄")
        expectError("not_debug_build") { try fixture.host.publish(json: Data("{}".utf8)) }
        expectError("bad_request") { try fixture.host.publish(json: Data("{broken".utf8)) }
    }

    @Test("링크 JSON은 경로 없이 받으며 잘못된 시각과 구역을 검증")
    func 리소스문자열() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publishResource(json: Data(#"{"name":"open","link":"sample:open","publishedAt":"bad"}"#.utf8))
        let list: ResourcesResponse = try decode(await fixture.request("/v1/resources"))
        #expect(list.resources.first?.id == id && list.resources.first?.publishedAt == fixture.clock.now())
        #expect(list.resources.first?.size == 0)
        expectError("bad_request") { try fixture.host.publishResource(json: Data(#"{"name":"x","link":"sample:x","project":{"id":"a/b","name":"x"}}"#.utf8)) }
        expectError("bad_request") { try fixture.host.publishResource(json: Data(#"{"name":"x","link":"sample:x","project":4}"#.utf8)) }
    }

    @Test("JSON 읽기는 본문별 후행 값 규칙과 필드 자료형 적용")
    func JSON규칙() async throws {
        let fixture = try HostFixture()
        try fixture.host.setAgentBoard(Data(#"{"enabled":true}"#.utf8))
        #expect(await fixture.request("POST", "/v1/agent/requests", body: #"{"text":"hello"} trailing"#).status == 202)
        #expect(await fixture.request("POST", "/v1/agent/requests", body: #"{"TEXT":"hello"}"#).status == 202)
        #expect(await fixture.request("POST", "/v1/agent/requests", body: #"{"text":true}"#).status == 400)
        #expect(await fixture.request("POST", "/v1/logs", body: #"{"entries":[null]}"#).status == 202)
        expectError("bad_request") { try fixture.host.setDevices(json: Data(#"{"devices":[]} false"#.utf8)) }
    }
    @Test("기기 사건은 저장된 시각 문자열을 원문 그대로 보존")
    func 기기시각원문() async throws {
        let fixture = try HostFixture(direct: true)
        try fixture.host.setDevices(json: Data(#"{"devices":[{"id":"d_1","nodeStableId":"n_phone","pairedAt":"unparsed"}]}"#.utf8))
        _ = try await fixture.enroll()
        let emitted = try #require(fixture.events.nextEvent())
        let data = try JSONEncoder().encode(emitted)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((raw?["device"] as? [String: Any])?["pairedAt"] as? String == "unparsed")
        #expect(try JSONDecoder().decode(HostLogic.EmittedEvent.self, from: data) == emitted)
    }

}
