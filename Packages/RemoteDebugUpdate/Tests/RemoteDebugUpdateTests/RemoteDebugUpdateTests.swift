import Foundation
import Testing
@testable import RemoteDebugUpdate

@Suite struct RemoteDebugUpdateTests {
    #if DEBUG
    @Test func baseURLNormalizesAndRejectsInvalidHosts() {
        #expect(UpdateClient.baseURL(host: "rd-mac-1a2b3c4d.tail0001.ts.net")?.absoluteString == "https://rd-mac-1a2b3c4d.tail0001.ts.net")
        #expect(UpdateClient.baseURL(host: " HTTPS://RD-MAC.ts.net/ ")?.absoluteString == "https://rd-mac.ts.net")
        #expect(UpdateClient.baseURL(host: "") == nil)
        #expect(UpdateClient.baseURL(host: "localhost") == nil)
        #expect(UpdateClient.baseURL(host: "bad host.ts.net") == nil)
        #expect(UpdateClient.baseURL(host: "rd-mac.ts.net/path") == nil)
    }

    @Test func deepLinkBuildsValidUpdateURL() {
        let simple = UpdateDeepLink.url(bundleId: "com.example.app")
        #expect(simple?.absoluteString == "remotedebug://update?bundleId=com.example.app")

        let withBuild = UpdateDeepLink.url(bundleId: "com.example.app", buildId: "b_123")
        #expect(withBuild?.absoluteString == "remotedebug://update?bundleId=com.example.app&buildId=b_123")

        #expect(UpdateDeepLink.url(bundleId: "") == nil)
        #expect(UpdateDeepLink.url(bundleId: ".bad") == nil)
        #expect(UpdateDeepLink.url(bundleId: "bad/id") == nil)
    }

    @Test func versionAndTimestampComparison() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000)
        let current = CurrentBuild(version: "1.2", buildNumber: "10", installedAt: t1)

        func info(version: String, build: String, publishedAt: Date) -> UpdateInfo {
            UpdateInfo(buildId: "b1", bundleId: "com.example.app", displayName: "App",
                       version: version, buildNumber: build, minOS: "17.0", publishedAt: publishedAt)
        }

        // 버전이 높으면 새 빌드
        #expect(current.isNewer(info(version: "1.3", build: "1", publishedAt: t1)))
        #expect(current.isNewer(info(version: "1.10", build: "1", publishedAt: t1)))
        // 버전이 낮으면 아님
        #expect(!current.isNewer(info(version: "1.1", build: "99", publishedAt: t2)))
        // 버전이 같고 빌드 번호가 높으면 새 빌드
        #expect(current.isNewer(info(version: "1.2", build: "11", publishedAt: t1)))
        // 버전이 같고 빌드 번호가 낮으면 아님
        #expect(!current.isNewer(info(version: "1.2", build: "9", publishedAt: t2)))
        // 버전·빌드 번호가 모두 같으면 게시 시각으로 비교
        #expect(current.isNewer(info(version: "1.2", build: "10", publishedAt: t2)))
        #expect(!current.isNewer(info(version: "1.2", build: "10", publishedAt: t1)))
    }

    @Test func checkUsesUpdatesEndpoint() async throws {
        let json = """
        {
          "bundleId": "com.example.app",
          "latest": {
            "id": "b_new",
            "bundleId": "com.example.app",
            "displayName": "Sample",
            "version": "1.2",
            "buildNumber": "12",
            "minOS": "17.0",
            "publishedAt": "2026-11-26T12:00:00Z",
            "releaseNotes": "버그 수정\\n성능 개선",
            "ipaSize": 2048
          }
        }
        """
        let client = try #require(UpdateClient(host: "rd-mac-test.ts.net") { request in
            #expect(request.url?.path == "/v1/updates/com.example.app")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        })
        let current = CurrentBuild(version: "1.2", buildNumber: "11", installedAt: Date(timeIntervalSince1970: 0))
        let status = await client.check(bundleID: "com.example.app", current: current)
        guard case .available(let info) = status else {
            Issue.record("Expected .available, got \(status)")
            return
        }
        #expect(info.buildId == "b_new")
        #expect(info.version == "1.2")
        #expect(info.buildNumber == "12")
        #expect(info.releaseNotes == "버그 수정\n성능 개선")
        #expect(info.ipaSize == 2048)
    }

    @Test func checkFallsBackToBuildsEndpointOn404() async throws {
        let buildsJSON = """
        {
          "builds": [
            {
              "id": "b_other",
              "bundleId": "com.example.other",
              "displayName": "Other",
              "version": "9.0",
              "buildNumber": "99",
              "minOS": "17.0",
              "publishedAt": "2026-11-26T13:00:00Z"
            },
            {
              "id": "b_mine",
              "bundleId": "com.example.app",
              "displayName": "Sample",
              "version": "1.3",
              "buildNumber": "15",
              "minOS": "17.0",
              "publishedAt": "2026-11-26T12:30:00Z",
              "releaseNotes": "새 화면",
              "ipa": { "size": 4096 }
            }
          ]
        }
        """
        let client = try #require(UpdateClient(host: "rd-mac-test.ts.net") { request in
            if request.url?.path == "/v1/updates/com.example.app" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
            #expect(request.url?.path == "/v1/builds")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(buildsJSON.utf8), response)
        })
        let current = CurrentBuild(version: "1.2", buildNumber: "10", installedAt: Date(timeIntervalSince1970: 0))
        let status = await client.check(bundleID: "com.example.app", current: current)
        guard case .available(let info) = status else {
            Issue.record("Expected .available via fallback, got \(status)")
            return
        }
        #expect(info.buildId == "b_mine")
        #expect(info.releaseNotes == "새 화면")
        #expect(info.ipaSize == 4096)
    }

    @Test func checkReturnsUpToDateWhenNoPublishedBuild() async throws {
        let json = #"{"bundleId":"com.example.app","latest":null}"#
        let client = try #require(UpdateClient(host: "rd-mac-test.ts.net") { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        })
        let current = CurrentBuild(version: "1.0", buildNumber: "1", installedAt: Date())
        let status = await client.check(bundleID: "com.example.app", current: current)
        #expect(status == .upToDate(nil))
    }

    @Test func debugStringsCoverAllLanguages() {
        for key in UpdateDebugStrings.Key.allCases {
            for lang in UpdateDebugStrings.languages {
                #expect(!UpdateDebugStrings.text(key, language: lang).isEmpty)
            }
        }
        #expect(UpdateDebugStrings.pickLanguage(preferred: ["ko-KR"]) == "ko")
        #expect(UpdateDebugStrings.pickLanguage(preferred: ["ja-JP"]) == "ja")
        #expect(UpdateDebugStrings.pickLanguage(preferred: ["zh-Hant-TW"]) == "zh-Hant")
        #expect(UpdateDebugStrings.pickLanguage(preferred: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(UpdateDebugStrings.pickLanguage(preferred: ["fr-FR"]) == "en")
    }
    #else
    @Test func releaseBuildDisablesAllUpdateBehavior() async {
        #expect(!RemoteDebugUpdate.start(macHost: "rd-mac-test.ts.net"))
        #expect(!RemoteDebugUpdate.isConfigured)
        #expect(RemoteDebugUpdate.updaterURL() == nil)
        #expect(await RemoteDebugUpdate.check() == .unavailable(.disabledInRelease))
    }
    #endif
}
