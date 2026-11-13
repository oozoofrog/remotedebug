import Observation
import PhoneClientKit
import RDModels

/// 설치를 시작하기 전에 필요하면 VPN을 이 앱의 터널로 옮긴다(`InstallVPNGuard`).
///
/// 짝 앱의 터널이 VPN을 켜고 있을 때 그 앱을 설치하면 iOS가 터널을 끝내 전송이 끊긴다.
/// 옮기는 동안의 단계와 실패는 `preparations`에 빌드 id별로 둔다.
@MainActor
@Observable
final class GuardedInstaller {
    private(set) var preparations: [String: InstallPreparation] = [:]
    @ObservationIgnored private let tunnel: TunnelController
    @ObservationIgnored private let role: InstallVPNGuard.Role

    init(tunnel: TunnelController, role: InstallVPNGuard.Role) {
        self.tunnel = tunnel
        self.role = role
    }

    /// 준비 단계의 실패 안내를 지운다.
    func clear(_ buildID: String) {
        if case .failed = preparations[buildID] { preparations[buildID] = nil }
    }

    func install(_ build: BuildDescriptor, with model: ClientModel) {
        if case .working = preparations[build.id] { return }
        tunnel.refreshExternal()
        let holder = tunnel.vpnHolder
        let takesOver = InstallVPNGuard.takesOverFirst(role: role, installing: build.bundleId, pairedAppID: AppPair.otherAppID, holder: holder)
            || InstallVPNGuard.connectsOwnFirst(state: tunnel.currentState(), holder: holder, configuration: tunnel.autoStartConfiguration)
        guard takesOver else {
            preparations[build.id] = nil
            model.install(build)
            return
        }
        preparations[build.id] = .working(holder == .none ? "이 앱의 VPN을 켜는 중" : "VPN을 이 앱으로 옮기는 중")
        Task { await takeOverThenInstall(build, model: model, startedFromOff: holder == .none) }
    }

    /// - Parameter startedFromOff: 설치를 누를 때 어느 앱의 VPN도 켜져 있지 않았다.
    private func takeOverThenInstall(_ build: BuildDescriptor, model: ClientModel, startedFromOff: Bool) async {
        let id = build.id
        model.log(.info, "install", startedFromOff
            ? "\(build.displayName) 설치 전에 이 앱의 VPN을 켬"
            : "\(build.displayName) 설치 전에 VPN을 이 앱의 터널로 옮김")
        // 다른 앱에서 넘겨받은 VPN은 원래 켜져 있던 것이므로 자동으로 끄지 않는다.
        model.noteManualVPNChange()
        do {
            try await tunnel.connectOwn()
        } catch {
            model.log(.error, "install", "VPN 옮기기 실패: \(error.localizedDescription)")
            preparations[id] = .failed("VPN을 이 앱으로 옮기지 못했습니다. \(error.localizedDescription)")
            return
        }
        preparations[id] = .working("VPN이 연결되기를 기다리는 중")
        let settled = await tunnel.waitUntilOwnTunnelSettles()
        if tunnel.takeoverRestartsUsed > 0 || tunnel.lastTakeoverDrop != nil {
            model.log(.info, "install", "VPN을 옮기는 중 iOS가 연결을 끊어 \(tunnel.takeoverRestartsUsed)번 다시 켬(끊김: \(tunnel.lastTakeoverDrop ?? "오류 없음"))")
        }
        // 꺼져 있던 VPN을 설치 때문에 켰으면 자동으로 켠 것으로 본다. 설치가 끝난 뒤 쓸 일이 없으면 꺼진다.
        if startedFromOff { model.noteAutoStartedVPN() }
        guard settled else {
            model.log(.warning, "install", "이 앱의 VPN이 연결되지 않아 설치를 시작하지 않음")
            if case .needsLogin = tunnel.state {
                preparations[id] = .failed("Tailscale 로그인이 필요합니다. 로그인한 뒤 다시 설치하세요.")
            } else {
                preparations[id] = .failed("VPN이 연결되지 않아 설치를 시작하지 못했습니다. VPN 상태를 확인한 뒤 다시 설치하세요.")
            }
            return
        }
        preparations[id] = nil
        model.install(build)
    }
}
