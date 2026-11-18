#if DEBUG
import Foundation

/// 개발 빌드에만 있는 문구(Mac으로 보내는 길, 확인 목록)의 번역.
///
/// 묶음의 문자열 카탈로그에 두지 않고 코드에 둔다. 카탈로그는 리소스라서 구성을 가리지 않고 배포판 묶음에도 들어가는데,
/// 이 문구는 배포판에 있으면 안 되기 때문이다(`scripts/check-feedback-release.sh`가 그 일부를 표시로 찾는다).
/// 언어는 카탈로그 문구와 같은 방법으로 고른다(`FeedbackStrings.language`).
enum FeedbackDebugStrings {
    enum Key: CaseIterable, Sendable {
        case sendingToMac, saving, unreachable, sendByMail, sendLater, saved
        case unansweredOnly, resetChecks, resetChecksConfirm, checklist, checklistFooter, unansweredChecks
        case checkAnswer, noAnswer, checkNote, checkPlace, checkSteps, checkExpect, staleAnswer
        /// 바뀌기 전 답 한 줄. `%1$@` 문구(`staleAnswer`), `%2$@` 고른 답, `%3$@` 빌드 번호.
        case staleAnswerLine
    }

    /// `FeedbackStrings.languages`와 같은 차례: 영어, 한국어, 일본어, 중국어 간체, 중국어 번체.
    static let table: [Key: [String]] = [
        .sendingToMac: ["Sending to the developer's Mac…", "개발자의 Mac으로 보내는 중…", "開発者のMacに送信中…", "正在发送到开发者的 Mac…", "正在傳送到開發者的 Mac…"],
        .saving: ["Saving…", "저장하는 중…", "保存中…", "正在存储…", "正在儲存…"],
        .unreachable: ["The developer's Mac cannot be reached right now.", "지금은 개발자의 Mac에 닿지 않습니다.", "現在、開発者のMacに接続できません。", "目前无法连接到开发者的 Mac。", "目前無法連接到開發者的 Mac。"],
        .sendByMail: ["Send by Email", "메일로 보내기", "メールで送信", "通过邮件发送", "透過郵件傳送"],
        .sendLater: ["Save and Send Later", "저장하고 나중에 보내기", "保存してあとで送信", "存储并稍后发送", "儲存並稍後傳送"],
        .saved: ["Saved. It will be sent when you turn on the VPN in the RemoteDebug app and open this app again.",
                 "저장해 두었습니다. RemoteDebug 앱의 VPN을 켜고 이 앱을 다시 열면 보냅니다.",
                 "保存しました。RemoteDebugアプリのVPNをオンにしてこのアプリを開き直すと送信します。",
                 "已存储。在 RemoteDebug App 中打开 VPN 并重新打开此 App 后会发送。",
                 "已儲存。在 RemoteDebug App 中開啟 VPN 並重新打開此 App 後會傳送。"],
        .unansweredOnly: ["Show Unanswered Only", "답하지 않은 것만 보기", "未回答のみ表示", "仅显示未回答的项目", "僅顯示未回答的項目"],
        .resetChecks: ["Clear All Answers", "답 모두 지우기", "回答をすべて消去", "清除所有回答", "清除所有回答"],
        .resetChecksConfirm: ["Clear all the answers and notes chosen on this device?", "이 기기에서 고른 답과 메모를 모두 지울까요?",
                              "このデバイスで選んだ回答とメモをすべて消去しますか？", "要清除在本设备上选择的所有回答和备注吗？", "要清除在本裝置上選擇的所有回答和備註嗎？"],
        .checklist: ["To Check", "확인할 것", "確認すること", "待确认事项", "待確認事項"],
        .checklistFooter: ["Shown only in development builds. Your answers are sent with your feedback.", "개발 빌드에만 보입니다. 고른 답은 피드백과 함께 갑니다.",
                           "開発ビルドでのみ表示されます。選んだ回答はフィードバックと一緒に送信されます。", "仅在开发版本中显示。所选回答会随反馈一并发送。", "僅在開發版本中顯示。所選回答會隨意見回饋一併傳送。"],
        .unansweredChecks: ["Not Answered Yet", "아직 답하지 않은 것", "未回答", "尚未回答", "尚未回答"],
        .checkAnswer: ["Answer", "답", "回答", "回答", "回答"],
        .noAnswer: ["No Answer", "답 없음", "回答なし", "未回答", "未回答"],
        .checkNote: ["Note (do not include personal information)", "메모(개인 정보는 적지 않습니다)", "メモ（個人情報は書かないでください）", "备注（请勿填写个人信息）", "備註（請勿填寫個人資訊）"],
        .checkPlace: ["Where", "어디서", "場所", "位置", "位置"],
        .checkSteps: ["Steps", "할 일", "手順", "步骤", "步驟"],
        .checkExpect: ["Expected", "보여야 하는 것", "期待される結果", "预期结果", "預期結果"],
        .staleAnswer: ["Answer from a build before the change", "바뀌기 전 빌드에서 고른 답", "変更前のビルドでの回答", "更改前的版本中的回答", "變更前的版本中的回答"],
        .staleAnswerLine: ["%1$@: %2$@ (%3$@)", "%1$@: %2$@ (%3$@)", "%1$@：%2$@（%3$@）", "%1$@：%2$@（%3$@）", "%1$@：%2$@（%3$@）"],
    ]

    static func text(_ key: Key, _ arguments: CVarArg...) -> String {
        text(key, language: FeedbackStrings.language, arguments: arguments)
    }

    static func text(_ key: Key, language: String, arguments: [CVarArg] = []) -> String {
        let values = table[key] ?? []
        let index = FeedbackStrings.languages.firstIndex(of: language) ?? 0
        let format = values.indices.contains(index) ? values[index] : values.first ?? ""
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
}

extension FeedbackCheckItem {
    /// 기본 답을 화면에 보일 때의 이름. 저장하고 Mac에 보내는 값은 언제나 `통과`·`실패`·`확인 못함` 그대로이고,
    /// 화면에서만 `labels`의 문구(기기 언어, 또는 앱이 넣은 값)로 바꿔 보인다. 목록이 따로 정한 답은 적힌 그대로 보인다.
    static func displayName(for choice: String, labels: FeedbackLabels) -> String {
        switch choice {
        case defaultChoices[0]: labels.passed
        case defaultChoices[1]: labels.failedCheck
        case untestedChoice: labels.untested
        default: choice
        }
    }
}
#endif
