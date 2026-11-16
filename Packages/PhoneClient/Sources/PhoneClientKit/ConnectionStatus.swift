import Foundation

/// 이 앱이 지금 Mac과 주고받을 수 있는지 한눈에 보이는 요약.
///
/// 화면은 `ready`·`standby`·`working`이면 상태 한 줄로 접고, `problem`일 때만 원인과 버튼 하나를 펼친다.
/// 읽기 전용 계산이라 `ClientModel`의 동작은 바꾸지 않는다.
public enum ConnectionStatus: Equatable, Sendable {
    /// 지금 Mac과 주고받을 수 있다(VPN, 다른 앱의 VPN, 같은 Wi-Fi 직접 연결).
    case ready
    /// VPN은 꺼져 있지만 Mac이 필요할 때 앱이 자동으로 켠다.
    case standby
    /// VPN을 켜거나 연결하거나 끄는 중이다.
    case working
    /// 사용자가 해야 할 일이 있거나 이 기기에서는 쓸 수 없다.
    case problem(Problem)

    public enum Problem: Equatable, Sendable {
        /// 이 기기에서는 VPN을 쓸 수 없다(시뮬레이터). 할 수 있는 일이 없다.
        case unavailable
        /// VPN이 꺼져 있고 앱이 자동으로 켤 수 없다. 사용자가 켜야 한다.
        case vpnOff
        /// tailnet 로그인이 필요하다. `hasURL`이 `false`면 로그인 주소를 받는 중이다.
        case needsLogin(hasURL: Bool)
        /// Tailnet Lock 서명을 기다린다.
        case lockSignature
        /// VPN 오류. `running`이면 VPN은 켜져 있고 tailnet 쪽만 오류다(다시 켜려면 먼저 끈다).
        case failed(running: Bool)
    }

    public init(
        tunnel: TunnelState,
        tunnelAvailable: Bool,
        tunnelActive: Bool,
        directConnected: Bool,
        autoStartReady: Bool,
        autoStarting: Bool,
        lockWaiting: Bool
    ) {
        if !tunnelAvailable {
            self = directConnected ? .ready : .problem(.unavailable)
            return
        }
        switch tunnel {
        case .off:
            if autoStarting { self = .working }
            else if directConnected { self = .ready }
            else if autoStartReady { self = .standby }
            else { self = .problem(.vpnOff) }
        case .connecting, .disconnecting:
            self = .working
        case .needsLogin(let url):
            self = .problem(.needsLogin(hasURL: url != nil))
        case .connected:
            self = lockWaiting ? .problem(.lockSignature) : .ready
        case .failed:
            self = .problem(.failed(running: tunnelActive))
        }
    }

    public var problem: Problem? {
        if case .problem(let problem) = self { return problem }
        return nil
    }
}
