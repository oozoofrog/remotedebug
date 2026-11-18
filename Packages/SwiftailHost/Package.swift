// swift-tools-version: 6.0
import PackageDescription

// Swiftail(순수 Swift tailnet 노드) 위에서 도는 Mac 호스트: 호스트 로직(RDHostLogic)과 전송(SwiftailHostServer).
// Swiftail은 공개 저장소의 고정 커밋을 쓴다.
// 로컬 checkout으로 빌드하려면 환경 변수 SWIFTAIL_PATH에 그 경로를 준다(폴더 이름은 Swiftail이어야 한다).
import Foundation

let swiftail: Package.Dependency = ProcessInfo.processInfo.environment["SWIFTAIL_PATH"].map { .package(path: $0) }
    ?? .package(url: "https://github.com/oozoofrog/Swiftail", revision: "5dc81527e14629f1f1b44ec742ef1b1d76d2ebec")

let package = Package(
    name: "SwiftailHost",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RDHostLogic", targets: ["RDHostLogic"]),
        .library(name: "SwiftailHostServer", targets: ["SwiftailHostServer"]),
        .executable(name: "rd-swiftail-host", targets: ["rd-swiftail-host"]),
    ],
    dependencies: [
        swiftail,
        .package(path: "../RemoteDebugKit"),
        // 시험만: iPhone 앱이 실제로 만드는 요청(PhoneClientKit)을 두 리스너에 보내 본다.
        .package(path: "../PhoneClient"),
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
                // 페어링 제안·짝 맺기(PairingHost)와 1회용 인증 키 발급. Mac 코어(MacHostCore)가 쓴다.
                .product(name: "SwiftailPairing", package: "Swiftail"),
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
                .product(name: "PhoneClientKit", package: "PhoneClient"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
