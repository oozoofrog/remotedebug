import RemoteDebugFeedback
import SwiftUI

// RemoteDebugFeedback 패키지를 실기기에서 확인하는 예제 앱이다.
// 화면의 글은 번역하지 않고 한국어 그대로 둔다(String Catalog를 쓰지 않는다).

@main
struct FeedbackSampleApp: App {
    init() {
        SampleSetup.start()
        RemoteDebugFeedback.log("앱 시작")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Mac 주소, 공개키, 메일 주소는 소스에 적지 않는다. 빌드 설정(`Config/Signing.local.xcconfig`의
/// `RD_FEEDBACK_MAC_HOST`, `RD_FEEDBACK_PUBLIC_KEY`, `RD_FEEDBACK_EMAIL`)이 Info.plist에 넣은 값을 읽는다.
enum SampleSetup {
    /// Info.plist의 글자 값. 없거나 비었으면 `nil`.
    static func value(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var email: String? { value("RDFeedbackEmail") }
    static var publicKey: String? { value("RDFeedbackPublicKey") }

    /// Mac 앱이 주는 코드(`rd feedback`의 snippet)와 같은 모양이다. Mac 주소는 `#if DEBUG` 안에서만 읽는다.
    /// 배포 구성에서는 Info.plist의 `RDFeedbackMacHost`도 비어 있다(프로젝트의 `RD_SAMPLE_MAC_HOST`).
    static func start() {
        #if DEBUG
        RemoteDebugFeedback.start(.init(
            macHost: value("RDFeedbackMacHost"),
            email: email,
            publicKeyBase64: publicKey
        ))
        // 코드로 정해 두는 확인 목록. Mac에서 에이전트가 이 앱의 목록을 남기면 그것이 대신 보인다.
        RemoteDebugFeedback.checklist = [
            .init("sample.sheet", "피드백 화면이 열린다", at: "첫 화면",
                  do: "1. \"피드백 보내기\"를 누른다", expect: ["글 쓰는 칸이 보인다", "\"확인할 것\" 목록이 보인다"],
                  stage: "피드백 화면"),
            .init("sample.attach", "사진을 골라 붙일 수 있다", at: "피드백 화면",
                  do: "1. 사진 붙이기를 누른다\n2. 사진 한 장을 고른다", expect: ["고른 사진이 목록에 보인다", "지울 수 있다"],
                  since: 1, stage: "피드백 화면"),
            .init("sample.consent", "로그 기록 스위치를 켜면 설명이 뜬다", at: "첫 화면 › 설정",
                  do: "1. \"문제 해결용 로그 기록\" 스위치를 켠다", expect: ["무엇을 남기는지 설명이 보인다"],
                  choices: ["보임", "안 보임", "확인 못함"], stage: "설정"),
        ]
        #else
        // 배포판: Mac 주소를 넣지 않는다. 사용자가 쓴 글을 메일 앱으로 보낸다.
        RemoteDebugFeedback.start(.init(email: email, publicKeyBase64: publicKey))
        #endif
    }

    /// 지금 빌드가 피드백을 보내는 곳. 화면에 그대로 보인다.
    static var route: String {
        #if DEBUG
        let host = value("RDFeedbackMacHost")
        switch (host, email) {
        case (.some, .some): return "Mac으로 바로, 닿지 않으면 메일"
        case (.some, .none): return "Mac으로 바로"
        case (.none, .some): return "메일(Mac 주소가 없다)"
        case (.none, .none): return "없음"
        }
        #else
        return email == nil ? "없음" : "메일"
        #endif
    }

    static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }
}
