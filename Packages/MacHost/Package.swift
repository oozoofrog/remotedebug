// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHost",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MacHostKit", targets: ["MacHostKit"]),
        // SwiftUI 화면과 미리보기. 코어(Swiftail)를 링크하지 않아 Xcode 미리보기가 이 대상만으로 뜬다.
        .library(name: "MacHostUI", targets: ["MacHostUI"]),
        // 실제 코어: Swiftail 노드(SwiftailHostServer)와 호스트 로직(RDHostLogic). MacHostKit·MacHostUI는 의존하지 않는다.
        .library(name: "MacHostCore", targets: ["MacHostCore"]),
    ],
    dependencies: [
        .package(path: "../RemoteDebugKit"),
        // Swiftail은 SwiftailHost가 공개 저장소의 고정 커밋으로 받는다(SWIFTAIL_PATH가 있으면 그 로컬 checkout).
        .package(path: "../SwiftailHost"),
    ],
    targets: [
        .target(
            name: "MacHostKit",
            dependencies: [
                .product(name: "RDModels", package: "RemoteDebugKit"),
                .product(name: "RDBuildInspection", package: "RemoteDebugKit"),
                .product(name: "RDPackaging", package: "RemoteDebugKit"),
            ]
        ),
        .target(
            name: "MacHostUI",
            dependencies: [
                "MacHostKit",
                .product(name: "RDModels", package: "RemoteDebugKit"),
                // 미리보기용 가짜 검사기(InspectionResult 등). 순수 Swift라 Go 런타임과 무관하다.
                .product(name: "RDBuildInspection", package: "RemoteDebugKit"),
            ]
        ),
        .target(
            name: "MacHostCore",
            dependencies: [
                "MacHostKit",
                .product(name: "RDModels", package: "RemoteDebugKit"),
                .product(name: "SwiftailHostServer", package: "SwiftailHost"),
                .product(name: "RDHostLogic", package: "SwiftailHost"),
            ]
        ),
        .testTarget(name: "MacHostKitTests", dependencies: ["MacHostKit"]),
        .testTarget(name: "MacHostUITests", dependencies: ["MacHostUI", "MacHostKit"]),
        .testTarget(
            name: "MacHostCoreTests",
            dependencies: [
                "MacHostCore", "MacHostKit",
                .product(name: "RDModels", package: "RemoteDebugKit"),
                .product(name: "SwiftailHostServer", package: "SwiftailHost"),
                .product(name: "RDHostLogic", package: "SwiftailHost"),
            ]
        ),
        // 실제 모델 + 실제 코어·로직·HTTP 전송 + 루프백 가짜 tailnet(계정·소켓 밖의 tailnet 없이 돈다).
        .testTarget(
            name: "MacHostE2ETests",
            dependencies: [
                "MacHostCore", "MacHostKit",
                .product(name: "RDModels", package: "RemoteDebugKit"),
                .product(name: "RDBuildInspection", package: "RemoteDebugKit"),
                .product(name: "SwiftailHostServer", package: "SwiftailHost"),
                .product(name: "RDHostLogic", package: "SwiftailHost"),
            ]
        ),
    ]
)
