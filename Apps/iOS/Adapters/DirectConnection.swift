import Foundation
import PhoneClientKit

/// 같은 네트워크 직접 연결(docs/protocol-addenda.md O)의 실제 구성: Keychain, Bonjour, 네트워크 경로, 공개 키 고정 TLS.
///
/// 두 iPhone 앱은 같은 tailnet 기기라 Mac의 토큰이 하나다. 그래서 등록 값은 App Group 이름의
/// Keychain 그룹에 두어 함께 쓴다. 그 그룹을 쓸 수 없는 빌드에서는 앱마다 따로 저장한다.
@MainActor
final class DirectConnection {
    let route: DirectRoute
    private let monitor = LocalNetworkMonitor()
    /// Wi-Fi에 붙거나 떨어졌다.
    var onNetworkChange: (@MainActor () -> Void)?

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
    }
}
