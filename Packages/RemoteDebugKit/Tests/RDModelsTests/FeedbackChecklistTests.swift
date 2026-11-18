import Foundation
import Testing
@testable import RDModels

/// docs/protocol-addenda.md L.4: 에이전트가 남기는 확인 목록과, 피드백에 함께 오는 답(`checks`).
@Suite struct FeedbackChecklistTests {
    private let now = Date(timeIntervalSince1970: 1_794_478_500)

    private func make(_ items: Any, bundleId: String = "com.example.app") throws(FeedbackChecklist.Invalid) -> FeedbackChecklist {
        let json = JSONSerialization.isValidJSONObject(items) ? (try? JSONSerialization.data(withJSONObject: items)) ?? Data() : Data("\"nope\"".utf8)
        return try FeedbackChecklist.make(bundleId: bundleId, json: json, now: now)
    }

    @Test func acceptsItemsAndFillsDefaults() throws {
        let list = try make([
            ["id": "pay.sheet", "title": " 결제 화면이 열린다 ", "place": "설정 › 결제", "steps": "1. 결제를 누른다", "expect": ["금액이 보임"],
             "choices": ["보임", "안 보임", "모르겠음"], "since": 59, "stage": "결제"],
            ["id": "launch", "title": "앱이 켜진다", "since": 0],
        ])
        #expect(list.bundleId == "com.example.app" && list.updatedAt == now && list.items.count == 2)
        #expect(list.items[0].title == "결제 화면이 열린다" && list.items[0].choices == ["보임", "안 보임", "모르겠음"] && list.items[0].since == 59)
        #expect(list.items[1].choices == FeedbackChecklist.defaultChoices && list.items[1].since == nil && list.items[1].expect.isEmpty)
        // {"items": […]} 모양도 받는다.
        #expect(try make(["items": [["id": "a", "title": "하나"]]]).items.map(\.id) == ["a"])
        // 저장한 모양이 다시 읽힌다.
        let decoded = try RDJSON.decoder().decode(FeedbackChecklist.self, from: RDJSON.encoder().encode(list))
        #expect(decoded.items == list.items)
    }

    @Test func refusesWhatIsOutOfBounds() {
        let item: [String: Any] = ["id": "a", "title": "하나"]
        func invalid(_ items: Any, bundleId: String = "com.example.app") -> Bool {
            do throws(FeedbackChecklist.Invalid) { _ = try make(items, bundleId: bundleId); return false } catch { return !error.message.isEmpty }
        }
        #expect(invalid([]))
        #expect(invalid("nope"))
        #expect(invalid([item], bundleId: "../etc"))
        #expect(invalid([item], bundleId: ""))
        #expect(invalid((0...FeedbackChecklist.maxItems).map { ["id": "i\($0)", "title": "t"] }))
        #expect(!invalid((0..<FeedbackChecklist.maxItems).map { ["id": "i\($0)", "title": "t"] }))
        #expect(invalid([item, item]), "id가 겹친다")
        #expect(invalid([["title": "id 없음"]]))
        #expect(invalid([["id": "a"]]))
        #expect(invalid([["id": "a b/c", "title": "t"]]))
        #expect(invalid([["id": String(repeating: "a", count: FeedbackChecklist.maxIDLength + 1), "title": "t"]]))
        #expect(invalid([["id": "a", "title": String(repeating: "가", count: FeedbackChecklist.maxTitleLength + 1)]]))
        #expect(invalid([["id": "a", "title": "t", "steps": String(repeating: "가", count: FeedbackChecklist.maxStepsLength + 1)]]))
        #expect(invalid([["id": "a", "title": "t", "expect": Array(repeating: "e", count: FeedbackChecklist.maxExpect + 1)]]))
        #expect(invalid([["id": "a", "title": "t", "choices": ["하나"]]]))
        #expect(invalid([["id": "a", "title": "t", "choices": ["같음", "같음"]]]))
        #expect(invalid([["id": "a", "title": "t", "choices": (0...FeedbackChecklist.maxChoices).map { "c\($0)" }]]))
        #expect(invalid([["id": "a", "title": "t", "choices": ["좋음", String(repeating: "가", count: FeedbackChecklist.maxChoiceLength + 1)]]]))
        #expect(invalid([["id": "a", "title": "t", "since": -1]]))
        #expect(invalid([["id": "a", "title": "t", "since": "59"]]))
        #expect(invalid([["id": "a", "title": 3]]))
    }

    @Test func bundleIDsAreSafeFileNames() {
        #expect(FeedbackChecklist.isValidBundleID("com.example.app-dev"))
        for bad in ["", ".hidden", "a/b", "a b", "한글", String(repeating: "a", count: 256)] {
            #expect(!FeedbackChecklist.isValidBundleID(bad))
        }
        let file = FeedbackChecklist.file(bundleId: "com.example.app", publishDirectory: "/state/Published")
        #expect(file.path == "/state/FeedbackChecklists/com.example.app.json")
    }

    @Test func checksTravelWithTheReportAndOldShapesStillDecode() throws {
        var report = CrashReport.feedback(message: "느려요", bundleId: "com.example.app", appVersion: "1.0", date: now)
        #expect(try (JSONSerialization.jsonObject(with: RDJSON.encoder().encode(report)) as? [String: Any])?["checks"] == nil)
        report.checks = [.init(id: "pay.sheet", title: "결제 화면이 열린다", answer: "보임", note: "조금 늦게 뜸", build: "59", answeredAt: "2026-11-13T05:05:01.000Z"),
                         .init(id: "launch", title: "앱이 켜진다")]
        let data = try RDJSON.encoder().encode(report)
        #expect(try RDJSON.decoder().decode(CrashReport.self, from: data).checks == report.checks)
        // 필드가 빠진 답도 읽힌다.
        let sparse = #"{"kind":"feedback","crashedAt":"2026-11-13T05:05:01.000Z","text":"x","checks":[{"id":"a"}]}"#
        #expect(try RDJSON.decoder().decode(CrashReport.self, from: Data(sparse.utf8)).checks == [.init(id: "a", title: "")])

        let text = CrashReport.checksText(report.checks)
        #expect(text.hasPrefix("확인 목록의 답 (1/2개 답함)"))
        #expect(text.contains("- [보임] pay.sheet: 결제 화면이 열린다 (빌드 59, 2026-11-13T05:05:01.000Z)\n  메모: 조금 늦게 뜸"))
        #expect(text.contains("- [답 없음] launch: 앱이 켜진다"))
        #expect(CrashReport.checksText([]).isEmpty)
    }
}
