// swift-tools-version: 6.0
// scripts/build-core.sh가 생성한다. RDCore.xcframework는 eyebuild 산출물로 가는 심볼릭 링크다.
import PackageDescription

let package = Package(
    name: "RDCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "RDCoreBridge", targets: ["RDCoreBridge"]),
    ],
    targets: [
        .binaryTarget(name: "RDCoreC", path: "RDCore.xcframework"),
        .target(
            name: "RDCoreBridge",
            dependencies: ["RDCoreC"],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "RDCoreBridgeTests", dependencies: ["RDCoreBridge"]),
    ]
)
