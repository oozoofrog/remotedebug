// swift-tools-version: 6.0
import PackageDescription

// iPhone 앱 RemoteDebugPhone의 로직(UI·NetworkExtension과 분리). RDModels에만 의존한다.
let package = Package(
    name: "PhoneClient",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "PhoneClientKit", targets: ["PhoneClientKit"]),
    ],
    dependencies: [
        .package(path: "../RemoteDebugKit"),
    ],
    targets: [
        .target(
            name: "PhoneClientKit",
            dependencies: [.product(name: "RDModels", package: "RemoteDebugKit")]
        ),
        .testTarget(
            name: "PhoneClientKitTests",
            dependencies: ["PhoneClientKit", .product(name: "RDModels", package: "RemoteDebugKit")]
        ),
    ]
)
