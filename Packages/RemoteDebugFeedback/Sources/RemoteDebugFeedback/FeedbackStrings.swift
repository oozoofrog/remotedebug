import Foundation

/// 패키지의 기본 문구를 기기 언어에 맞춰 꺼낸다. 문구는 이 패키지 묶음의 문자열 카탈로그(`Localizable.xcstrings`)에 있고,
/// 한국어·영어·일본어·중국어 간체·중국어 번체가 들어 있다. 그 밖의 언어는 영어로 보인다.
///
/// 앱의 묶음이 아니라 패키지 묶음(`Bundle.module`)에서 읽고, 언어는 사용자가 정한 언어 차례(`Locale.preferredLanguages`,
/// 앱별 언어 설정 포함)에서 고른다. 그래서 앱 자체가 그 언어로 번역돼 있지 않아도 패키지 문구는 기기 언어를 따른다.
/// UserDefaults를 직접 읽지 않으므로 개인정보 매니페스트에 적을 API가 늘지 않는다.
///
/// 여기에 없는 것: 개발 빌드 전용 문구(`FeedbackDebugStrings`, 배포판 묶음에 들어가지 않게 코드에 둔다)와,
/// 언어에 따라 바뀌면 안 되는 줄(메일 본문의 `App:`·`OS:`·`Device:`·`[rdfeedback:…]`, Mac으로 보내는 기록의 글).
enum FeedbackStrings {
    /// 카탈로그의 키. 시험이 이 목록으로 모든 언어에 문구가 있는지 본다.
    enum Key: String, CaseIterable, Sendable {
        case mailTitle = "mail.title"
        case mailWrite = "mail.write"
        case mailCollecting = "mail.collecting"
        case mailAttach = "mail.attach"
        case mailShare = "mail.share"
        case mailCopyAddress = "mail.copyAddress"
        case mailCopied = "mail.copied"
        case mailUnavailable = "mail.unavailable"
        case mailSeparateAttachment = "mail.separateAttachment"
        case mailCollectionFailed = "mail.collectionFailed"
        case mailSeparateFiles = "mail.separateFiles"
        case mailShareFailed = "mail.shareFailed"
        case mailAttachmentNotice = "mail.attachmentNotice"
        case mailUsageNotice = "mail.usageNotice"
        case mailHandedOff = "mail.handedOff"
        case mailSavedDraft = "mail.savedDraft"
        case mailFailed = "mail.failed"
        case mailChecklist = "mail.checklist"
        case mailUnchecked = "mail.unchecked"
        case mailPassed = "mail.passed"
        case mailFailedCheck = "mail.failedCheck"
        case mailUntested = "mail.untested"
        case mailNote = "mail.note"
        /// 메일 제목. `%@`는 앱 이름.
        case mailSubject = "mail.subject"

        case sheetTitle = "sheet.title"
        case sheetPrompt = "sheet.prompt"
        case sheetAttachments = "sheet.attachments"
        case sheetAttachPhoto = "sheet.attachPhoto"
        case sheetAttachFile = "sheet.attachFile"
        case sheetRemoveAttachment = "sheet.removeAttachment"
        /// `%1$lld` 붙일 수 있는 수, `%2$@` 파일 하나의 한도(MB), `%3$@` 합계 한도(MB).
        case sheetAttachmentLimits = "sheet.attachmentLimits"
        /// `%lld` 붙일 수 있는 수.
        case sheetTooManyAttachments = "sheet.tooManyAttachments"
        /// `%@` 파일 하나의 한도(MB).
        case sheetAttachmentTooLarge = "sheet.attachmentTooLarge"
        /// `%@` 합계 한도(MB).
        case sheetAttachmentsTooLarge = "sheet.attachmentsTooLarge"
        case sheetAttachmentUnreadable = "sheet.attachmentUnreadable"
        case sheetIncludeLogs = "sheet.includeLogs"
        case sheetSend = "sheet.send"
        case sheetClose = "sheet.close"
        case sheetDisclosure = "sheet.disclosure"
        case sheetNotConfigured = "sheet.notConfigured"
        case sheetCollectingLogs = "sheet.collectingLogs"
        case sheetPreparingMail = "sheet.preparingMail"
        case sheetSent = "sheet.sent"

        case consentToggle = "consent.toggle"
        case consentFooter = "consent.footer"
        case consentAgreeTitle = "consent.agreeTitle"
        /// `%1$lld` 메모리에 두는 줄 수, `%2$@` 로그를 붙이는 스위치의 이름, `%3$@` 시스템 로그를 모으는 분.
        case consentExplanation = "consent.explanation"
        case consentAgree = "consent.agree"
        case consentCancel = "consent.cancel"
    }

    /// 카탈로그에 들어 있는 언어. 맞는 언어가 없으면 첫째(영어)를 쓴다.
    static let languages = ["en", "ko", "ja", "zh-Hans", "zh-Hant"]

    /// 시험에서 언어를 정해 놓고 문구를 꺼낼 때 쓴다. 앱에서는 언제나 `nil`이다.
    @TaskLocal static var forcedLanguage: String?

    /// 사용자의 언어 차례에서 카탈로그에 있는 언어를 고른다(`zh-TW` → `zh-Hant`, `ko-KR` → `ko`).
    static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: languages, forPreferences: preferences)
            .first { languages.contains($0) } ?? languages[0]
    }

    /// 지금 쓸 언어.
    static var language: String { forcedLanguage ?? language(for: Locale.preferredLanguages) }

    /// 그 언어의 문구가 든 `.lproj` 묶음.
    static func bundle(for language: String) -> Bundle? {
        Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// 지금 언어의 문구. `arguments`가 있으면 자리표시에 채우고, 언어에 단수·복수가 있으면 첫 정수 값에 맞춘다.
    static func text(_ key: Key, _ arguments: CVarArg...) -> String {
        text(key, language: language, arguments: arguments)
    }

    static func text(_ key: Key, language: String, arguments: [CVarArg] = []) -> String {
        let format = format(key.rawValue, language: language) ?? format(key.rawValue, language: languages[0]) ?? key.rawValue
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }

    private static func format(_ key: String, language: String) -> String? {
        // 없는 키는 이 값이 그대로 돌아온다. 문구에는 쓰이지 않는 글자다.
        let missing = "\u{1}"
        guard let found = bundle(for: language)?.localizedString(forKey: key, value: missing, table: nil), found != missing else { return nil }
        return found
    }

    /// 바이트 한도를 문구에 넣을 MB 숫자로 적는다(`1`, `1.5`). 소수점은 그 언어의 표기를 따른다.
    static func megabytes(_ bytes: Int, language: String = FeedbackStrings.language) -> String {
        (Double(bytes) / Double(1 << 20)).formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: language)))
    }
}
