import Foundation
import Testing

@testable import PhoneClientKit

@Suite struct VPNTakeoverTests {
    @Test func iOS가_끊은_경우만_정해진_횟수까지_다시_켠다() {
        #expect(VPNTakeover.restarts(after: .system, restartsDone: 0, userStopped: false))
        #expect(VPNTakeover.restarts(after: .system, restartsDone: VPNTakeover.maxRestarts - 1, userStopped: false))
        #expect(!VPNTakeover.restarts(after: .system, restartsDone: VPNTakeover.maxRestarts, userStopped: false))
    }

    @Test func 사용자가_끄거나_오류_없이_꺼지거나_확장_오류면_다시_켜지_않는다() {
        #expect(!VPNTakeover.restarts(after: .system, restartsDone: 0, userStopped: true))
        #expect(!VPNTakeover.restarts(after: .noError, restartsDone: 0, userStopped: false))
        #expect(!VPNTakeover.restarts(after: .tunnel, restartsDone: 0, userStopped: false))
    }

    @Test func 넘겨받는_동안은_연결_중으로_보인다() {
        let states: [TunnelState] = [.off, .connected, .disconnecting, .failed(message: "VPN 연결이 끊겼습니다. 다시 연결하세요.")]
        for state in states {
            #expect(VPNTakeover.displayedState(state, takingOver: true) == .connecting)
            #expect(VPNTakeover.displayedState(state, takingOver: false) == state)
        }
    }

    @Test func 이_앱의_터널로_연결되거나_멈출_때까지_기다린다() {
        #expect(VPNTakeover.settled(.connected, ownActive: true) == true)
        // 이 앱의 터널이 꺼져 있으면 연결됨은 다른 앱의 VPN이다.
        #expect(VPNTakeover.settled(.connected, ownActive: false) == nil)
        #expect(VPNTakeover.settled(.needsLogin(authURL: nil), ownActive: true) == false)
        #expect(VPNTakeover.settled(.failed(message: "x"), ownActive: false) == false)
        #expect(VPNTakeover.settled(.failed(message: "x"), ownActive: true) == false)
        // 켜기를 부른 직후에는 iOS가 아직 꺼짐으로 알려 줄 수 있다.
        #expect(VPNTakeover.settled(.off, ownActive: false) == nil)
        #expect(VPNTakeover.settled(.connecting, ownActive: true) == nil)
    }
}
