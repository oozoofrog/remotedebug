#if DEBUG
import Foundation
import Testing
@testable import RemoteDebugFeedback

/// 개발 빌드의 확인 목록: 답 저장, `since`로 답 무르기, 목록이 바뀔 때 답 지우기, Mac에서 받은 목록, 보내는 모양.
@MainActor
struct FeedbackChecklistTests {
    private let declared = [
        FeedbackCheckItem("launch", "앱이 켜진다"),
        FeedbackCheckItem("pay.sheet", "결제 화면이 열린다", at: "설정 › 결제", do: "결제를 누른다", expect: ["금액이 보임"],
                          choices: ["보임", "안 보임", "모르겠음"], since: 59, stage: "결제"),
    ]

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rdchecks-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func answersPersistAndCountUnanswered() {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FeedbackCheckStore(directory: folder, build: "59", declared: declared, now: { Date(timeIntervalSince1970: 1_794_478_500) })
        #expect(store.unansweredCount == 2)
        store.choose("통과", for: declared[0])
        store.setNote("조금 늦게 뜸", for: declared[1])
        store.choose("없는 답", for: declared[1])
        #expect(store.unansweredCount == 1, "메모만 적은 것과 목록에 없는 답은 답이 아니다")
        store.setNote(String(repeating: "가", count: 500), for: declared[0])
        #expect(store.answer(for: declared[0]).note.count == FeedbackCheckStore.noteLimit)

        let reopened = FeedbackCheckStore(directory: folder, build: "59", declared: declared)
        #expect(reopened.answer(for: declared[0]).choice == "통과" && reopened.answer(for: declared[1]).note == "조금 늦게 뜸")
        #expect(reopened.stages.map(\.title) == ["", "결제"])
        reopened.choose(nil, for: declared[0])
        reopened.setNote("", for: declared[0])
        reopened.setNote("", for: declared[1])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("answers.json").path), "답이 없으면 파일도 없다")
    }

    @Test func answersFromBeforeSinceNoLongerCount() {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = FeedbackCheckStore(directory: folder, build: "58", declared: declared)
        old.choose("통과", for: declared[0])
        old.choose("보임", for: declared[1])
        #expect(old.unansweredCount == 1, "58에서 고른 답은 59에서 바뀐 항목에 세지 않는다")
        #expect(old.answer(for: declared[1]).choice == nil && old.staleAnswer(for: declared[1])?.choice == "보임")
        #expect(old.reportChecks.map(\.answer) == ["통과", ""])

        let new = FeedbackCheckStore(directory: folder, build: "59", declared: declared)
        #expect(new.unansweredCount == 1 && new.staleAnswer(for: declared[1])?.build == "58")
        new.choose("안 보임", for: declared[1])
        #expect(new.unansweredCount == 0 && new.staleAnswer(for: declared[1]) == nil)
        #expect(new.reportChecks.last?.build == "59")
    }

    @Test func remoteListOverridesIsCachedAndPrunesAnswers() throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FeedbackCheckStore(directory: folder, build: "59", declared: declared)
        store.choose("통과", for: declared[0])
        store.apply(remote: Data(#"{"bundleId":"com.example.app","updatedAt":"2026-11-13T05:05:01Z","items":[{"id":"launch","title":"앱이 켜진다"},{"id":"new","title":"새 항목","choices":["좋음","나쁨"],"since":60}]}"#.utf8))
        #expect(store.items.map(\.id) == ["launch", "new"])
        #expect(store.answer(for: store.items[0]).choice == "통과", "같은 id의 답은 이어진다")
        store.choose("좋음", for: store.items[1])

        // Mac에 닿지 않아도 마지막으로 받은 목록이 보인다.
        let offline = FeedbackCheckStore(directory: folder, build: "59", declared: declared)
        #expect(offline.items.map(\.id) == ["launch", "new"] && offline.items[1].choices == ["좋음", "나쁨"])
        #expect(offline.staleAnswer(for: offline.items[1])?.choice == "좋음", "60에서 바뀐 항목이라 59의 답은 세지 않는다")

        // 읽을 수 없는 답은 무시하고, 빈 목록이면 코드로 정한 목록으로 돌아가며 없는 항목의 답을 지운다.
        offline.apply(remote: Data("not json".utf8))
        #expect(offline.items.map(\.id) == ["launch", "new"])
        offline.apply(remote: Data(#"{"bundleId":"com.example.app","items":[]}"#.utf8))
        #expect(offline.items.map(\.id) == ["launch", "pay.sheet"])
        #expect(Set(offline.answers.keys) == ["launch"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("checklist.json").path))
        let saved = try JSONDecoder().decode([String: FeedbackCheckStore.Answer].self, from: Data(contentsOf: folder.appendingPathComponent("answers.json")))
        #expect(Set(saved.keys) == ["launch"])
    }

    @Test func listsAreBounded() {
        let many = (0..<80).map { FeedbackCheckItem("i\($0)", String(repeating: "가", count: 500), choices: (0..<9).map { "c\($0)" }) }
        let store = FeedbackCheckStore(directory: nil, build: "1", declared: many + [many[0], FeedbackCheckItem("one", "답 하나", choices: ["하나"])])
        #expect(store.items.count == FeedbackCheckStore.maxItems)
        #expect(store.items[0].title.count == 200 && store.items[0].choices.count == FeedbackCheckStore.maxChoices)
        #expect(FeedbackCheckItem("one", "답 하나", choices: ["하나"]).bounded.choices == FeedbackCheckItem.defaultChoices)
        // Mac이 저장해 주는 가장 큰 목록(256KiB)은 언제나 받을 수 있는 크기다.
        #expect(FeedbackCheckStore.macStoredBytes == 256 << 10 && FeedbackCheckStore.maxResponseBytes >= FeedbackCheckStore.macStoredBytes)
        store.apply(remote: Data(count: FeedbackCheckStore.maxResponseBytes + 1))
        #expect(store.items.count == FeedbackCheckStore.maxItems)
    }

    @Test func checksGoIntoTheReportAndTheMailDiagnostics() throws {
        let store = FeedbackCheckStore(directory: nil, build: "59", declared: declared, now: { Date(timeIntervalSince1970: 1_794_478_500) })
        store.choose("안 보임", for: declared[1])
        store.setNote("빈 화면", for: declared[1])
        var report = RemoteDebugFeedback.report(message: "느려요", details: "", date: Date())
        report.checks = store.reportChecks
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let checks = try #require(object["checks"] as? [[String: String]])
        #expect(checks[0] == ["id": "launch", "title": "앱이 켜진다", "answer": "", "note": "", "build": "", "answeredAt": ""])
        #expect(checks[1]["answer"] == "안 보임" && checks[1]["note"] == "빈 화면" && checks[1]["build"] == "59")
        #expect(checks[1]["answeredAt"]?.hasPrefix("2026-11-") == true)

        let mail = store.mailChecks
        #expect(mail.map(\.answer) == [.unchecked, .failed] && mail[1].choice == "안 보임" && mail[1].note == "빈 화면")
        // 해 보지 못한 것은 실패와도, 답하지 않은 것과도 다르게 간다.
        store.choose(FeedbackCheckItem.untestedChoice, for: declared[0])
        #expect(store.mailChecks[0].answer == .untested && store.reportChecks[0].answer == "확인 못함")
        // 고른 답이 없는 옛 모양도 읽힌다.
        let old = try JSONDecoder().decode(FeedbackCheck.self, from: Data(#"{"id":"a","title":"t","answer":"passed","note":""}"#.utf8))
        #expect(old.choice == nil && old.answer == .passed)
    }

    @Test func fetchAsksTheSameMacForThisAppsList() async throws {
        let seen = Seen()
        let client = FeedbackClient(endpoint: URL(string: "https://rd-mac-1a2b3c4d.tail0001.ts.net/v1/crashes")!, directory: directory()) { request in
            await seen.set(request.url)
            return (Data(#"{"items":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await client.fetchChecklist(bundleID: "com.example.app") == Data(#"{"items":[]}"#.utf8))
        #expect(await seen.url?.absoluteString == "https://rd-mac-1a2b3c4d.tail0001.ts.net/v1/feedback/checklist/com.example.app")
        #expect(await client.fetchChecklist(bundleID: "../x") == nil)
        let unpaired = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: directory()) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await unpaired.fetchChecklist(bundleID: "com.example.app") == nil)
    }
}

private actor Seen {
    var url: URL?
    func set(_ url: URL?) { self.url = url }
}
#endif
