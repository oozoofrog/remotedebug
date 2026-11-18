import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

/// 페어링 작업이 겹치거나 끊기는 순서와, 앱용 페어링이 쓸 수 있는 VPN.
@MainActor
@Suite struct PairingOrderTests {
    private let secret = "tskey-auth-kTest1CNTRL-abc"

    // MARK: 취소된 앞 작업이 늦게 돌아온다

    @Test func aLateCancelledJoinDoesNotHideTheNextCode() async {
        let h = Harness()
        h.pairing.setCode(nil)
        h.pairing.setFirstJoinIgnoresCancel(true)
        _ = h.model.pair(scanned: pairingLink())
        await h.waitUntil { h.pairing.calls.count == 1 }

        // 다른 QR로 바꾼다. 앞 작업은 취소됐지만 아직 돌아오지 않았다.
        h.pairing.setHolds(true)
        _ = h.model.pair(scanned: pairingLink(secret: "s2"))
        h.model.confirmPending()
        await h.waitUntil { h.pairing.calls.count == 2 }

        // 앞 작업이 이제 돌아온다. 두 번째 작업의 확인 숫자는 그 뒤에 온다.
        h.pairing.releaseFirstJoin()
        await h.waitUntil { h.pairing.cancelledJoins == 1 }
        for _ in 0..<50 { await Task.yield() }
        h.pairing.announce("482915")
        await h.waitUntil { h.model.confirmationCode != nil }

        #expect(h.model.confirmationCode == "482915")
        #expect(h.model.phase == .waitingApproval(deviceName: "내 iPhone"))
        #expect(h.model.lastError == nil)
        h.model.cancelPairing()
        await h.model.waitForBackgroundWork()
    }

    // MARK: VPN을 준비하는 동안

    @Test func cancellingEndsTheVPNPreparationThatUsesTheAuthKey() async {
        let h = Harness(tunnel: .off)
        var gate: CheckedContinuation<Void, Never>?
        var cancelledAfterWaiting: Bool?
        let tunnel = h.tunnel
        h.model.connectWithAuthKey = { _ in
            await withCheckedContinuation { gate = $0 }
            cancelledAfterWaiting = Task.isCancelled
            tunnel.set(.connected)
        }
        _ = h.model.pair(scanned: pairingLink(key: secret))
        await h.waitUntil { gate != nil }

        h.model.cancelPairing()
        gate?.resume()
        await h.waitUntil { cancelledAfterWaiting != nil }
        for _ in 0..<50 { await Task.yield() }

        // 준비 작업이 취소를 알았고, VPN이 연결돼도 취소한 페어링은 이어지지 않는다.
        #expect(cancelledAfterWaiting == true)
        #expect(h.pairing.calls.isEmpty)
        #expect(h.model.queuedPairing == nil)
        #expect(h.model.phase == .unpaired)
    }

    @Test func goingToTheBackgroundDropsTheProposalWaitingForVPN() async {
        let h = Harness(tunnel: .off)
        _ = h.model.pair(scanned: pairingLink())
        #expect(h.model.queuedPairing != nil)

        h.model.stopPolling()
        #expect(h.model.queuedPairing == nil)
        #expect(h.model.lastError == ClientModel.pairingInterruptedMessage)

        // 백그라운드에서 VPN이 연결돼도 1회용 제안을 보내지 않는다.
        h.tunnel.set(.connected)
        for _ in 0..<50 { await Task.yield() }
        await h.model.waitForBackgroundWork()
        #expect(h.pairing.calls.isEmpty)
        #expect(h.model.phase == .unpaired)
    }

    @Test func goingToTheBackgroundDropsTheProposalWaitingForTheAuthKeyVPN() async {
        let h = Harness(tunnel: .off)
        var gate: CheckedContinuation<Void, Never>?
        let tunnel = h.tunnel
        h.model.connectWithAuthKey = { _ in
            await withCheckedContinuation { gate = $0 }
            tunnel.set(.connected)
        }
        _ = h.model.pair(scanned: pairingLink(key: secret))
        await h.waitUntil { gate != nil }

        h.model.stopPolling()
        gate?.resume()
        for _ in 0..<50 { await Task.yield() }
        await h.model.waitForBackgroundWork()
        #expect(h.pairing.calls.isEmpty)
        #expect(h.model.queuedPairing == nil)
    }

    @Test func aProposalQueuedWhileBackgroundedIsNotStartedByTheConnection() async {
        let h = Harness(tunnel: .off)
        h.model.stopPolling()
        _ = h.model.pair(scanned: pairingLink())
        #expect(h.model.queuedPairing != nil)

        h.tunnel.set(.connected)
        for _ in 0..<50 { await Task.yield() }
        await h.model.waitForBackgroundWork()
        #expect(h.pairing.calls.isEmpty)
        #expect(h.model.queuedPairing == nil)
        #expect(h.model.lastError == ClientModel.pairingInterruptedMessage)
    }

    // MARK: 다른 VPN이 켜져 있다

    @Test func anotherVPNDoesNotCarryThePairingAndNeedsTheAppsOwnTunnel() async {
        let h = Harness(tunnel: .connected)
        h.tunnel.holder = .other
        h.serveHostInfoAndBuilds()
        _ = h.model.pair(scanned: pairingLink())
        for _ in 0..<50 { await Task.yield() }

        #expect(h.pairing.calls.isEmpty)
        #expect(h.model.queuedPairing != nil)
        #expect(h.model.needsTunnel)
        #expect(h.model.lastError == ClientModel.pairingNeedsOwnTunnelMessage)

        // 이 앱의 터널로 바뀌고 연결되면 이어 간다.
        h.tunnel.holder = nil
        h.tunnel.set(.connecting)
        h.tunnel.set(.connected)
        await h.waitUntil { h.model.phase == .paired }
        await h.model.waitForBackgroundWork()
        #expect(h.pairing.calls.count == 1)
        #expect(h.model.phase == .paired)
        #expect(h.model.queuedPairing == nil)
        #expect(h.model.lastError == nil)
    }

    @Test func aConnectedNotificationFromAnotherVPNKeepsTheQueuedPairing() async {
        let h = Harness(tunnel: .off)
        _ = h.model.pair(scanned: pairingLink())
        #expect(h.model.lastError == ClientModel.tunnelOffMessage)

        h.tunnel.holder = .other
        h.tunnel.set(.connected)
        for _ in 0..<50 { await Task.yield() }
        #expect(h.pairing.calls.isEmpty)
        #expect(h.model.queuedPairing != nil)
        #expect(h.model.lastError == ClientModel.pairingNeedsOwnTunnelMessage)
        h.model.cancelPairing()
    }

    @Test func autoStartThatFindsAnotherVPNDoesNotPair() async {
        let h = Harness(tunnel: .off)
        h.tunnel.autoStartConfiguration = .ready
        h.tunnel.holderAfterAutoStart = .other
        _ = h.model.pair(scanned: pairingLink())
        await h.model.waitForBackgroundWork()
        for _ in 0..<50 { await Task.yield() }

        #expect(h.pairing.calls.isEmpty)
        #expect(h.model.queuedPairing != nil)
        #expect(h.model.lastError == ClientModel.pairingNeedsOwnTunnelMessage)
        h.model.cancelPairing()
    }

    @Test func authKeyReplacesAnotherVPNOnce() async {
        let h = Harness(tunnel: .connected)
        h.tunnel.holder = .other
        h.serveHostInfoAndBuilds()
        var usedKeys: [String] = []
        let tunnel = h.tunnel
        h.model.connectWithAuthKey = { key in
            usedKeys.append(key)
            tunnel.holder = nil
            tunnel.set(.connecting)
            tunnel.set(.connected)
        }
        _ = h.model.pair(scanned: pairingLink(key: secret))
        await h.waitUntil { h.model.phase == .paired }
        await h.model.waitForBackgroundWork()
        #expect(usedKeys == [secret])
        #expect(h.pairing.calls.count == 1)
        #expect(h.model.phase == .paired)
        #expect(h.model.lastError == nil)
    }

    @Test func thePairedAppsTunnelDoesNotCarryThePairing() async {
        // 짝 앱이 VPN을 쥐고 있으면 이 앱은 터널의 tailnet 주소를 받을 수 없다. 이 앱의 터널을 기다린다.
        let h = Harness(tunnel: .connected)
        h.tunnel.holder = .pairedApp
        _ = h.model.pair(scanned: pairingLink())
        await h.model.waitForBackgroundWork()
        #expect(h.pairing.calls.isEmpty)
        #expect(h.model.needsTunnel)
        #expect(h.model.lastError == ClientModel.pairingNeedsOwnTunnelMessage)
    }

    @Test func theAppsOwnTunnelCarriesThePairing() async {
        let h = Harness(tunnel: .connected)
        h.tunnel.holder = .thisApp
        h.serveHostInfoAndBuilds()
        var used = 0
        h.model.connectWithAuthKey = { _ in used += 1 }
        _ = h.model.pair(scanned: pairingLink(key: secret))
        await h.waitUntil { h.model.phase == .paired }
        await h.model.waitForBackgroundWork()
        #expect(used == 0)
        #expect(h.pairing.calls.count == 1)
        #expect(h.model.phase == .paired)
    }

    @Test func anotherVPNStillServesRefreshes() async {
        // 설치·목록 같은 다른 기능이 바깥 VPN을 쓰는 정책은 그대로다.
        let h = Harness(tunnel: .connected, storedHost: Harness.pairedHost)
        h.tunnel.holder = .other
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        #expect(h.model.builds.isEmpty == false)
        #expect(h.model.lastError == nil)
    }
}
