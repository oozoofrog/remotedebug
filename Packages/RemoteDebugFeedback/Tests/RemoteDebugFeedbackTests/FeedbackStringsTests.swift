import Foundation
import Testing
@testable import RemoteDebugFeedback

/// 기본 문구의 번역: 다섯 언어에 모두 있는지, 언어 고르기, 영어의 단수·복수, 언어가 달라도 같아야 하는 줄, 앱이 넣은 문구.
struct FeedbackStringsTests {
    private let languages = ["en", "ko", "ja", "zh-Hans", "zh-Hant"]
    private let info = FeedbackAppInfo(name: "Sample", version: "1.2", build: "3", system: "iOS 18.1", device: "iPhone16,2",
                                       bundleID: "com.example.sample")

    /// 저장소에 있는 카탈로그 원본.
    private func catalog() throws -> (text: String, strings: [String: Any]) {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/RemoteDebugFeedback/Localizable.xcstrings").standardizedFileURL
        let data = try Data(contentsOf: file)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (String(decoding: data, as: UTF8.self), try #require(root["strings"] as? [String: Any]))
    }

    private func strings(in value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap { $0.value as? String }
    }

    @Test func packageBundleHasEveryLanguageAndEveryKey() throws {
        #expect(FeedbackStrings.languages == languages)
        for language in languages {
            // 실행 중인 언어에 기대지 않고 묶음의 .lproj를 직접 연다.
            let bundle = try #require(FeedbackStrings.bundle(for: language), "\(language).lproj가 패키지 묶음에 없다")
            for key in FeedbackStrings.Key.allCases {
                let found = bundle.localizedString(forKey: key.rawValue, value: "\u{1}", table: nil)
                #expect(found != "\u{1}" && !found.isEmpty && found != key.rawValue, "\(language) \(key.rawValue)")
            }
        }
    }

    @Test func catalogSourceIsCompleteAndMatchesTheKeys() throws {
        let strings = try catalog().strings
        #expect(Set(strings.keys) == Set(FeedbackStrings.Key.allCases.map(\.rawValue)))
        for (key, value) in strings {
            let localizations = try #require((value as? [String: Any])?["localizations"] as? [String: Any])
            #expect(Set(localizations.keys) == Set(languages), "\(key)")
        }
        // 살펴봐야 한다는 표시나 새로 뽑힌 채 남은 문구가 없다.
        let text = try catalog().text
        #expect(!text.contains("needs_review") && !text.contains("\"new\"") && !text.contains("\"stale\""))
    }

    @Test func labelDefaultsResolveInEveryLanguage() {
        var titles: Set<String> = []
        for language in languages {
            FeedbackStrings.$forcedLanguage.withValue(language) {
                var all = strings(in: FeedbackLabels())
                #expect(all.count == 23)
                #if canImport(SwiftUI)
                let consent = strings(in: RemoteDebugFeedbackConsentLabels())
                #expect(consent.count == 6)
                all += consent
                #endif
                #if os(iOS) && !targetEnvironment(macCatalyst)
                all += strings(in: RemoteDebugFeedbackLabels())
                #endif
                for text in all {
                    #expect(!text.isEmpty && !text.contains("%") && FeedbackStrings.Key(rawValue: text) == nil, "\(language): \(text)")
                }
                titles.insert(FeedbackLabels().title)
                #expect(FeedbackContent.defaultUsageNotice == FeedbackLabels().usageNotice)
            }
        }
        #expect(titles.count == languages.count, "언어마다 다른 문구가 나온다")
        #expect(FeedbackStrings.$forcedLanguage.withValue("ko") { FeedbackLabels().copied } == "메일 주소를 복사했습니다.")
    }

    /// 화면 문구(`RemoteDebugFeedbackLabels`)는 iOS에서만 컴파일되므로, 그 기본값이 쓰는 키와 값을 여기서 그대로 꺼내 본다.
    @Test func sheetTextFillsCountsAndSizesInEveryLanguage() {
        let one = FeedbackStrings.megabytes(FeedbackFiles.maxBytes, language: "en")
        let total = FeedbackStrings.megabytes(FeedbackFiles.maxTotalBytes, language: "en")
        #expect(one == "1" && total == "1.5")
        for language in languages {
            let limits = FeedbackStrings.text(.sheetAttachmentLimits, language: language, arguments: [FeedbackFiles.maxCount, one, total])
            #expect(limits.contains("5") && limits.contains("1.5") && !limits.contains("%") && !limits.contains("$"), "\(language): \(limits)")
            let many = FeedbackStrings.text(.sheetTooManyAttachments, language: language, arguments: [FeedbackFiles.maxCount])
            #expect(many.contains("5") && !many.contains("%"), "\(language): \(many)")
            for key in [FeedbackStrings.Key.sheetAttachmentTooLarge, .sheetAttachmentsTooLarge] {
                let text = FeedbackStrings.text(key, language: language, arguments: [total])
                #expect(text.contains("1.5") && !text.contains("%"), "\(language): \(text)")
            }
            let label = FeedbackStrings.text(.sheetIncludeLogs, language: language)
            let consent = FeedbackStrings.text(.consentExplanation, language: language, arguments: [FeedbackLog.limit, label, "15"])
            #expect(consent.contains("500") && consent.contains(label) && consent.contains("15") && !consent.contains("%"), "\(language): \(consent)")
            #expect(FeedbackStrings.text(.mailSubject, language: language, arguments: ["Sample"]).hasPrefix("Sample "))
        }
        // 한국어는 번역을 넣기 전의 문구 그대로다.
        #expect(FeedbackStrings.text(.sheetAttachmentLimits, language: "ko", arguments: [5, "1", "1.5"])
            == "사진과 파일을 5개까지 붙일 수 있습니다. 파일 하나는 1MB, 모두 합쳐 1.5MB까지이고 사진은 크기를 줄여 붙입니다.")
        #expect(FeedbackStrings.text(.sheetTooManyAttachments, language: "ko", arguments: [5]) == "첨부는 5개까지 붙일 수 있습니다.")
    }

    @Test func englishPicksSingularAndPlural() {
        #expect(FeedbackStrings.text(.sheetTooManyAttachments, language: "en", arguments: [1]) == "You can attach only 1 item.")
        #expect(FeedbackStrings.text(.sheetTooManyAttachments, language: "en", arguments: [5]) == "You can attach up to 5 items.")
        #expect(FeedbackStrings.text(.sheetAttachmentLimits, language: "en", arguments: [1, "1", "1.5"])
            == "You can attach 1 photo or file of up to 1 MB. Photos are made smaller before they are attached.")
        #expect(FeedbackStrings.text(.sheetAttachmentLimits, language: "en", arguments: [5, "1", "1.5"])
            == "You can attach up to 5 photos and files. Each file can be up to 1 MB and all of them together up to 1.5 MB. Photos are made smaller before they are attached.")
        #expect(FeedbackStrings.text(.consentExplanation, language: "en", arguments: [1, "Attach Recent Logs", "15"]).contains("the most recent 1 line, in"))
        #expect(FeedbackStrings.text(.consentExplanation, language: "en", arguments: [500, "Attach Recent Logs", "15"])
            .contains("the most recent 500 lines, in"))
    }

    @Test func languageFollowsTheUsersOrderAndFallsBackToEnglish() {
        #expect(FeedbackStrings.language(for: ["ko-KR", "en-US"]) == "ko")
        #expect(FeedbackStrings.language(for: ["ja-JP"]) == "ja")
        #expect(FeedbackStrings.language(for: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(FeedbackStrings.language(for: ["zh-CN"]) == "zh-Hans")
        #expect(FeedbackStrings.language(for: ["zh-TW"]) == "zh-Hant")
        #expect(FeedbackStrings.language(for: ["zh-Hant-HK"]) == "zh-Hant")
        #expect(FeedbackStrings.language(for: ["en-GB"]) == "en")
        #expect(FeedbackStrings.language(for: ["fr-FR", "ko-KR"]) == "ko", "앞 언어가 없으면 다음 언어를 본다")
        #expect(FeedbackStrings.language(for: ["fr-FR"]) == "en")
        #expect(FeedbackStrings.language(for: []) == "en")
        #expect(FeedbackStrings.text(.sheetSend, language: "fr") == "Send", "없는 언어는 영어로 보인다")
    }

    @Test func fixedMailLinesAreTheSameBytesInEveryLanguage() {
        let fixed = "App: Sample 1.2 (3)\nOS: iOS 18.1\nDevice: iPhone16,2\n[rdfeedback:com.example.sample:3]"
        var subjects: Set<String> = [], bodies: Set<String> = []
        for language in languages {
            let content = FeedbackStrings.$forcedLanguage.withValue(language) { FeedbackContent.standard(info) }
            subjects.insert(content.subject)
            bodies.insert(content.body)
            #expect(Data(content.body.utf8).suffix(fixed.utf8.count) == Data(fixed.utf8), "\(language)")
            #expect(content.body.hasPrefix("\n\n\n---\n"))
            #expect(content.body.split(separator: "\n").count == 6, "안내 줄 하나와 정해진 줄 넷")
        }
        #expect(subjects.count == languages.count && bodies.count == languages.count)
        #expect(Set(languages.map { _ in FeedbackContent.searchTag(bundleID: info.bundleID, build: info.build) ?? "" }).count == 1)
    }

    @Test @MainActor func textTheAppSuppliesWinsOverTheDeviceLanguage() async {
        await FeedbackStrings.$forcedLanguage.withValue("ja") {
            var labels = FeedbackLabels()
            labels.usageNotice = "Only for this problem."
            labels.attachmentNotice = "Diagnostics are attached."
            labels.handedOff = "Passed to Mail."
            #expect(labels.copied == "メールアドレスをコピーしました。", "바꾸지 않은 문구는 기기 언어를 따른다")
            let content = FeedbackContent.standard(info, message: "", usageNotice: labels.usageNotice)
            #expect(content.body.hasPrefix("\n\n\n---\nOnly for this problem.\nApp: Sample 1.2 (3)\n"))
            let session = FeedbackSession(recipient: "feedback@example.com", appInfo: info, labels: labels)
            _ = await session.prepare(canSendMail: true)
            session.finish(.handedOff)
            #expect(session.status == "Passed to Mail.")
            let mail = FeedbackMail(recipient: "feedback@example.com", content: content, attachmentNotice: labels.attachmentNotice)
            #expect(mail.attachmentNotice == "Diagnostics are attached.")
            #if canImport(SwiftUI)
            var consent = RemoteDebugFeedbackConsentLabels()
            consent.explanation = "Screen names and error codes only."
            #expect(consent.explanation == "Screen names and error codes only." && consent.agree == "同意してオンにする")
            #endif
        }
    }

    /// 배포판 묶음에 들어가는 카탈로그에는 개발 빌드 전용 문구와 이름이 없어야 한다.
    /// 아래 목록은 `scripts/check-feedback-release.sh`의 `markers`와 같다.
    @Test func catalogCarriesNoDebugOnlyMarker() throws {
        let text = try catalog().text
        let markers = ["FeedbackCheckStore", "FeedbackCheckItem", "FeedbackCheckRow", "RemoteDebugFeedbackChecks", "/v1/feedback/checklist/",
                       "FeedbackClient", "FeedbackReport", "개발자의 Mac으로 보내는 중", "지금은 개발자의 Mac에 닿지 않습니다",
                       "저장하고 나중에 보내기", "답하지 않은 것만 보기"]
        for marker in markers { #expect(!text.contains(marker), "\(marker)") }
        #expect(!text.contains("ts.net") && !text.contains("rd-mac-"))
        #if DEBUG
        // 그 문구는 개발 빌드의 코드에 있고, 스크립트가 찾는 한국어 표시도 거기에 그대로 있다.
        let debug = FeedbackDebugStrings.table.values.flatMap { $0 }
        for marker in markers.suffix(4) { #expect(debug.contains { $0.contains(marker) }, "\(marker)") }
        #endif
    }

    #if DEBUG
    @Test func debugOnlyTextHasEveryLanguage() {
        for key in FeedbackDebugStrings.Key.allCases {
            let values = FeedbackDebugStrings.table[key] ?? []
            #expect(values.count == languages.count && values.allSatisfy { !$0.isEmpty }, "\(key)")
        }
        #expect(FeedbackDebugStrings.text(.sendLater, language: "ko") == "저장하고 나중에 보내기")
        #expect(FeedbackDebugStrings.text(.sendLater, language: "en") == "Save and Send Later")
        #expect(FeedbackDebugStrings.text(.sendLater, language: "fr") == "Save and Send Later")
        #expect(FeedbackDebugStrings.text(.staleAnswerLine, language: "en", arguments: ["Earlier answer", "Passed", "58"]) == "Earlier answer: Passed (58)")
        #expect(FeedbackDebugStrings.text(.staleAnswerLine, language: "ja", arguments: ["前の回答", "合格", "58"]) == "前の回答：合格（58）")
    }

    /// Mac으로 가는 기록의 글은 Mac 앱이 글자 그대로 읽으므로 기기 언어와 상관없이 같다.
    @Test func reportTextToTheMacIsTheSameBytesInEveryLanguage() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let file = FeedbackFile(name: "note.txt", type: "text/plain", data: Data("a".utf8))
        var texts: Set<Data> = []
        for language in languages {
            FeedbackStrings.$forcedLanguage.withValue(language) {
                let report = RemoteDebugFeedback.report(message: "", details: "\n최근 로그\n줄", attachments: [file], date: date)
                texts.insert(Data(report.text.utf8))
                #expect(report.text.hasPrefix("(글 없이 보냄)\n\n---\n앱: "))
                #expect(report.text.contains("\n기기: ") && report.text.contains("\n보낸 시각: ") && report.text.contains("\n첨부: note.txt\n"))
                #expect(RemoteDebugFeedback.emptyMessageMark == "(글 없이 보냄)")
            }
        }
        #expect(texts.count == 1)
    }

    /// 기본 답은 저장하고 보내는 값이 언어와 상관없이 같고, 화면에 보이는 이름만 바뀐다.
    @Test @MainActor func defaultChoicesKeepTheirStoredValueAndOnlyTheShownNameFollowsTheLanguage() {
        let item = FeedbackCheckItem("launch", "앱이 켜진다")
        let custom = FeedbackCheckItem("sound", "소리가 난다", choices: ["들림", "안 들림", "확인 못함"])
        for language in languages {
            FeedbackStrings.$forcedLanguage.withValue(language) {
                #expect(FeedbackCheckItem.defaultChoices == ["통과", "실패", "확인 못함"] && FeedbackCheckItem.untestedChoice == "확인 못함")
                let store = FeedbackCheckStore(directory: nil, build: "7", declared: [item, custom])
                store.choose("통과", for: item)
                store.choose("확인 못함", for: custom)
                #expect(store.reportChecks.map(\.answer) == ["통과", "확인 못함"])
                #expect(store.mailChecks.map(\.answer) == [.passed, .untested] && store.mailChecks.map(\.choice) == ["통과", "확인 못함"])
                let labels = FeedbackLabels()
                #expect(FeedbackCheckItem.displayName(for: "통과", labels: labels) == labels.passed)
                #expect(FeedbackCheckItem.displayName(for: "실패", labels: labels) == labels.failedCheck)
                #expect(FeedbackCheckItem.displayName(for: "확인 못함", labels: labels) == labels.untested)
                #expect(FeedbackCheckItem.displayName(for: "들림", labels: labels) == "들림", "목록이 정한 답은 적힌 그대로 보인다")
            }
        }
        #expect(FeedbackStrings.$forcedLanguage.withValue("en") { FeedbackCheckItem.displayName(for: "통과", labels: FeedbackLabels()) } == "Passed")
        #expect(FeedbackStrings.$forcedLanguage.withValue("ko") { FeedbackCheckItem.displayName(for: "확인 못함", labels: FeedbackLabels()) } == "확인 못함")
        var labels = FeedbackLabels()
        labels.passed = "OK"
        #expect(FeedbackCheckItem.displayName(for: "통과", labels: labels) == "OK", "앱이 넣은 이름이 이긴다")
    }
    #endif
}
