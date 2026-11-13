import Foundation

/// URL을 연다. 앱은 `UIApplication.shared.open`을 연결한다.
@MainActor
public protocol URLOpening: AnyObject {
    func open(_ url: URL) async -> Bool
}

/// iPhone의 VPN(패킷 터널) 상태.
public enum TunnelState: Equatable, Sendable {
    case off
    case connecting
    /// VPN을 끄는 중이다. 꺼질 때까지 켜기 동작을 받지 않는다.
    case disconnecting
    case connected
    /// tailnet 로그인이 필요하다. `authURL`을 열어 로그인한다.
    case needsLogin(authURL: URL?)
    case failed(message: String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 로그에 남기는 짧은 설명.
    var logText: String {
        switch self {
        case .off: "꺼짐"
        case .connecting: "연결 중"
        case .disconnecting: "끄는 중"
        case .connected: "연결됨"
        case .needsLogin: "로그인 필요"
        case .failed(let message): "실패(\(message))"
        }
    }
}

/// VPN 관리. 앱은 `NETunnelProviderManager`로 구현한다.
///
/// VPN은 패킷 터널이라 tailnet 트래픽 전체를 나른다(docs/tunnel.md). 호스트별 허용 목록이 없으므로
/// 페어링·호스트 변경은 VPN 구성을 건드리지 않는다.
@MainActor
public protocol TunnelControlling: AnyObject {
    func currentState() -> TunnelState
    func stateUpdates() -> AsyncStream<TunnelState>
    /// VPN 구성이 저장돼 있고 켜져 있게 한다(없거나 다르거나 꺼져 있으면 저장하고, 같으면 아무것도 바꾸지 않는다).
    /// 여러 번 불러도 결과가 같아야 한다. 모델은 사용자가 VPN을 켤 때(`connect()` 직전)만 부른다.
    /// 앱 시작에서는 부르지 않는다. 사용자가 시스템에서 고른 다른 VPN을 바꾸지 않기 위해서다.
    /// 사용자가 iOS의 "VPN 구성 추가" 알림에서 거절하면 오류를 던진다.
    func prepare() async throws
    func connect() async throws
    func disconnect() async
    /// 지금 VPN을 켜고 있는 쪽. 다른 앱의 VPN이 켜져 있으면 자동으로 켜거나 끄지 않는다.
    var vpnHolder: VPNHolder { get }
    /// 이 앱의 VPN 구성이 저장돼 있고 선택돼 있는지. `ready`일 때만 자동으로 켠다.
    var autoStartConfiguration: VPNConfigurationState { get }
    /// 이 앱의 VPN을 사용자 조작 없이 켠다. 구성을 만들거나 저장하지 않고(iOS 동의 창을 띄우지 않는다),
    /// 다른 앱의 VPN이 켜져 있으면 그것을 그대로 쓴다. 구성이 없거나 꺼져 있으면 오류를 던진다.
    func connectAutomatically() async throws
}

/// 자동으로 켜기를 구현하지 않은 쪽(시험용 가짜)은 자동으로 켜지 않는다.
public extension TunnelControlling {
    var vpnHolder: VPNHolder { currentState() == .off ? .none : .thisApp }
    var autoStartConfiguration: VPNConfigurationState { .missing }
    func connectAutomatically() async throws { throw CancellationError() }
}

/// 현재 시각과 대기. 테스트는 실제로 기다리지 않는 구현을 넣는다.
public protocol PollingClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemPollingClock: PollingClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
