// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHost",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MacHostKit", targets: ["MacHostKit"]),
        // SwiftUI 화면과 미리보기. Go 런타임(RDCoreBridge)을 링크하지 않아 Xcode 미리보기가 이 대상만으로 뜬다.
        .library(name: "MacHostUI", targets: ["MacHostUI"]),
        // 실제 Go 코어(RDCoreBridge) 어댑터. MacHostKit·MacHostUI는 RDCore에 의존하지 않는다.
        .library(name: "MacHostCore", targets: ["MacHostCore"]),
    ],
    dependencies: [
        .package(path: "../RemoteDebugKit"),
        .package(path: "../RDCore"),
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
                .product(name: "RDCoreBridge", package: "RDCore"),
            ]
        ),
        .testTarget(name: "MacHostKitTests", dependencies: ["MacHostKit"]),
        .testTarget(name: "MacHostUITests", dependencies: ["MacHostUI", "MacHostKit"]),
        .testTarget(name: "MacHostCoreTests", dependencies: ["MacHostCore", "MacHostKit"]),
        // 실제 코어 + 가짜 tailnet(rdtestenv). RDTESTENV_BIN이 있을 때만 돈다(scripts/e2e-mac.sh).
        .testTarget(
            name: "MacHostE2ETests",
            dependencies: [
                "MacHostCore", "MacHostKit",
                .product(name: "RDModels", package: "RemoteDebugKit"),
            ]
        ),
    ]
)
