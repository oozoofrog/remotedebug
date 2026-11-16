import Foundation
import Testing

@testable import PhoneClientKit

@Suite struct ConnectionStatusTests {
    private func status(
        _ tunnel: TunnelState,
        available: Bool = true,
        active: Bool = false,
        direct: Bool = false,
        autoReady: Bool = false,
        autoStarting: Bool = false,
        lock: Bool = false
    ) -> ConnectionStatus {
        ConnectionStatus(
            tunnel: tunnel, tunnelAvailable: available, tunnelActive: active, directConnected: direct,
            autoStartReady: autoReady, autoStarting: autoStarting, lockWaiting: lock
        )
    }

    @Test func 연결되어_있으면_한_줄로_접는다() {
        #expect(status(.connected) == .ready)
        #expect(status(.off, direct: true) == .ready)
        // 같은 Wi-Fi로 닿으면 시뮬레이터처럼 VPN을 못 써도 막히지 않는다.
        #expect(status(.failed(message: "x"), available: false, direct: true) == .ready)
    }

    @Test func VPN이_꺼져_있어도_자동으로_켤_수_있으면_문제가_아니다() {
        #expect(status(.off, autoReady: true) == .standby)
        #expect(status(.off, autoStarting: true) == .working)
        #expect(status(.connecting) == .working)
        #expect(status(.disconnecting) == .working)
    }

    @Test func 사용자가_해야_할_일이_있을_때만_문제로_펼친다() {
        #expect(status(.off) == .problem(.vpnOff))
        #expect(status(.needsLogin(authURL: URL(string: "https://login.example.com/a"))) == .problem(.needsLogin(hasURL: true)))
        #expect(status(.needsLogin(authURL: nil)) == .problem(.needsLogin(hasURL: false)))
        #expect(status(.connected, lock: true) == .problem(.lockSignature))
        #expect(status(.failed(message: "x")) == .problem(.failed(running: false)))
        #expect(status(.failed(message: "x"), active: true) == .problem(.failed(running: true)))
        #expect(status(.failed(message: "x"), available: false) == .problem(.unavailable))
    }

    @Test func 직접_연결은_VPN_오류를_가리지_않는다() {
        // 직접 연결로 목록은 받아도 설치에는 VPN이 필요하므로 오류는 그대로 보인다.
        #expect(status(.failed(message: "x"), direct: true) == .problem(.failed(running: false)))
        #expect(status(.needsLogin(authURL: nil), direct: true) == .problem(.needsLogin(hasURL: false)))
    }
}
