import Foundation
import Testing
@testable import RemoteDebugFeedback

/// 메일 본문의 모양, 검색용 표시 줄, 기기 종류 글, 글 없는 피드백, 확인 목록의 기본 답과 거르기·지우기.
struct FeedbackContentTests {
    private let info = FeedbackAppInfo(name: "Sample", version: "1.2", build: "3", system: "iOS 18.1", device: "iPhone16,2",
                                       bundleID: "com.example.sample")

    @Test func mailBodyHasUserTextThenNoticeVersionWithBuildSystemDeviceKindAndTag() {
        let content = FeedbackContent.standard(info, message: "느려요", usageNotice: "문제를 살펴보는 데만 씁니다.")
        #expect(content.body == "느려요\n\n\n---\n문제를 살펴보는 데만 씁니다.\nApp: Sample 1.2 (3)\nOS: iOS 18.1\nDevice: iPhone16,2\n[rdfeedback:com.example.sample:3]")
        // 글이 없어도 같은 모양이다.
        let empty = FeedbackContent.standard(info, message: "", usageNotice: FeedbackLabels().usageNotice)
        #expect(empty.body.hasPrefix("\n\n\n---\n\(FeedbackContent.defaultUsageNotice)\nApp: Sample 1.2 (3)\n"))
        #expect(empty.body.hasSuffix("\n[rdfeedback:com.example.sample:3]"))
    }

    @Test func searchTagIsStableAndCarriesOnlySafeCharacters() {
        #expect(FeedbackContent.searchTag(bundleID: "com.example.sample", build: "61") == "[rdfeedback:com.example.sample:61]")
        #expect(FeedbackContent.searchTag(bundleID: "com.example.my-app", build: "1.2 beta]\n") == "[rdfeedback:com.example.my-app:1.2beta]")
        #expect(FeedbackContent.searchTag(bundleID: "", build: "3") == nil, "번들 ID를 모르면 표시 줄을 넣지 않는다")
        // 제목이 어느 언어든 표시 줄은 같다.
        let mail = FeedbackMail(recipient: "dev@example.com", content: .standard(info))
        #expect(mail.body.contains("[rdfeedback:com.example.sample:3]"))
        #expect(mail.mailtoURL?.absoluteString.removingPercentEncoding?.contains("[rdfeedback:com.example.sample:3]") == true)
    }

    @Test func deviceTextIsTheKindNeverTheNameAndTheSystemIsNotLocalized() {
        #expect(RemoteDebugFeedback.systemSummary(name: "iOS", version: .init(majorVersion: 18, minorVersion: 1, patchVersion: 0)) == "iOS 18.1")
        #expect(RemoteDebugFeedback.systemSummary(name: "iOS", version: .init(majorVersion: 17, minorVersion: 6, patchVersion: 1)) == "iOS 17.6.1")
        let system = RemoteDebugFeedback.systemSummary
        #expect(system.unicodeScalars.allSatisfy(\.isASCII) && !system.contains("Version"))
        // 모델 식별자나 CPU 종류(`iPhone16,2`, `arm64`)만 나온다. 사용자가 붙인 기기·컴퓨터 이름은 들어가지 않는다.
        let model = RemoteDebugFeedback.deviceModel
        #expect(!model.isEmpty && model.unicodeScalars.allSatisfy { $0.isASCII && $0 != " " })
        var names = [ProcessInfo.processInfo.hostName]
        #if os(macOS)
        names.append(Host.current().localizedName ?? "")
        #endif
        names = names.filter { !$0.isEmpty }
        #expect(!names.contains(model))
        let appInfo = RemoteDebugFeedback.appInfo
        #expect(appInfo.device == model && appInfo.system == system)
        #expect(RemoteDebugFeedback.deviceSummary == "\(model), \(system)")
        for name in names { #expect(!RemoteDebugFeedback.deviceSummary.contains(name)) }
    }

    #if DEBUG
    @Test func feedbackWithoutTextIsSentWhenItCarriesSomethingElse() async throws {
        let none: [FeedbackReport.Check] = [.init(id: "a", title: "t", answer: "", note: "메모만", build: "", answeredAt: "")]
        let answered: [FeedbackReport.Check] = [.init(id: "a", title: "t", answer: "통과", note: "", build: "3", answeredAt: "")]
        #expect(!RemoteDebugFeedback.hasContent(message: "  \n", details: "", hasFiles: false, checks: []))
        #expect(!RemoteDebugFeedback.hasContent(message: "", details: "", hasFiles: false, checks: none), "메모만 적은 것은 답이 아니다")
        #expect(RemoteDebugFeedback.hasContent(message: "", details: "", hasFiles: false, checks: answered))
        #expect(RemoteDebugFeedback.hasContent(message: "", details: "", hasFiles: true, checks: []))
        #expect(RemoteDebugFeedback.hasContent(message: "", details: "\n최근 로그\n줄", hasFiles: false, checks: []))
        #expect(RemoteDebugFeedback.hasContent(message: "느려요", details: "", hasFiles: false, checks: []))

        // 글이 비면 첫 줄에 표시를 적어, Mac이 빈 본문으로 거절하지 않고 읽는 쪽이 잘린 글로 보지 않는다.
        var report = RemoteDebugFeedback.report(message: "", details: "", date: Date(timeIntervalSince1970: 1_794_478_500))
        report.checks = answered
        #expect(report.text.hasPrefix("\(RemoteDebugFeedback.emptyMessageMark)\n\n---\n앱: "))
        #expect(report.text.contains("\n기기: \(RemoteDebugFeedback.deviceSummary)\n"))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rdempty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sent = Sent()
        let client = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: folder) { request in
            sent.body = request.httpBody
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await client.submit(report))
        let body = try #require(sent.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((object["text"] as? String)?.hasPrefix(RemoteDebugFeedback.emptyMessageMark) == true)
        #expect((object["checks"] as? [[String: String]])?.first?["answer"] == "통과")
    }

    @Test @MainActor func defaultChoicesTellUntestedFromFailedAndForgotten() throws {
        #expect(FeedbackCheckItem.defaultChoices == ["통과", "실패", "확인 못함"])
        #expect(FeedbackCheckItem("a", "t").choices == FeedbackCheckItem.defaultChoices)
        let decoded = try JSONDecoder().decode(FeedbackCheckItem.self, from: Data(#"{"id":"a","title":"t"}"#.utf8))
        #expect(decoded.choices == FeedbackCheckItem.defaultChoices)
        // 에이전트가 정한 답은 그대로 쓴다.
        let custom = try JSONDecoder().decode(FeedbackCheckItem.self, from: Data(#"{"id":"c","title":"t","choices":["보임","안 보임"]}"#.utf8))
        #expect(custom.bounded.choices == ["보임", "안 보임"])

        let items = [FeedbackCheckItem("a", "하나", stage: "앞"), FeedbackCheckItem("b", "둘", stage: "앞"), custom,
                     FeedbackCheckItem("d", "넷", stage: "뒤")]
        let store = FeedbackCheckStore(directory: nil, build: "3", declared: items)
        store.choose("확인 못함", for: items[0])
        store.choose("실패", for: items[1])
        store.choose("안 보임", for: items[2])
        #expect(store.unansweredCount == 1, "확인 못함도 답이다. 잊은 것만 남는다")
        #expect(store.mailChecks.map(\.answer) == [.untested, .failed, .failed, .unchecked])
        #expect(store.reportChecks.map(\.answer) == ["확인 못함", "실패", "안 보임", ""])
    }

    @Test @MainActor func unansweredFilterHidesAnsweredItemsAndResetClearsEverything() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rdfilter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = [FeedbackCheckItem("a", "하나", stage: "앞"), FeedbackCheckItem("b", "둘", stage: "앞"), FeedbackCheckItem("c", "셋", stage: "뒤")]
        let store = FeedbackCheckStore(directory: folder, build: "3", declared: items)
        store.choose("통과", for: items[0])
        store.setNote("메모만", for: items[1])
        store.choose("확인 못함", for: items[2])
        #expect(store.answeredIDs == ["a", "c"], "메모만 적은 것은 답한 것이 아니다")
        let shown = store.stages(hiding: store.answeredIDs)
        #expect(shown.map(\.title) == ["앞"] && shown[0].items.map(\.id) == ["b"], "항목이 남지 않은 묶음은 보이지 않는다")
        #expect(store.stages.flatMap(\.items).map(\.id) == ["a", "b", "c"])

        store.reset()
        #expect(store.answers.isEmpty && store.unansweredCount == 3 && store.answeredIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("answers.json").path), "지운 답은 파일에도 남지 않는다")
        #expect(FeedbackCheckStore(directory: folder, build: "3", declared: items).answers.isEmpty)
    }
    #endif
}

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var body: Data? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
