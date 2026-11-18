// swift-tools-version: 6.0
import PackageDescription

// 다른 앱이 이 저장소 주소로 추가하는 패키지. RemoteDebug로 설치하는 Debug 빌드가
// 자기 크래시 기록과 피드백을 Mac에 보내게 한다. RemoteDebug 앱 자체는 RemoteDebug.xcodeproj로 빌드한다.
let package = Package(
    name: "RemoteDebugFeedback",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RemoteDebugFeedback", targets: ["RemoteDebugFeedback"]),
    ],
    targets: [
        // 개인정보 매니페스트는 리소스로 넣어야 앱의 개인정보 보고서에 잡힌다. README.md는 소스 폴더 밖에 있다.
        .target(name: "RemoteDebugFeedback", path: "Packages/RemoteDebugFeedback/Sources/RemoteDebugFeedback",
                resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "RemoteDebugFeedbackTests", dependencies: ["RemoteDebugFeedback"],
                    path: "Packages/RemoteDebugFeedback/Tests/RemoteDebugFeedbackTests"),
    ]
)
