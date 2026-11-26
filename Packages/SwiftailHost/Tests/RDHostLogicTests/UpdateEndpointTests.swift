import Foundation
import RDModels
import Testing
@testable import RDHostLogic

@Suite("업데이트 조회 경로")
struct UpdateEndpointTests {
    @Test("페어링 필요")
    func 인증() async throws {
        let fixture = try HostFixture(paired: false)
        let response = await fixture.request("/v1/updates/com.example.app")
        #expect(try response.status == 403 && errorCode(response) == "not_paired")
    }

    @Test("게시된 빌드가 없으면 latest가 null")
    func 게시없음() async throws {
        let fixture = try HostFixture()
        let response = await fixture.request("/v1/updates/com.example.app")
        #expect(response.status == 200)
        let object = try JSONSerialization.jsonObject(with: responseData(response)) as? [String: Any]
        #expect(object?["bundleId"] as? String == "com.example.app")
        #expect(object?["latest"] is NSNull)
    }

    @Test("번들 ID의 가장 최근 빌드만 아이콘 없이 반환")
    func 최신빌드반환() async throws {
        let fixture = try HostFixture()
        var first = try fixture.writeBuild("old-ipa-data", bundleID: "com.example.app")
        first.build.version = "1.0"
        first.build.buildNumber = "1"
        first.build.releaseNotes = "첫 빌드"
        _ = try fixture.host.publish(first)

        fixture.clock.advance(60)
        var other = try fixture.writeBuild("other-app", bundleID: "com.example.other")
        other.build.version = "9.0"
        other.build.buildNumber = "99"
        _ = try fixture.host.publish(other)

        fixture.clock.advance(60)
        var newer = try fixture.writeBuild("new-ipa-data-longer", bundleID: "com.example.app")
        newer.build.version = "1.1"
        newer.build.buildNumber = "2"
        newer.build.releaseNotes = "버그 수정"
        let newerID = try fixture.host.publish(newer)

        let response = await fixture.request("/v1/updates/com.example.app")
        #expect(response.status == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: responseData(response)) as? [String: Any])
        #expect(object["bundleId"] as? String == "com.example.app")
        let latest = try #require(object["latest"] as? [String: Any])
        #expect(latest["id"] as? String == newerID)
        #expect(latest["version"] as? String == "1.1")
        #expect(latest["buildNumber"] as? String == "2")
        #expect(latest["releaseNotes"] as? String == "버그 수정")
        #expect(latest["ipaSize"] as? Int == "new-ipa-data-longer".utf8.count)
        #expect(latest["icon"] == nil)
    }

    @Test("잘못된 번들 ID는 400")
    func 잘못된번들ID() async throws {
        let fixture = try HostFixture()
        let response = await fixture.request("/v1/updates/.invalid")
        #expect(try response.status == 400 && errorCode(response) == "bad_request")
    }
}
