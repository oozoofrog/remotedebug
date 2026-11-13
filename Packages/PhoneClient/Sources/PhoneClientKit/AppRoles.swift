import Foundation
import RDModels

/// 두 iPhone 앱이 빌드 목록에서 각자 보여 줄 빌드를 고른다.
///
/// RemoteDebug 앱은 자기 자신의 빌드를 보여 주지 않는다. 업데이트 앱은 RemoteDebug 앱의 빌드만 보여 준다.
public enum AppBuildFilter {
    /// `bundleID` 앱의 빌드를 뺀 목록. 번들 ID를 모르면 그대로 돌려준다.
    public static func hiding(_ bundleID: String?, in builds: [BuildDescriptor]) -> [BuildDescriptor] {
        guard let bundleID, !bundleID.isEmpty else { return builds }
        return builds.filter { $0.bundleId != bundleID }
    }

    /// `bundleID` 앱의 빌드만, 늦게 게시된 것이 앞에 오게.
    public static func only(_ bundleID: String, in builds: [BuildDescriptor]) -> [BuildDescriptor] {
        guard !bundleID.isEmpty else { return [] }
        return builds.filter { $0.bundleId == bundleID }.sorted { $0.publishedAt > $1.publishedAt }
    }
}

/// 지금 이 iPhone의 VPN을 켜고 있는 쪽.
public enum VPNHolder: Equatable, Sendable {
    /// VPN이 꺼져 있다.
    case none
    /// 이 앱의 터널.
    case thisApp
    /// 짝 앱(RemoteDebug ↔ 업데이트 앱)의 터널.
    case pairedApp
    /// tailnet 주소를 가진 다른 VPN(공식 Tailscale 등).
    case other
}

/// 짝 앱을 설치하기 전에 VPN을 이 앱의 터널로 옮겨야 하는지 정한다.
///
/// iOS는 앱을 설치하는 동안 그 앱과 그 앱의 터널 확장을 끝낸다. 설치할 앱의 터널이 VPN을 켜고 있으면
/// Mac과의 연결이 설치 도중에 끊긴다. 그래서 설치를 시작하기 전에 이 앱의 터널로 옮긴다.
public enum InstallVPNGuard {
    public enum Role: Sendable {
        /// RemoteDebug 앱. 업데이트 앱의 터널이 VPN을 켜고 있을 때만 옮긴다.
        case store
        /// 업데이트 앱. 이 앱의 터널이 아니면 언제나 옮긴다(꺼져 있으면 켠다).
        case updater
    }

    public static func takesOverFirst(role: Role, installing bundleID: String, pairedAppID: String, holder: VPNHolder) -> Bool {
        guard !pairedAppID.isEmpty, bundleID == pairedAppID else { return false }
        switch role {
        case .store: return holder == .pairedApp
        case .updater: return holder != .thisApp
        }
    }

    /// 설치를 눌렀을 때 VPN이 꺼져 있고 자동으로 켤 수 없으면(구성이 없거나 다른 VPN이 선택됨, 또는 실패로 멈춤) `true`.
    /// 이때는 이 앱의 VPN을 켠 뒤 설치한다(iOS 동의가 한 번 뜰 수 있다). 그 VPN은 자동으로 켠 것으로 보고 설치가 끝나면 끈다.
    public static func connectsOwnFirst(state: TunnelState, holder: VPNHolder, configuration: VPNConfigurationState) -> Bool {
        guard holder == .none else { return false }
        switch state {
        case .off, .disconnecting: return configuration != .ready
        // 실패로 멈춘 VPN은 자동으로 다시 켜지 않는다. 설치를 누른 것을 다시 연결 요청으로 본다.
        case .failed: return true
        default: return false
        }
    }
}
