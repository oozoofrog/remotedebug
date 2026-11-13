import Foundation

/// 넘겨받기: 다른 앱(짝 앱 등)의 VPN이 켜져 있을 때 이 앱의 터널을 켠다(docs/protocol-addenda.md M.4). 부작용이 없다.
///
/// iOS는 다른 앱의 터널을 내리는 동안 막 시작한 이 앱의 연결을 확장을 띄우기도 전에 끊을 수 있다.
/// 그 끊김은 실패로 보이지 않고 "연결 중"으로 둔 채, 상대 터널이 내려간 뒤 정해진 횟수만큼 다시 켠다.
public enum VPNTakeover {
    /// 이 앱의 터널이 연결되기 전에 끊겼을 때 다시 켜는 최대 횟수.
    public static let maxRestarts = 2

    /// 이 앱의 터널이 연결되기 전에 끊긴 까닭(`fetchLastDisconnectError()`).
    public enum Drop: Equatable, Sendable {
        /// iOS가 끊었다. 확장이 보낸 오류가 아니다.
        case system
        /// 오류 없이 꺼졌다(설정 앱·제어 센터에서 끔).
        case noError
        /// 확장이 보낸 오류로 끝났다(구성·코어 시작 실패, 시작 중 종료 요청 등).
        case tunnel
    }

    /// 넘겨받는 중 끊겼을 때 다시 켤지. 사용자가 끈 경우, 오류 없이 꺼진 경우, 확장이 보낸 오류는 다시 켜지 않는다.
    public static func restarts(after drop: Drop, restartsDone: Int, userStopped: Bool) -> Bool {
        !userStopped && drop == .system && restartsDone < maxRestarts
    }

    /// 넘겨받는 동안(이 앱의 터널이 아직 연결되지 않았다) 보일 상태. 일시적인 꺼짐·실패나 아직 남은 다른 앱의 연결 대신 "연결 중".
    public static func displayedState(_ state: TunnelState, takingOver: Bool) -> TunnelState {
        takingOver ? .connecting : state
    }

    /// 이 앱의 터널을 기다릴 때: 이 앱의 터널로 연결됐으면 `true`, 로그인이 필요하거나 실패로 멈췄으면 `false`, 더 기다리면 `nil`.
    /// - Parameter ownActive: 이 앱의 터널이 켜져 있거나 켜지는 중이다. 아니면 `connected`는 다른 앱의 VPN이다.
    public static func settled(_ state: TunnelState, ownActive: Bool) -> Bool? {
        switch state {
        case .connected: ownActive ? true : nil
        case .needsLogin: ownActive ? false : nil
        case .failed: false
        case .off, .connecting, .disconnecting: nil
        }
    }
}
