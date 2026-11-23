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
                                  publishedBuilds: { library.withLock { $0 } }) { url, releaseNotes in
            var accepted = next
            accepted.releaseNotes = releaseNotes
            library.withLock { $0.insert(accepted, at: 0) }
            return .accepted(LibraryBuild(descriptor: accepted, sourcePath: url.path))
        }

        // 넷째 줄부터 끝까지가 업데이트 내역이다. 너무 길면 빌드하지 않는다.
        let long = await model.handleAgentRequest("build\n\(container.path)\nApp\n" + String(repeating: "a", count: BuildDescriptor.maxReleaseNotesBytes + 1))
        #expect(!long.ok && long.error?.contains("업데이트 내역이 너무 깁니다") == true && library.withLock { $0.count } == 1)

        let built = await model.handleAgentRequest("build\n\(container.path)\nApp\n로그인 고침\n- 목록 정렬\n")
        #expect(built.report?.published.first?.releaseNotes == "로그인 고침\n- 목록 정렬")
        #expect(library.withLock { $0.first?.releaseNotes } == "로그인 고침\n- 목록 정렬")
        let notes = try #require(built.report?.notes)
        #expect(built.ok && notes.count == 2)
        #expect(notes[0].contains("버전과 빌드 번호가 앞서 게시한 빌드와 같습니다") && notes[1].contains("공유가 꺼져"))

        let status = await model.handleAgentRequest("status\n\n\n")
        #expect(status.projects?.first?.published?.map(\.buildId) == ["b"])

        // 결과가 그대로면 새로 게시하지 않았다고 알린다.
        let again = await model.handleAgentRequest("build\n\(container.path)\nApp\n붙지 않을 내역")
        #expect(again.ok && again.report?.published.isEmpty == true)
        #expect(again.report?.notes?.contains { $0.contains("업데이트 내역도 붙지 않았습니다") } == true)
        #expect(again.report?.notes?.contains { $0.contains("새로 게시하지 않았습니다") } == true)
    }

    /// 에이전트가 사람 손을 빌리지 않고 피드백 패키지 설정 코드를 받는다.
    @Test func feedbackCommandReturnsTheSnippetWithHostAndKey() async throws {
        let tmp = try TempDir("feedback")
        let container = tmp.path("src/App/App.xcodeproj").standardizedFileURL
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let model = ProjectsModel(root: tmp.path("state"), builder: AdviceBuilder(app: tmp.path("p/App.app")),
                                  scanner: DerivedDataScanner(root: tmp.path("DerivedData")),
                                  feedbackInfo: { _ in ("rd-mac-1a2b3c4d.tail0001.ts.net", "S0VZ") }) { _, _ in nil }

        let plain = try #require(await model.handleAgentRequest("feedback\n\(container.path)\n\n").feedback)
        #expect(!plain.added && plain.product == "RemoteDebugFeedback")
        #expect(plain.snippet.contains(#"macHost: "rd-mac-1a2b3c4d.tail0001.ts.net""#) && plain.snippet.contains(#"publicKeyBase64: "S0VZ""#))
        #expect(!plain.snippet.contains("email:") && plain.steps.contains { $0.contains("email이 비어 있고") })

        try Data("RemoteDebugFeedback".utf8).write(to: container.appendingPathComponent("project.pbxproj"))
        let mailed = try #require(await model.handleAgentRequest("feedback\n\(container.path)\nme@example.com\n").feedback)
        #expect(mailed.added && mailed.snippet.contains(#"email: "me@example.com""#))
        #expect(!mailed.steps.contains { $0.contains("email이 비어 있고") })
        // 메일 주소가 있으면 배포판은 Mac 주소 없이 메일만 쓴다.
        let release = try #require(mailed.snippet.components(separatedBy: "#else").last)
        #expect(mailed.snippet.contains("#if DEBUG") && release.contains(#".init(email: "me@example.com", publicKeyBase64: "S0VZ")"#) && !release.contains("macHost"))

        // 받은 피드백 목록과 원문을 명령으로 읽는다.
        let dir = tmp.path("state/CrashLogs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(await model.handleAgentRequest("reports\nfeedback\n\n").text?.contains("받은 크래시 기록이 없습니다") == true)
        #expect(await !model.handleAgentRequest("report\nc_none\n\n").ok)
    }
}

extension PublishAdviceTests {
    /// 에이전트가 앱의 확인 목록을 남기고, 읽고, 지운다. 코어는 같은 파일을 iPhone에 내준다.
    @Test func checklistCommandSetsGetsAndClears() async throws {
        let tmp = try TempDir("checklist")
        let model = ProjectsModel(root: tmp.path("state"), builder: AdviceBuilder(app: tmp.path("p/App.app")),
                                  scanner: DerivedDataScanner(root: tmp.path("DerivedData")),
                                  now: { Date(timeIntervalSince1970: 1_794_478_500) }) { _, _ in nil }
        let file = FeedbackChecklist.file(bundleId: "com.example.app", publishDirectory: tmp.path("state/Published").path)

        let none = await model.handleAgentRequest("checklist\ncom.example.app\n\n")
        #expect(none.ok && none.checklist == nil && none.text?.contains("없습니다") == true)

        // MCP는 항목을 한 줄 JSON으로, rd는 파일 경로로 넘긴다.
        let inline = #"[{"id":"launch","title":"앱이 켜진다"},{"id":"pay.sheet","title":"결제 화면이 열린다","place":"설정 › 결제","expect":["금액이 보임"],"choices":["보임","안 보임","모르겠음"],"since":59,"stage":"결제"}]"#
        let set = await model.handleAgentRequest("checklist\ncom.example.app\n\(inline)\n")
        #expect(set.ok && set.checklist?.items.map(\.id) == ["launch", "pay.sheet"])
        #expect(set.checklist?.items.first?.choices == FeedbackChecklist.defaultChoices)
        let onDisk = try RDJSON.decoder().decode(FeedbackChecklist.self, from: Data(contentsOf: file))
        #expect(onDisk == set.checklist && onDisk.updatedAt == Date(timeIntervalSince1970: 1_794_478_500))

        let source = tmp.path("items.json")
        try Data(#"{"items":[{"id":"only","title":"하나만"}]}"#.utf8).write(to: source)
        let fromFile = await model.handleAgentRequest("checklist\ncom.example.app\n\(source.path)\n")
        #expect(fromFile.ok && fromFile.checklist?.items.map(\.id) == ["only"])
        #expect(await model.handleAgentRequest("checklist\ncom.example.app\n\n").checklist?.items.map(\.id) == ["only"])

        // 틀린 목록은 저장하지 않고 까닭을 돌려준다.
        let bad = await model.handleAgentRequest("checklist\ncom.example.app\n[{\"id\":\"a\"}]\n")
        #expect(!bad.ok && bad.error?.contains("title") == true)
        #expect(await !model.handleAgentRequest("checklist\ncom.example.app\n\(tmp.path("missing.json").path)\n").ok)
        #expect(await !model.handleAgentRequest("checklist\n../escape\n[]\n").ok)
        #expect(await !model.handleAgentRequest("checklist\n\n\n").ok)
        #expect(await model.handleAgentRequest("checklist\ncom.example.app\n\n").checklist?.items.map(\.id) == ["only"])

        let cleared = await model.handleAgentRequest("checklist\ncom.example.app\nclear\n")
        #expect(cleared.ok && !FileManager.default.fileExists(atPath: file.path))
        #expect(await model.handleAgentRequest("checklist\ncom.example.app\n\n").checklist == nil)
    }

    @Test func checklistIsInTheScriptAndTheGuidance() {
        let script = AgentScript.text(agentDir: "/tmp/agent", bundleID: "dev.example.RemoteDebug")
        #expect(script.contains("checklist <번들 ID> [항목 JSON 파일|clear]"))
        #expect(script.contains(#"checklist) case "$scheme" in ""|clear|/*) ;; *) scheme="$PWD/$scheme" ;; esac ;;"#))
        #expect(AgentScript.feedbackGuidance.contains("remotedebug_feedback_checklist") && AgentScript.feedbackGuidance.contains("확인 목록의 답"))
    }

    /// 부른 쪽이 메일 주소를 주지 않으면 Mac 앱 설정에 저장된 주소가 들어간다.
    @Test func feedbackCommandUsesTheAddressSavedInTheMacApp() async throws {
        let tmp = try TempDir("feedback-mail")
        let container = tmp.path("src/App/App.xcodeproj").standardizedFileURL
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let model = ProjectsModel(root: tmp.path("state"), builder: AdviceBuilder(app: tmp.path("p/App.app")),
                                  scanner: DerivedDataScanner(root: tmp.path("DerivedData")),
                                  feedbackInfo: { _ in ("rd-mac-1a2b3c4d.tail0001.ts.net", "S0VZ") },
                                  savedFeedbackEmail: { " dev@example.com " }) { _, _ in nil }

        let saved = try #require(await model.handleAgentRequest("feedback\n\(container.path)\n\n").feedback)
        #expect(saved.email == "dev@example.com" && saved.emailSource == "macSetting")
        #expect(saved.snippet.contains(#"email: "dev@example.com""#) && saved.snippet.contains("#if DEBUG"))
        #expect(saved.steps.contains { $0.contains("저장해 둔 것이다") } && !saved.steps.contains { $0.contains("email이 비어 있고") })

        let given = try #require(await model.handleAgentRequest("feedback\n\(container.path)\nother@example.com\n").feedback)
        #expect(given.email == "other@example.com" && given.emailSource == "argument")
    }
}

struct AdviceBuilder: ProjectBuilding {
    let app: URL
    func schemes(container: URL) async throws -> [String] { ["App"] }
    func build(container: URL, scheme: String, log: URL) async throws {
        if !FileManager.default.fileExists(atPath: app.path) { try makeFakeApp(at: app) }
    }
    func products(container: URL, scheme: String) async throws -> [URL] { [app] }
}
