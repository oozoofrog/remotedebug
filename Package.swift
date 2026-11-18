// swift-tools-version: 6.0
import PackageDescription

// 다른 앱이 이 저장소 주소로 추가하는 패키지. RemoteDebug로 설치하는 Debug 빌드가
// 자기 크래시 기록과 피드백을 Mac에 보내게 한다. RemoteDebug 앱 자체는 RemoteDebug.xcodeproj로 빌드한다.
let package = Package(
    name: "RemoteDebugFeedback",
    // 카탈로그에 없는 언어의 기기에서는 영어 문구가 보인다.
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RemoteDebugFeedback", targets: ["RemoteDebugFeedback"]),
    ],
    targets: [
        // 개인정보 매니페스트는 리소스로 넣어야 앱의 개인정보 보고서에 잡힌다. README.md는 소스 폴더 밖에 있다.
        // 문자열 카탈로그는 기본 문구의 번역(한국어·영어·일본어·중국어 간체·번체)이고, 언어마다 .lproj로 풀려 묶음에 들어간다.
        .target(name: "RemoteDebugFeedback", path: "Packages/RemoteDebugFeedback/Sources/RemoteDebugFeedback",
                resources: [.copy("PrivacyInfo.xcprivacy"), .process("Localizable.xcstrings")]),
        .testTarget(name: "RemoteDebugFeedbackTests", dependencies: ["RemoteDebugFeedback"],
                    path: "Packages/RemoteDebugFeedback/Tests/RemoteDebugFeedbackTests"),
    ]
)
