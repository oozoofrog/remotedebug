import Foundation
import PhoneClientKit
import UIKit

/// 같은 네트워크·USB 케이블 직접 연결(docs/protocol-addenda.md O, Q)의 실제 구성: Keychain, Bonjour, 네트워크 경로, 공개 키 고정 TLS.
///
/// 두 iPhone 앱은 같은 tailnet 기기라 Mac의 토큰이 하나다. 그래서 등록 값은 App Group 이름의
/// Keychain 그룹에 두어 함께 쓴다. 그 그룹을 쓸 수 없는 빌드에서는 앱마다 따로 저장한다.
@MainActor
final class DirectConnection {
    let route: DirectRoute
    private let monitor = LocalNetworkMonitor()
    /// Wi-Fi에 붙거나 떨어졌다. 케이블을 꽂거나 뽑았다.
    var onNetworkChange: (@MainActor () -> Void)?
    private var batteryObserver: (any NSObjectProtocol)?

    init() {
        route = DirectRoute(
            store: KeychainDirectCredentialStore(accessGroup: SharedContainer.groupID),
            browser: BonjourDirectBrowser(),
            network: monitor,
            transports: PinnedTransportFactory()
        )
        monitor.start { [weak self] in
            Task { @MainActor in self?.onNetworkChange?() }
        }
        // 케이블이 꽂혀 있는지는 충전 상태로 안다. Mac에 꽂은 것인지는 직접 경로를 찾아봐야 안다(충전기일 수도 있다).
        UIDevice.current.isBatteryMonitoringEnabled = true
        monitor.setCablePlugged(Self.isPlugged)
        let monitor = monitor
        batteryObserver = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { monitor.setCablePlugged(Self.isPlugged) }
        }
    }

    private static var isPlugged: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        default: false
        }
    }
}
