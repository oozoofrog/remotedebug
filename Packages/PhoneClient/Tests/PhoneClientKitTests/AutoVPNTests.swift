import Foundation
import RDModels
import Testing
@testable import PhoneClientKit

@Suite struct AutoVPNPolicyTests {
    private let login = TunnelState.needsLogin(authURL: nil)

    @Test func startsOnlyWithEnabledConfigurationAndNoVPN() {
        #expect(AutoVPNPolicy.start(state: .off, holder: .none, configuration: .ready) == .start)
        #expect(AutoVPNPolicy.start(state: .disconnecting, holder: .thisApp, configuration: .ready) == .start)
        // 구성이 없으면 iOS 동의가 필요하다. 자동으로 만들지 않는다.
        #expect(AutoVPNPolicy.start(state: .off, holder: .none, configuration: .missing) == .blocked(.noConfiguration))
        // 다른 VPN이 선택돼 있으면 자동으로 바꾸지 않는다.
        #expect(AutoVPNPolicy.start(state: .off, holder: .none, configuration: .disabled) == .blocked(.configurationDisabled))
    }

    @Test func neverStartsWhileAnotherVPNIsUp() {
        for holder in [VPNHolder.pairedApp, .other] {
            #expect(AutoVPNPolicy.start(state: .connected, holder: holder, configuration: .ready) == .notNeeded)
            #expect(AutoVPNPolicy.start(state: .off, holder: holder, configuration: .ready) == .blocked(.otherVPN))
        }
    }

    @Test func doesNotRestartWhenLoginOrErrorNeedsTheUser() {
        #expect(AutoVPNPolicy.start(state: .connected, holder: .thisApp, configuration: .ready) == .notNeeded)
        #expect(AutoVPNPolicy.start(state: .connecting, holder: .thisApp, configuration: .ready) == .blocked(.connecting))
        #expect(AutoVPNPolicy.start(state: login, holder: .thisApp, configuration: .ready) == .blocked(.needsLogin))
        #expect(AutoVPNPolicy.start(state: .failed(message: "x"), holder: .none, configuration: .ready) == .blocked(.failed))
    }

    @Test func idleTurnsOffOnlyAfterTheDelay() {
        var idle = AutoVPNIdle()
        func check(_ seconds: TimeInterval, need: Bool = false, started: Bool = true, holder: VPNHolder = .thisApp,
                   state: TunnelState = .connected, idle: inout AutoVPNIdle) -> AutoVPNIdle.Action {
            idle.check(now: t0.addingTimeInterval(seconds), autoStarted: started, holder: holder, state: state, hasNeed: need, delay: 30)
        }
        #expect(check(0, idle: &idle) == .keep)
        #expect(check(29, idle: &idle) == .keep)
        #expect(check(30, idle: &idle) == .turnOff)
    }

    @Test func idleIsResetByNeedAndBlockedWhileWorkRemains() {
        var idle = AutoVPNIdle()
        func check(_ seconds: TimeInterval, need: Bool = false) -> AutoVPNIdle.Action {
            idle.check(now: t0.addingTimeInterval(seconds), autoStarted: true, holder: .thisApp, state: .connected, hasNeed: need, delay: 30)
        }
        #expect(check(0) == .keep)
        // 설치·전송이 남아 있는 동안은 아무리 지나도 끄지 않는다.
        #expect(check(20, need: true) == .keep)
        #expect(check(500, need: true) == .keep)
        // 일이 끝난 때부터 다시 30초를 센다.
        #expect(check(510) == .keep)
        #expect(check(539) == .keep)
        // 그사이 새 동작이 시작되면(짧게 끝나도) 다시 센다.
        idle.noteNeed()
        #expect(idle.idleSince == nil)
        #expect(check(545) == .keep)
        #expect(check(574) == .keep)
        #expect(check(575) == .turnOff)
    }

    @Test func idleNeverTouchesVPNsTheAppDidNotStart() {
        var idle = AutoVPNIdle()
        let late = t0.addingTimeInterval(3600)
        // 사용자가 켠 VPN.
        #expect(idle.check(now: late, autoStarted: false, holder: .thisApp, state: .connected, hasNeed: false, delay: 30) == .forget)
        // 짝 앱·다른 앱의 VPN, 이미 꺼진 VPN.
        for holder in [VPNHolder.pairedApp, .other, .none] {
            #expect(idle.check(now: late, autoStarted: true, holder: holder, state: .connected, hasNeed: false, delay: 30) == .forget)
        }
        // 로그인을 기다리는 동안은 끄지 않는다.
        _ = idle.check(now: t0, autoStarted: true, holder: .thisApp, state: login, hasNeed: false, delay: 30)
        #expect(idle.check(now: late, autoStarted: true, holder: .thisApp, state: login, hasNeed: false, delay: 30) == .keep)
    }

    @Test func statusTextSaysThePathOnlyForThisAppsTunnel() {
        let lan = PeerPath(direct: true, addr: "192.168.0.10:41641", relay: "tok")
        let wan = PeerPath(direct: true, addr: "203.0.113.7:41641", relay: "tok")
        let relayed = PeerPath(direct: false, relay: "tok")
        #expect(VPNStatusText.connected(holder: .thisApp, path: lan) == "연결됨 · 직접 연결(같은 네트워크)")
        #expect(VPNStatusText.connected(holder: .thisApp, path: wan) == "연결됨 · 직접 연결")
        #expect(VPNStatusText.connected(holder: .thisApp, path: relayed) == "연결됨 · 중계 서버 경유")
        #expect(VPNStatusText.connected(holder: .thisApp, path: nil) == "연결됨")
        // 다른 앱의 VPN이면 경로를 모른다.
        #expect(VPNStatusText.connected(holder: .pairedApp, path: lan) == "연결됨")
        #expect(VPNStatusText.connected(holder: .other, path: relayed) == "연결됨")
    }
}

@MainActor
@Suite struct AutoVPNModelTests {
    private let buildID = "b_9f3a1c2e"
    private let createPath = "/v1/builds/b_9f3a1c2e/sessions"

    private func harness(_ state: TunnelState = .off, configuration: VPNConfigurationState = .ready, offDelay: TimeInterval = 30) -> Harness {
        var timing = ClientModel.Timing.standard
        timing.autoOffDelay = offDelay
        let h = Harness(tunnel: state, storedHost: Harness.pairedHost, timing: timing)
        h.tunnel.autoStartConfiguration = configuration
        h.serveHostInfoAndBuilds()
        return h
    }

    @Test func refreshStartsTheVPNThenTurnsItOffWhenIdle() async {
        let h = harness()
        await h.model.restore()
        #expect(h.tunnel.autoStartCount == 1)
        // 구성을 저장하거나(동의 창) 다른 VPN을 바꾸는 길은 쓰지 않는다.
        #expect(h.tunnel.prepareCount == 0 && h.tunnel.connectCount == 0)
        #expect(h.model.tunnel == .connected)
        #expect(h.model.buildsLoadedAt != nil)
        #expect(h.model.lastError == nil && !h.model.needsTunnel)
        #expect(!h.model.isAutoStartingVPN)
        #expect(h.model.vpnAutoStarted)

        await h.waitUntil { h.tunnel.disconnectCount == 1 }
        #expect(h.tunnel.disconnectCount == 1)
        #expect(h.model.tunnel == .off)
        #expect(!h.model.vpnAutoStarted)
        // 가상 시계로 30초 이상 지난 뒤에 껐다.
        #expect(h.clock.now.timeIntervalSince(t0) >= 30)
    }

    @Test func withoutAnEnabledConfigurationNothingStarts() async {
        for configuration in [VPNConfigurationState.missing, .disabled] {
            let h = harness(configuration: configuration)
            await h.model.restore()
            #expect(h.tunnel.autoStartCount == 0)
            #expect(h.model.needsTunnel)
            #expect(h.model.lastError == ClientModel.tunnelOffMessage)
            #expect(!h.model.canReachHost)
        }
    }

    @Test func anotherAppsVPNIsUsedAndNeverTurnedOff() async {
        let h = harness(.connected)
        h.tunnel.holder = .pairedApp
        await h.model.restore()
        #expect(h.model.buildsLoadedAt != nil)
        #expect(h.tunnel.autoStartCount == 0)
        #expect(!h.model.vpnAutoStarted)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(h.tunnel.disconnectCount == 0)
    }

    @Test func loginNeededAfterStartShowsGuidanceAndKeepsTheVPN() async {
        let h = harness()
        h.tunnel.autoStartResult = .needsLogin(authURL: URL(string: "https://login.example.com/a/x"))
        await h.model.restore()
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.model.buildsLoadedAt == nil)
        #expect(h.model.lastError == ClientModel.tunnelNeedsLoginMessage)
        #expect(h.model.needsTunnel)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(h.tunnel.disconnectCount == 0)
        // 로그인이 끝나 연결되면 기다리던 새로고침을 이어 한다.
        h.tunnel.set(.connected)
        await h.waitUntil { h.model.buildsLoadedAt != nil }
        #expect(h.model.buildsLoadedAt != nil)
    }

    @Test func startFailureShowsTheOffGuidance() async {
        let h = harness()
        h.tunnel.autoStartError = URLError(.notConnectedToInternet)
        await h.model.restore()
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.model.lastError == ClientModel.tunnelOffMessage)
        #expect(!h.model.vpnAutoStarted)
    }

    @Test func manualConnectOrDisconnectClearsAutoStarted() async {
        let h = harness(offDelay: 100_000)
        await h.model.restore()
        #expect(h.model.vpnAutoStarted)
        await h.model.connectTunnel()
        #expect(!h.model.vpnAutoStarted)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(h.tunnel.disconnectCount == 0)

        let other = harness(offDelay: 100_000)
        await other.model.restore()
        await other.model.disconnectTunnel()
        #expect(!other.model.vpnAutoStarted)
        #expect(other.tunnel.disconnectCount == 1)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(other.tunnel.disconnectCount == 1)
    }

    @Test func installStartsTheVPNFirstAndHoldsItUntilTheInstallEnds() async throws {
        let h = harness(offDelay: 100_000)
        // 목록은 다른 VPN이 켜져 있을 때 받았고, 그 VPN이 꺼진 뒤 설치를 누른다.
        h.tunnel.holder = .other
        h.tunnel.set(.connected)
        await h.model.restore()
        h.tunnel.holder = nil
        h.tunnel.set(.off)
        await Task.yield()
        #expect(h.tunnel.autoStartCount == 0)

        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.opener.holds = true
        h.model.install(try Examples.buildDescriptor())
        #expect(h.model.installs[buildID] == .preparing)
        await h.waitUntil { h.opener.isWaiting }
        // VPN을 켠 뒤에 세션을 만들었다.
        #expect(h.tunnel.autoStartCount == 1)
        #expect(h.transport.count("POST", createPath) == 1)
        #expect(h.model.vpnAutoStarted)
        h.opener.release(false)
        await h.model.waitForBackgroundWork()
        #expect(h.tunnel.disconnectCount == 0)
    }

    @Test func idleOffWaitsForTheInstallAndFiresAfterItEnds() async throws {
        let h = harness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.opener.holds = true
        await h.model.restore()
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntil { h.opener.isWaiting }
        // 설치 창이 떠 있는 동안 가상 시계로 30초를 훨씬 넘겨도 끄지 않는다.
        let start = h.clock.now
        await h.waitUntil { h.clock.now.timeIntervalSince(start) >= 300 }
        #expect(h.clock.now.timeIntervalSince(start) >= 300)
        #expect(h.tunnel.disconnectCount == 0)
        #expect(h.model.vpnAutoStarted)

        h.opener.release(false)
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: ClientModel.openFailedMessage))
        // 끝난 상태를 지우지 않아도 진행 중인 설치가 없으면 끈다.
        await h.waitUntil { h.tunnel.disconnectCount == 1 }
        #expect(h.tunnel.disconnectCount == 1)
    }

    @Test func installReportsWhenTheVPNDoesNotConnect() async throws {
        let h = harness(offDelay: 100_000)
        h.tunnel.holder = .other
        h.tunnel.set(.connected)
        await h.model.restore()
        h.tunnel.holder = nil
        h.tunnel.set(.off)
        await Task.yield()
        h.tunnel.autoStartResult = .needsLogin(authURL: nil)
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: ClientModel.vpnLoginBeforeRetryMessage))
        #expect(h.transport.count("POST", createPath) == 0)
        #expect(h.opener.opened.isEmpty)
    }

    /// 설치 전에 앱이 모델을 거치지 않고 이 앱의 VPN을 켠 상태를 만든다(구성이 없어 자동으로 켤 수 없던 경우).
    private func harnessAfterInstallerConnected(offDelay: TimeInterval = 30) async -> Harness {
        let h = harness(configuration: .missing, offDelay: offDelay)
        await h.model.restore()
        #expect(h.tunnel.autoStartCount == 0)
        h.tunnel.autoStartConfiguration = .ready
        h.tunnel.set(.connected)
        return h
    }

    @Test func vpnStartedForAnInstallTurnsOffAfterTheInstallEnds() async throws {
        let h = await harnessAfterInstallerConnected()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.opener.holds = true
        h.model.noteAutoStartedVPN()
        #expect(h.model.vpnAutoStarted)
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntil { h.opener.isWaiting }
        // 설치가 진행되는 동안은 가상 시계로 30초를 훨씬 넘겨도 끄지 않는다.
        let start = h.clock.now
        await h.waitUntil { h.clock.now.timeIntervalSince(start) >= 300 }
        #expect(h.tunnel.disconnectCount == 0)
        #expect(h.model.vpnAutoStarted)

        h.opener.release(false)
        await h.model.waitForBackgroundWork()
        await h.waitUntil { h.tunnel.disconnectCount == 1 }
        #expect(h.tunnel.disconnectCount == 1)
        #expect(h.model.tunnel == .off)
        #expect(!h.model.vpnAutoStarted)
        #expect(h.tunnel.autoStartCount == 0)
    }

    @Test func vpnTakenOverForAnInstallStaysOn() async throws {
        let h = await harnessAfterInstallerConnected()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        // 짝 앱의 VPN을 넘겨받은 경우에는 앱이 사용자가 켠 VPN으로 알린다.
        h.model.noteManualVPNChange()
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(h.tunnel.disconnectCount == 0)
        #expect(!h.model.vpnAutoStarted)
    }

    @Test func manualChangeAfterAnInstallStartedVPNKeepsItOn() async {
        let h = await harnessAfterInstallerConnected()
        h.model.noteAutoStartedVPN()
        h.model.noteManualVPNChange()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(h.tunnel.disconnectCount == 0)
        #expect(!h.model.vpnAutoStarted)
    }

    @Test func installStartedVPNHeldByAnotherAppIsForgotten() async {
        let h = await harnessAfterInstallerConnected()
        h.tunnel.holder = .pairedApp
        h.model.noteAutoStartedVPN()
        await h.waitUntil { !h.model.vpnAutoStarted }
        #expect(!h.model.vpnAutoStarted)
        #expect(h.tunnel.disconnectCount == 0)
    }
}
