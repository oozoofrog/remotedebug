// swift-tools-version: 6.0
import PackageDescription

// 설치 웹 페이지(core/internal/host/web)의 순수 로직(logic.js)과 화면 도움 함수(install.js)를
// JavaScriptCore로 불러 검사한다. 제품 코드는 없다. 규칙과 문구가 iPhone 앱과 같은지
// PhoneClientKit과 직접 비교한다.
let package = Package(
    name: "WebPage",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../PhoneClient"),
        .package(path: "../RemoteDebugKit"),
    ],
    targets: [
        .testTarget(
            name: "WebPageTests",
            dependencies: [
                .product(name: "PhoneClientKit", package: "PhoneClient"),
                .product(name: "RDModels", package: "RemoteDebugKit"),
            ]
        ),
    ]
)
