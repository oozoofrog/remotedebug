// swift-tools-version: 5.10
import PackageDescription

// 다른 앱이 이 저장소 주소로 추가하는 패키지. RemoteDebug로 설치하는 Debug 빌드가
// 자기 크래시 기록과 피드백을 Mac에 보내게 한다. RemoteDebug 앱 자체는 RemoteDebug.xcodeproj로 빌드한다.
let package = Package(
    name: "RemoteDebugFeedback",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "RemoteDebugFeedback", targets: ["RemoteDebugFeedback"]),
    ],
    targets: [
        .target(name: "RemoteDebugFeedback", path: "Packages/RemoteDebugFeedback/Sources/RemoteDebugFeedback"),
        .testTarget(name: "RemoteDebugFeedbackTests", dependencies: ["RemoteDebugFeedback"],
                    path: "Packages/RemoteDebugFeedback/Tests/RemoteDebugFeedbackTests"),
    ]
)
