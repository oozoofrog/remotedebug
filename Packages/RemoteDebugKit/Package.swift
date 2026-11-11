// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteDebugKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "RDModels", targets: ["RDModels"]),
        .library(name: "RDBuildInspection", targets: ["RDBuildInspection"]),
        .library(name: "RDPackaging", targets: ["RDPackaging"]),
        .executable(name: "rdvalidate", targets: ["rdvalidate"]),
    ],
    targets: [
        // iOS + macOS
        .target(name: "RDModels"),
        // macOS 전용(소스 전체가 #if os(macOS)). App Sandbox 호환: 프로세스 실행 없음.
        .target(name: "RDPackaging"),
        .target(name: "RDBuildInspection", dependencies: ["RDModels", "RDPackaging"]),
        .executableTarget(
            name: "rdvalidate",
            dependencies: ["RDModels", "RDBuildInspection", "RDPackaging"]
        ),
        .testTarget(name: "RDModelsTests", dependencies: ["RDModels"]),
        .testTarget(
            name: "RDKitTests",
            dependencies: ["RDModels", "RDBuildInspection", "RDPackaging"]
        ),
    ]
)
