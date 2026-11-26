import Foundation
import PhoneClientKit
import RDModels
import Testing

@Suite struct UpdateLinkTests {
    private func makeBuild(id: String, bundleId: String, publishedAt: Date) -> BuildDescriptor {
        BuildDescriptor(
            id: id,
            bundleId: bundleId,
            displayName: "Sample",
            version: "1.0",
            buildNumber: "1",
            minOS: "17.0",
            debug: true,
            configuration: "Debug",
            configurationEvidence: .path,
            signing: .init(teamId: "TEAM", profileName: "Dev", profileExpires: Date().addingTimeInterval(86_400),
                           provisionedDeviceCount: 1, getTaskAllow: true),
            ipa: .init(size: 1024, sha256: "abc"),
            publishedAt: publishedAt
        )
    }

    @Test func parsesValidUpdateURLs() throws {
        let simple = try #require(URL(string: "remotedebug://update?bundleId=com.example.app"))
        #expect(UpdateLink.request(from: simple) == UpdateLinkRequest(bundleId: "com.example.app", buildId: nil))

        let withBuild = try #require(URL(string: "RemoteDebug://UPDATE/?bundleId=com.example.app&buildId=b_42"))
        #expect(UpdateLink.request(from: withBuild) == UpdateLinkRequest(bundleId: "com.example.app", buildId: "b_42"))
    }

    @Test func rejectsInvalidOrUnrelatedURLs() throws {
        let cases = [
            "remotedebug://pair#v=1",
            "remotedebug://vpn?action=connect",
            "remotedebug://update",
            "remotedebug://update?bundleId=",
            "remotedebug://update?bundleId=.bad",
            "remotedebug://update?bundleId=bad/id",
            "remotedebug://update/extra?bundleId=com.example.app",
            "https://example.com/update?bundleId=com.example.app",
        ]
        for raw in cases {
            let url = try #require(URL(string: raw))
            #expect(UpdateLink.request(from: url) == nil, "Expected nil for \(raw)")
        }
    }

    @Test func selectsExactOrLatestBuildAndExcludesSelf() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000)
        let builds = [
            makeBuild(id: "b_old", bundleId: "com.example.app", publishedAt: t1),
            makeBuild(id: "b_new", bundleId: "com.example.app", publishedAt: t2),
            makeBuild(id: "b_self", bundleId: "com.oozoofrog.app.RemoteDebugPhone", publishedAt: t2),
        ]

        // buildId가 없으면 가장 최근 빌드
        let latest = UpdateLink.selectBuild(for: .init(bundleId: "com.example.app"), in: builds,
                                            excluding: "com.oozoofrog.app.RemoteDebugPhone")
        #expect(latest?.id == "b_new")

        // buildId가 맞으면 그 빌드
        let exact = UpdateLink.selectBuild(for: .init(bundleId: "com.example.app", buildId: "b_old"), in: builds,
                                           excluding: "com.oozoofrog.app.RemoteDebugPhone")
        #expect(exact?.id == "b_old")

        // buildId가 목록에 없으면 최신 빌드로 내려감
        let fallback = UpdateLink.selectBuild(for: .init(bundleId: "com.example.app", buildId: "missing"), in: builds,
                                              excluding: "com.oozoofrog.app.RemoteDebugPhone")
        #expect(fallback?.id == "b_new")

        // RemoteDebug 자신은 제외
        let selfReq = UpdateLink.selectBuild(for: .init(bundleId: "com.oozoofrog.app.RemoteDebugPhone"), in: builds,
                                             excluding: "com.oozoofrog.app.RemoteDebugPhone")
        #expect(selfReq == nil)
    }
}
