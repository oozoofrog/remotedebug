// swift-tools-version: 6.0
import PackageDescription

// Go 코어 대신 Swiftail(순수 Swift tailnet 노드) 위에서 도는 최소 HTTPS 파일 서버. Mac 호스트를 Go에서 옮기는 첫 단계이고,
// Swiftail 실기기 관문(M7 (나) 3~6, M6 (나))에 쓴다. 이 저장소 옆 폴더(../Swiftail)에 Swiftail 패키지가 있어야 한다.
// MacHost와 따로 둔다: 일반 빌드는 ../Swiftail 없이 된다.
//
// 관문에 쓰는 빌드는 Swiftail을 커밋에 고정한 별도 checkout으로 받는다(옆 폴더는 작업 중이라 깨져 있을 수 있다):
// 환경 변수 SWIFTAIL_PATH에 그 checkout의 경로를 준다. 폴더 이름은 Swiftail이어야 한다.
import Foundation

let swiftailPath = ProcessInfo.processInfo.environment["SWIFTAIL_PATH"] ?? "../../../Swiftail"

let package = Package(
    name: "SwiftailHost",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RDHostLogic", targets: ["RDHostLogic"]),
        .library(name: "SwiftailHostServer", targets: ["SwiftailHostServer"]),
        .executable(name: "rd-swiftail-host", targets: ["rd-swiftail-host"]),
    ],
    dependencies: [
        .package(path: swiftailPath),
        .package(path: "../RemoteDebugKit"),
    ],
    targets: [
        // 호스트 로직: 경로·페어링·세션·게시. Swiftail도 소켓도 쓰지 않는다(전송과의 접점은 HostHTTP.swift).
        .target(name: "RDHostLogic", dependencies: [.product(name: "RDModels", package: "RemoteDebugKit")], resources: [.copy("Resources/web")]),
        .testTarget(name: "RDHostLogicTests", dependencies: ["RDHostLogic"]),
        .target(
            name: "SwiftailHostServer",
            dependencies: [
                "RDHostLogic",
                .product(name: "Swiftail", package: "Swiftail"),
                .product(name: "SwiftailBase", package: "Swiftail"),
                .product(name: "SwiftailControl", package: "Swiftail"),
                .product(name: "SwiftailCertificates", package: "Swiftail"),
                .product(name: "SwiftailLoopback", package: "Swiftail"),
            ]
        ),
        .executableTarget(
            name: "rd-swiftail-host",
            dependencies: [
                "SwiftailHostServer",
                .product(name: "Swiftail", package: "Swiftail"),
                .product(name: "SwiftailControl", package: "Swiftail"),
                .product(name: "SwiftailCertificates", package: "Swiftail"),
            ]
        ),
        .testTarget(
            name: "SwiftailHostServerTests",
            dependencies: [
                "SwiftailHostServer", "RDHostLogic",
                .product(name: "Swiftail", package: "Swiftail"),
                .product(name: "SwiftailLoopback", package: "Swiftail"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
