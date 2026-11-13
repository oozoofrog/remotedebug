import Foundation
import RDModels

/// 이 앱의 VPN 구성이 iOS에 저장돼 있는지.
public enum VPNConfigurationState: Equatable, Sendable {
    /// 구성이 없다. 만들려면 iOS의 "VPN 구성 추가" 동의가 필요하다.
    case missing
    /// 구성은 있지만 iOS 설정에서 다른 VPN이 선택돼 있다.
    case disabled
    /// 구성이 있고 선택돼 있다. 동의 없이 켤 수 있다.
    case ready
}

/// VPN을 자동으로 켜고 끄는 규칙(docs/protocol-addenda.md N). 부작용이 없다.
public enum AutoVPNPolicy {
    public enum Start: Equatable, Sendable {
        /// 이미 연결돼 있다(이 앱의 터널이든 다른 앱의 VPN이든).
        case notNeeded
        /// 이 앱의 VPN을 켠다.
        case start
        /// 켜지 않는다.
        case blocked(Blocker)
    }

    public enum Blocker: Equatable, Sendable {
        /// 구성이 없다. 사용자가 **VPN 켜기**를 눌러 iOS 동의를 거쳐야 한다.
        case noConfiguration
        /// 다른 VPN이 선택돼 있다. 자동으로 바꾸지 않는다.
        case configurationDisabled
        /// 다른 앱의 VPN이 켜져 있다. 그것을 끄고 이 앱의 것으로 바꾸지 않는다.
        case otherVPN
        /// 이미 켜지는 중이다.
        case connecting
        /// tailnet 로그인이 필요하다.
        case needsLogin
        /// 오류로 멈췄다. 사용자가 다시 연결한다.
        case failed
    }

    /// Mac이 필요한 동작을 시작할 때 VPN을 자동으로 켤지 정한다.
    public static func start(state: TunnelState, holder: VPNHolder, configuration: VPNConfigurationState) -> Start {
        if state == .connected { return .notNeeded }
        if holder == .pairedApp || holder == .other { return .blocked(.otherVPN) }
        switch state {
        case .connected: return .notNeeded
        case .connecting: return .blocked(.connecting)
        case .needsLogin: return .blocked(.needsLogin)
        case .failed: return .blocked(.failed)
        case .off, .disconnecting:
            switch configuration {
            case .missing: return .blocked(.noConfiguration)
            case .disabled: return .blocked(.configurationDisabled)
            case .ready: return .start
            }
        }
    }
}

/// 자동으로 켠 VPN을 쓸 일이 없어진 뒤 얼마나 지났는지 센다.
public struct AutoVPNIdle: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// 그대로 둔다.
        case keep
        /// 이 앱의 VPN을 끈다.
        case turnOff
        /// 더는 자동으로 켠 VPN이 아니다(사용자가 켜거나 껐다, 다른 앱이 가져갔다). 끄지 않고 잊는다.
        case forget
    }

    /// 쓸 일이 없어진 시각. 쓰는 중이면 `nil`.
    public private(set) var idleSince: Date?

    public init() {}

    /// Mac이 필요한 동작이 시작됐다. 끄기를 미룬다.
    public mutating func noteNeed() {
        idleSince = nil
    }

    /// - Parameters:
    ///   - autoStarted: 지금 VPN을 앱이 자동으로 켰는가.
    ///   - holder: 지금 VPN을 켜고 있는 쪽.
    ///   - hasNeed: 설치(시스템 설치기 대기 포함), 파일 전송, 보내기처럼 Mac이 필요한 일이 남았는가.
    ///   - delay: 쓸 일이 없어진 뒤 끄기까지의 시간.
    public mutating func check(now: Date, autoStarted: Bool, holder: VPNHolder, state: TunnelState, hasNeed: Bool, delay: TimeInterval) -> Action {
        guard autoStarted, holder == .thisApp else {
            idleSince = nil
            return .forget
        }
        // 로그인이 필요하면 사용자가 로그인하는 중일 수 있다. 끄지 않는다.
        if hasNeed || state.isNeedsLogin {
            idleSince = nil
            return .keep
        }
        let since = idleSince ?? now
        idleSince = since
        return now.timeIntervalSince(since) >= delay ? .turnOff : .keep
    }
}

extension TunnelState {
    var isNeedsLogin: Bool {
        if case .needsLogin = self { return true }
        return false
    }
}

/// VPN 카드에 보여 줄 상태 문구.
public enum VPNStatusText {
    public static let autoStarting = "VPN 켜는 중…"
    public static let connected = "연결됨"
    /// VPN은 꺼져 있고 같은 Wi-Fi의 Mac과 직접 주고받는다(docs/protocol-addenda.md O).
    public static let direct = "직접 연결(같은 Wi-Fi, VPN 없이)"
    public static let directDetail = "같은 Wi-Fi의 Mac과 직접 주고받습니다. 앱을 설치할 때만 VPN을 자동으로 켭니다."
    public static let directWithVPNDetail = "빌드 목록·파일·로그는 같은 Wi-Fi로 Mac과 직접 주고받습니다."

    /// 연결됐을 때의 문구. 이 앱의 터널이 아니면(다른 앱의 VPN) 경로를 알 수 없으므로 경로를 말하지 않는다.
    public static func connected(holder: VPNHolder, path: PeerPath?) -> String {
        guard holder == .thisApp, let path else { return connected }
        return connected + " · " + path.label
    }
}
