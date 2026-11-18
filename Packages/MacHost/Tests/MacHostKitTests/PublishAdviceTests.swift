import Foundation
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

@MainActor
@Suite("PublishAdvice")
struct PublishAdviceTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func build(_ id: String, bundle: String = "com.example.App", version: String = "1.0", number: String,
                       profileDays: Double = 300) -> BuildDescriptor {
        var d = sampleDescriptor(bundleId: bundle, name: "App", now: now)
        d.id = id
        d.version = version
        d.buildNumber = number
        d.signing.profileExpires = now.addingTimeInterval(86_400 * profileDays)
        return d
    }

    @Test func aChangedBinaryWithTheSameVersionIsReported() {
        let notes = PublishAdvice.notes(for: build("b", number: "7"), others: [build("a", number: "7"), build("b", number: "7")], now: now)
        #expect(notes.count == 1)
        #expect(notes[0].contains("App 1.0 (7)") && notes[0].contains("CURRENT_PROJECT_VERSION"))
    }

    @Test func aRaisedBuildNumberAndOtherAppsAreQuiet() {
        let others = [build("a", number: "9"), build("x", bundle: "com.example.Other", number: "10")]
        #expect(PublishAdvice.notes(for: build("b", number: "10"), others: others, now: now).isEmpty)
        // 첫 게시와, 버전이 다른 앞선 빌드도 알리지 않는다.
        #expect(PublishAdvice.notes(for: build("b", number: "1"), others: [], now: now).isEmpty)
        #expect(PublishAdvice.notes(for: build("b", version: "2.0", number: "1"), others: [build("a", number: "9")], now: now).isEmpty)
    }

    @Test func aLoweredBuildNumberIsComparedAsANumber() {
        let notes = PublishAdvice.notes(for: build("b", number: "9"), others: [build("a", number: "10")], now: now)
        #expect(notes.count == 1 && notes[0].contains("(10)보다 낮습니다"))
    }

    @Test func aProfileAboutToExpireIsReported() {
        let notes = PublishAdvice.notes(for: build("b", number: "1", profileDays: 2.5), others: [], now: now)
        #expect(notes.count == 1 && notes[0].contains("2일 뒤 만료"))
        #expect(PublishAdvice.notes(for: build("b", number: "1", profileDays: 4), others: [], now: now).isEmpty)
    }

    /// 에이전트 응답: 빌드 응답에 점검 사항이, 상태 응답에 지금 게시된 버전이 실린다.
    @Test func agentResponsesCarryNotesAndThePublishedVersion() async throws {
        let tmp = try TempDir("advice")
        let container = tmp.path("src/App/App.xcodeproj").standardizedFileURL
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let app = tmp.path("products/App.app")
        let builder = AdviceBuilder(app: app)
        let library = Mutex<[BuildDescriptor]>([build("a", number: "7")])
        let next = build("b", number: "7")
        let model = ProjectsModel(root: tmp.path("state"), builder: builder, scanner: DerivedDataScanner(root: tmp.path("DerivedData")),
                                  hostStatus: { .init(sharing: false, installPage: nil) },
                                  publishedBuilds: { library.withLock { $0 } }) { url in
            library.withLock { $0.insert(next, at: 0) }
            return .accepted(LibraryBuild(descriptor: next, sourcePath: url.path))
        }

        let built = await model.handleAgentRequest("build\n\(container.path)\nApp\n")
        let notes = try #require(built.report?.notes)
        #expect(built.ok && notes.count == 2)
        #expect(notes[0].contains("버전과 빌드 번호가 앞서 게시한 빌드와 같습니다") && notes[1].contains("공유가 꺼져"))

        let status = await model.handleAgentRequest("status\n\n\n")
        #expect(status.projects?.first?.published?.map(\.buildId) == ["b"])

        // 결과가 그대로면 새로 게시하지 않았다고 알린다.
        let again = await model.handleAgentRequest("build\n\(container.path)\nApp\n")
        #expect(again.ok && again.report?.published.isEmpty == true)
        #expect(again.report?.notes?.contains { $0.contains("새로 게시하지 않았습니다") } == true)
    }

    /// 에이전트가 사람 손을 빌리지 않고 피드백 패키지 설정 코드를 받는다.
    @Test func feedbackCommandReturnsTheSnippetWithHostAndKey() async throws {
        let tmp = try TempDir("feedback")
        let container = tmp.path("src/App/App.xcodeproj").standardizedFileURL
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let model = ProjectsModel(root: tmp.path("state"), builder: AdviceBuilder(app: tmp.path("p/App.app")),
                                  scanner: DerivedDataScanner(root: tmp.path("DerivedData")),
                                  feedbackInfo: { _ in ("rd-mac-1a2b3c4d.tail0001.ts.net", "S0VZ") }) { _ in nil }

        let plain = try #require(await model.handleAgentRequest("feedback\n\(container.path)\n\n").feedback)
        #expect(!plain.added && plain.product == "RemoteDebugFeedback")
        #expect(plain.snippet.contains(#"macHost: "rd-mac-1a2b3c4d.tail0001.ts.net""#) && plain.snippet.contains(#"publicKeyBase64: "S0VZ""#))
        #expect(!plain.snippet.contains("email:") && plain.steps.contains { $0.contains("email이 비어 있다") })

        try Data("RemoteDebugFeedback".utf8).write(to: container.appendingPathComponent("project.pbxproj"))
        let mailed = try #require(await model.handleAgentRequest("feedback\n\(container.path)\nme@example.com\n").feedback)
        #expect(mailed.added && mailed.snippet.contains(#"email: "me@example.com""#))
        #expect(!mailed.steps.contains { $0.contains("email이 비어 있다") })
        // 메일 주소가 있으면 배포판은 Mac 주소 없이 메일만 쓴다.
        let release = try #require(mailed.snippet.components(separatedBy: "#else").last)
        #expect(mailed.snippet.contains("#if DEBUG") && release.contains(#".init(email: "me@example.com")"#) && !release.contains("macHost"))

        // 받은 피드백 목록과 원문을 명령으로 읽는다.
        let dir = tmp.path("state/CrashLogs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(await model.handleAgentRequest("reports\nfeedback\n\n").text?.contains("받은 크래시 기록이 없습니다") == true)
        #expect(await !model.handleAgentRequest("report\nc_none\n\n").ok)
    }
}

private struct AdviceBuilder: ProjectBuilding {
    let app: URL
    func schemes(container: URL) async throws -> [String] { ["App"] }
    func build(container: URL, scheme: String, log: URL) async throws {
        if !FileManager.default.fileExists(atPath: app.path) { try makeFakeApp(at: app) }
    }
    func products(container: URL, scheme: String) async throws -> [URL] { [app] }
}
