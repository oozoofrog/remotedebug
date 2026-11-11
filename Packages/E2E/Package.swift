// swift-tools-version: 6.0
import PackageDescription

// Mac 호스트(HostModel + 실제 Go 코어)와 iPhone 클라이언트(ClientModel + HostAPI)를 HTTP로 이어 시험한다.
// 제품 코드는 없다. FullE2ETests는 scripts/e2e-full.sh, WebBrowserTests는 scripts/e2e-web.sh로 돌린다.
let package = Package(
    name: "E2E",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../MacHost"),
        .package(path: "../PhoneClient"),
        .package(path: "../RemoteDebugKit"),
    ],
    targets: [
        // 두 시험 대상이 함께 쓰는 하네스: 하위 프로세스(rdtestenv control·forward), 기다리기, 환경 값.
        .target(name: "E2ESupport", path: "Tests/E2ESupport"),
        .testTarget(
            name: "FullE2ETests",
            dependencies: [
                "E2ESupport",
                .product(name: "MacHostKit", package: "MacHost"),
                .product(name: "MacHostCore", package: "MacHost"),
                .product(name: "PhoneClientKit", package: "PhoneClient"),
                .product(name: "RDModels", package: "RemoteDebugKit"),
                .product(name: "RDBuildInspection", package: "RemoteDebugKit"),
                .product(name: "RDPackaging", package: "RemoteDebugKit"),
            ]
        ),
        // 설치 웹 페이지를 WebKit(WKWebView)으로 띄워 실제 Mac 호스트와 사용자 흐름을 시험한다.
        // RD_E2E_WEB=1(scripts/e2e-web.sh)일 때만 돌고, 아니면 아무것도 하지 않고 끝난다.
        .testTarget(
            name: "WebBrowserTests",
            dependencies: [
                "E2ESupport",
                .product(name: "MacHostKit", package: "MacHost"),
                .product(name: "MacHostCore", package: "MacHost"),
                .product(name: "RDModels", package: "RemoteDebugKit"),
            ]
        ),
    ]
)
