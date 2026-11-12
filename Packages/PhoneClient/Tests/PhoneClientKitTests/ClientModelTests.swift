import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

private let pairURL = URL(string: "remotedebug://pair?host=\(hostFQDN)&code=k7m2-9qxd")!
private let otherFQDN = "other-mac.example-tailnet.ts.net"
private let otherPairURL = URL(string: "remotedebug://pair?host=\(otherFQDN)&code=ABCD2345")!
private let otherApproved = Examples.pairApproved
    .replacingOccurrences(of: "h_4be0c7a1", with: "h_other000")
    .replacingOccurrences(of: "rd-mac-ab12cd34", with: "other-mac")
private let token = "Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE"
private let manifest = "https://\(hostFQDN)/i/\(token)/manifest.plist"
private func enc(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
}
private let otherInfo = Examples.info
    .replacingOccurrences(of: "h_4be0c7a1", with: "h_other000")
    .replacingOccurrences(of: "rd-mac-ab12cd34", with: "other-mac")

@MainActor
@Suite struct ClientModelPairingTests {
    @Test func approvedPairingSavesHostAndLoadsBuilds() async throws {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pair("pending")), .json(Examples.pairApproved))
        h.serveHostInfoAndBuilds()

        #expect(h.model.handle(url: pairURL))
        await h.model.waitForBackgroundWork()

        #expect(h.model.phase == .paired)
        #expect(h.model.host == PairedHost(hostId: "h_4be0c7a1", hostName: "작업용 Mac", fqdn: hostFQDN, pairedAt: t0.addingTimeInterval(2)))
        #expect(h.store.load() == h.model.host)
        #expect(h.model.builds.map(\.id) == ["b_9f3a1c2e"])
        #expect(h.model.buildsLoadedAt == t0.addingTimeInterval(2))
        #expect(h.model.lastError == nil)
        #expect(h.model.pairingExpiresAt == nil)
        // 페어링은 VPN 구성을 건드리지 않는다.
        #expect(h.tunnel.prepareCount == 0)
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 2)
        // 모든 요청은 링크의 호스트로만 갔다.
        #expect(h.transport.requests.allSatisfy { $0.url?.host == hostFQDN && $0.url?.scheme == "https" })
        #expect(h.transport.requests.first?.jsonBody?["code"] as? String == "K7M29QXD")
    }

    @Test func waitingApprovalPhaseWhilePolling() async throws {
        let h = Harness(clock: TestClock(mode: .blocking))
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.model.pair(code: "K7M2-9QXD", host: hostFQDN)
        await h.waitUntilSleeping()
        #expect(h.model.phase == .waitingApproval(deviceName: "내 iPhone"))
        // 호스트 expiresAt(t0+420)보다 로컬 제한(120초)이 이르다.
        #expect(h.model.pairingExpiresAt == t0.addingTimeInterval(120))
        h.model.cancelPairing()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.pairingExpiresAt == nil)
    }

    @Test(arguments: [
        ("denied", ClientModel.pairingDeniedMessage),
        ("expired", ClientModel.pairingExpiredMessage),
    ])
    func deniedOrExpired(_ state: String, _ message: String) async {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pair(state)))
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.lastError == message)
        #expect(h.store.load() == nil)
    }

    @Test func pendingUntilDeadlineExpires() async {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pair("pending")))
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.lastError == ClientModel.pairingExpiredMessage)
        // 1초마다 120번 + 마감 뒤 마지막 확인 1번.
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 121)
        #expect(h.clock.now == t0.addingTimeInterval(120))
    }

    @Test func deadlineIsClampedToEarlierHostExpiry() async {
        let h = Harness()
        let soon = Examples.pairPending.replacingOccurrences(of: "09:07:00Z", with: "09:00:30Z")
        h.transport.on("POST", "/v1/pair/request", .json(soon, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pair("pending")))
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.model.lastError == ClientModel.pairingExpiredMessage)
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 31)
        #expect(h.clock.now == t0.addingTimeInterval(30))
    }

    @Test func transientPollFailureIsRetried() async {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .fail(.networkConnectionLost), .fail(.timedOut), .json(Examples.pairApproved))
        h.serveHostInfoAndBuilds()
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .paired)
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 3)
    }

    @Test func approvalAfterLocalDeadlineIsTrusted() async {
        let clock = TestClock(mode: .blocking)
        let h = Harness(clock: clock)
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pairApproved))
        h.serveHostInfoAndBuilds(Examples.emptyBuilds)
        h.model.handle(url: pairURL)
        await h.waitUntilSleeping()
        h.model.stopPolling()
        await h.model.waitForBackgroundWork()

        clock.advance(by: 300)  // 잠긴 동안 Mac에서 승인했다
        clock.setMode(.instant)
        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .paired)
        #expect(h.model.host?.hostId == "h_4be0c7a1")
        #expect(h.model.lastError == nil)
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 1)
    }

    @Test func unreachableFinalCheckReportsExpiry() async {
        let clock = TestClock(mode: .blocking)
        let h = Harness(clock: clock)
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .fail(.cannotConnectToHost))
        h.model.handle(url: pairURL)
        await h.waitUntilSleeping()
        h.model.stopPolling()
        await h.model.waitForBackgroundWork()
        clock.advance(by: 300)
        clock.setMode(.instant)
        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.lastError == ClientModel.pairingExpiredMessage)
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 1)
    }

    @Test func approvedWithoutHostFails() async {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pair("approved")))
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.host == nil)
        #expect(h.store.load() == nil)
        #expect(h.model.lastError == "Mac에서 알 수 없는 응답을 받았습니다. 잠시 뒤 다시 시도하세요.")
    }

    @Test(arguments: [
        ("pair_code_invalid", 403, "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요."),
        ("too_many_attempts", 429, "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요."),
    ])
    func rejectedCode(_ code: String, _ status: Int, _ message: String) async {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .error(code, status: status))
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.lastError == message)
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 0)
    }

    @Test func approvedHostWithDifferentAddressIsRejected() async {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pairApproved.replacingOccurrences(of: "rd-mac-ab12cd34", with: "other-mac")))
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.lastError == ClientModel.pairedAddressMismatchMessage)
        #expect(h.store.load() == nil)
    }

    @Test func linkOutsidePolicySendsNothing() async {
        let h = Harness()
        #expect(h.model.handle(url: URL(string: "remotedebug://pair?host=evil.example.com&code=K7M29QXD")!))
        #expect(h.model.lastError == PairingLinkError.hostNotAllowed.userMessage)
        h.model.pair(code: "K7M29QXD", host: "127.0.0.1")
        h.model.pair(code: "K7M29QXD", host: "100.64.0.10")
        // 다른 정책으로 만든 링크도 모델의 정책으로 다시 거른다.
        h.model.pair(link: try! PairingLink(host: "localhost", code: "K7M29QXD", policy: .allowingLoopbackForTesting))
        await h.model.waitForBackgroundWork()
        #expect(h.transport.requests.isEmpty)
        #expect(h.tunnel.prepareCount == 0)
        #expect(h.model.phase == .unpaired)
        #expect(h.model.handle(url: URL(string: "https://example.com")!) == false)
    }

    @Test func tunnelOffBlocksPairingUntilConnected() async throws {
        let h = Harness(tunnel: .off)
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pairApproved))
        h.serveHostInfoAndBuilds()

        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.transport.requests.isEmpty)
        #expect(h.model.queuedPairing == PairingLink(url: pairURL))
        #expect(h.model.needsTunnel)
        #expect(h.model.lastError == ClientModel.tunnelOffMessage)
        #expect(h.model.phase == .unpaired)

        await h.model.connectTunnel()
        await h.model.waitForBackgroundWork()
        #expect(h.tunnel.prepareCount == 1)
        #expect(h.tunnel.connectCount == 1)
        #expect(h.model.tunnel == .connected)
        #expect(!h.model.needsTunnel)
        #expect(h.model.queuedPairing == nil)
        #expect(h.model.phase == .paired)
        #expect(h.model.lastError == nil)
        #expect(h.transport.count("POST", "/v1/pair/request") == 1)
    }

    @Test func cancelDropsQueuedPairing() async {
        let h = Harness(tunnel: .off)
        h.model.handle(url: pairURL)
        #expect(h.model.queuedPairing != nil)
        h.model.cancelPairing()
        #expect(h.model.queuedPairing == nil)
        h.tunnel.set(.connected)
        for _ in 0..<50 { await Task.yield() }
        await h.model.waitForBackgroundWork()
        #expect(h.transport.requests.isEmpty)
    }

    @Test func linkWithAuthKeyTurnsOnVPNThenPairs() async throws {
        let h = Harness(tunnel: .off)
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pairApproved))
        h.serveHostInfoAndBuilds()
        var usedKeys: [String] = []
        let tunnel = h.tunnel
        h.model.connectWithAuthKey = { key in
            usedKeys.append(key)
            tunnel.set(.connected)
        }
        let url = URL(string: pairURL.absoluteString + "&key=tskey-auth-kTest1CNTRL-abc")!
        #expect(h.model.handle(url: url))
        await h.waitUntil { !usedKeys.isEmpty }
        #expect(usedKeys == ["tskey-auth-kTest1CNTRL-abc"])
        await h.waitUntil { h.model.phase == .paired }
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .paired)
        #expect(h.transport.count("POST", "/v1/pair/request") == 1)
        #expect(h.model.lastError == nil)
        // 키는 로그에 남지 않는다.
        #expect(!h.model.logBook.recent.contains { $0.message.contains("tskey") })
    }

    @Test func linkWithAuthKeyDoesNotReconnectWhenVPNIsUp() async throws {
        let h = Harness(tunnel: .connected)
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        var used = 0
        h.model.connectWithAuthKey = { _ in used += 1 }
        h.model.handle(url: URL(string: pairURL.absoluteString + "&key=tskey-auth-kTest1CNTRL-abc")!)
        await h.waitUntil { h.transport.count("POST", "/v1/pair/request") == 1 }
        #expect(used == 0)
        h.model.cancelPairing()
    }

    @Test func refreshDoesNotReplaceQueuedPairing() async throws {
        let h = Harness(tunnel: .off, storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pairApproved))
        await h.model.restore()
        // 같은 Mac의 새 코드라 확인 없이 VPN을 기다린다.
        h.model.handle(url: pairURL)
        #expect(h.model.queuedPairing == PairingLink(url: pairURL))
        await h.model.refresh()  // 당겨서 새로고침
        #expect(h.model.queuedPairing == PairingLink(url: pairURL))

        await h.model.connectTunnel()
        await h.model.waitForBackgroundWork()
        #expect(h.transport.count("POST", "/v1/pair/request") == 1)
        #expect(h.transport.count("GET", "/v1/info") >= 1)
        #expect(h.model.phase == .paired)
        #expect(h.model.builds.count == 1)
    }

    @Test func tunnelNeedsLoginMessage() async {
        let h = Harness(tunnel: .needsLogin(authURL: URL(string: "https://login.tailscale.com/a/x")))
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.model.lastError == ClientModel.tunnelNeedsLoginMessage)
        #expect(h.transport.requests.isEmpty)
    }

    @Test func tunnelConnectFailure() async {
        let h = Harness(tunnel: .off)
        h.tunnel.connectError = URLError(.notConnectedToInternet)
        await h.model.connectTunnel()
        #expect(h.model.lastError == ClientModel.tunnelConnectFailedMessage)
        #expect(h.model.tunnel == .off)
    }

    @Test func tunnelPrepareFailureOnConnect() async {
        let h = Harness(tunnel: .off)
        h.tunnel.prepareError = URLError(.userCancelledAuthentication)
        await h.model.connectTunnel()
        #expect(h.model.lastError == ClientModel.tunnelPrepareFailedMessage)
        #expect(h.tunnel.connectCount == 0)
        #expect(h.model.tunnel == .off)
    }

    @Test func stopBeforePairingResponseReturnsToUnpaired() async {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.hold("POST", "/v1/pair/request")
        h.model.handle(url: pairURL)
        await h.waitUntil { h.transport.waiting("POST", "/v1/pair/request") == 1 }
        #expect(h.model.phase == .requestingPairing)
        h.model.stopPolling()
        h.transport.release("POST", "/v1/pair/request")
        await h.model.waitForBackgroundWork()
        for _ in 0..<20 { await Task.yield() }
        #expect(h.model.phase == .unpaired)
        #expect(h.model.lastError == nil)
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 0)
    }

    @Test func pairingPollCanBeStoppedAndResumed() async {
        let clock = TestClock(mode: .blocking)
        let h = Harness(clock: clock)
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pairApproved))
        h.serveHostInfoAndBuilds(Examples.emptyBuilds)
        h.model.handle(url: pairURL)
        await h.waitUntilSleeping()

        h.model.stopPolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .waitingApproval(deviceName: "내 iPhone"))
        #expect(h.transport.count("GET", "/v1/pair/request/pr_7c1e55d0") == 0)

        clock.setMode(.instant)
        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .paired)
        #expect(h.transport.count("POST", "/v1/pair/request") == 1)
        #expect(h.model.builds.isEmpty)
        #expect(h.model.buildsLoadedAt != nil)
    }

    // MARK: 같은 링크·다른 링크

    @Test func sameLinkWhileWaitingIsIgnored() async {
        let h = Harness(clock: TestClock(mode: .blocking))
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.model.handle(url: pairURL)
        await h.waitUntilSleeping()
        h.model.handle(url: pairURL)
        h.model.handle(url: URL(string: "remotedebug://pair?host=\(hostFQDN.uppercased())&code=K7M29QXD")!)
        await h.waitUntilSleeping(atLeast: 1)
        #expect(h.transport.count("POST", "/v1/pair/request") == 1)
        #expect(h.model.phase == .waitingApproval(deviceName: "내 iPhone"))
        #expect(h.model.pendingReplacement == nil)
        #expect(h.model.lastError == nil)
        h.model.cancelPairing()
    }

    @Test func sameLinkAfterApprovalIsIgnored() async {
        let h = Harness()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(Examples.pairApproved))
        h.serveHostInfoAndBuilds()
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        h.model.handle(url: pairURL)
        await h.model.waitForBackgroundWork()
        #expect(h.transport.count("POST", "/v1/pair/request") == 1)
        #expect(h.model.lastError == nil)
    }

    @Test func differentLinkWhileWaitingAsksFirst() async throws {
        let clock = TestClock(mode: .blocking)
        let h = Harness(clock: clock)
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.model.handle(url: pairURL)
        await h.waitUntilSleeping()

        let second = URL(string: "remotedebug://pair?host=\(hostFQDN)&code=ABCD2345")!
        h.model.handle(url: second)
        #expect(h.model.pendingReplacement == PairingLink(url: second))
        #expect(h.transport.count("POST", "/v1/pair/request") == 1)
        #expect(h.model.phase == .waitingApproval(deviceName: "내 iPhone"))

        h.model.confirmReplacement()
        #expect(h.model.pendingReplacement == nil)
        await h.waitUntilSleeping(atLeast: 2)
        #expect(h.transport.count("POST", "/v1/pair/request") == 2)
        #expect(h.transport.requests.last?.jsonBody?["code"] as? String == "ABCD2345")
        #expect(h.model.phase == .waitingApproval(deviceName: "내 iPhone"))
        h.model.cancelPairing()
    }

    @Test func linkForOtherMacAsksBeforeReplacing() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        await h.model.restore()

        #expect(h.model.handle(url: otherPairURL))
        #expect(h.model.pendingReplacement == PairingLink(url: otherPairURL))
        #expect(h.model.phase == .paired)
        h.model.dismissReplacement()
        await h.model.waitForBackgroundWork()
        #expect(h.model.pendingReplacement == nil)
        #expect(h.model.host == Harness.pairedHost)
        #expect(h.transport.count("POST", "/v1/pair/request") == 0)
    }

    @Test func failedPairingWithOtherMacKeepsCurrentMac() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        let prepares = h.tunnel.prepareCount
        h.transport.on("POST", "/v1/pair/request", .error("pair_code_invalid", status: 403))

        h.model.handle(url: otherPairURL)
        h.model.confirmReplacement()
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .paired)
        #expect(h.model.host == Harness.pairedHost)
        #expect(h.store.load() == Harness.pairedHost)
        #expect(h.model.builds.count == 1)
        #expect(h.tunnel.prepareCount == prepares)
        #expect(h.tunnel.connectCount == 0 && h.tunnel.disconnectCount == 0)
        #expect(h.model.tunnel == .connected)

        // 이후 요청은 지금 페어링한 Mac으로 간다.
        await h.model.refresh()
        #expect(h.transport.requests.last?.url?.host == hostFQDN)
        #expect(h.model.refreshError == nil)
    }

    @Test func cancelledPairingWithOtherMacKeepsCurrentMac() async throws {
        let clock = TestClock(mode: .blocking)
        let h = Harness(storedHost: Harness.pairedHost, clock: clock)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.model.handle(url: otherPairURL)
        h.model.confirmReplacement()
        await h.waitUntilSleeping()
        h.model.cancelPairing()
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .paired)
        #expect(h.model.host == Harness.pairedHost)
        #expect(h.model.builds.count == 1)
        #expect(h.tunnel.connectCount == 0 && h.tunnel.disconnectCount == 0)
    }

    @Test func pairingWithOtherMacResetsHostScopedState() async throws {
        let clock = TestClock(mode: .blocking)
        let h = Harness(storedHost: Harness.pairedHost, clock: clock)
        h.transport.on("GET", "/v1/info", .json(Examples.info), .json(otherInfo))
        h.transport.on("GET", "/v1/builds", .json(Examples.builds), .json(Examples.emptyBuilds))
        await h.model.restore()
        #expect(h.model.builds.count == 1)

        // 설치 창을 연 뒤 확인이 멈춘 세션 하나.
        h.transport.on("POST", "/v1/builds/b_9f3a1c2e/sessions", .json(Examples.sessionCreated, status: 201))
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntilSleeping()
        h.model.stopPolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs["b_9f3a1c2e"] == .waitingForInstaller)

        clock.setMode(.instant)
        h.transport.on("POST", "/v1/pair/request", .json(Examples.pairPending, status: 202))
        h.transport.on("GET", "/v1/pair/request/pr_7c1e55d0", .json(otherApproved))
        h.model.handle(url: otherPairURL)
        h.model.confirmReplacement()
        await h.model.waitForBackgroundWork()

        #expect(h.model.host?.fqdn == otherFQDN)
        #expect(h.model.host?.hostId == "h_other000")
        #expect(h.store.load()?.fqdn == otherFQDN)
        #expect(h.model.builds.isEmpty)
        #expect(h.model.installs.isEmpty)
        #expect(h.model.lastError == nil)

        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.transport.count("GET", "/v1/sessions/s_52d9a07e") == 0)
    }
}

@MainActor
@Suite struct ClientModelHostTests {
    @Test func restoreLoadsBuildsFromSavedHost() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds(Examples.emptyBuilds)
        #expect(h.model.buildsLoadedAt == nil)
        await h.model.restore()
        #expect(h.model.phase == .paired)
        #expect(h.model.host == Harness.pairedHost)
        // 받았지만 비어 있다(게시된 빌드 없음).
        #expect(h.model.builds.isEmpty)
        #expect(h.model.buildsLoadedAt == t0)
        #expect(h.model.lastError == nil)
        #expect(h.model.refreshError == nil)
        #expect(!h.model.isRefreshing)
        // 앱 시작은 VPN 구성을 저장하거나 켜지 않는다(사용자가 고른 다른 VPN을 바꾸지 않는다).
        #expect(h.tunnel.prepareCount == 0)
        #expect(h.transport.requests.map { $0.url?.absoluteString } == [
            "https://\(hostFQDN)/v1/info", "https://\(hostFQDN)/v1/builds",
            // 파일 목록은 빌드 목록 뒤에 따로 받는다.
            "https://\(hostFQDN)/v1/resources",
            // 목록을 받은 뒤 쌓인 진단 로그를 보낸다.
            "https://\(hostFQDN)/v1/logs",
        ])
    }

    @Test func restoreWithoutHost() async {
        let h = Harness()
        await h.model.restore()
        #expect(h.model.phase == .unpaired)
        #expect(h.transport.requests.isEmpty)
        #expect(h.tunnel.prepareCount == 0)
    }

    @Test(arguments: ["evil.example.com", "100.64.0.10"])
    func restoreDropsHostOutsidePolicy(_ fqdn: String) async {
        let h = Harness(storedHost: PairedHost(hostId: "h_x", hostName: "x", fqdn: fqdn, pairedAt: t0))
        await h.model.restore()
        #expect(h.model.phase == .unpaired)
        #expect(h.store.load() == nil)
        #expect(h.transport.requests.isEmpty)
    }

    @Test func restoreWithTunnelOffWaitsThenRefreshes() async {
        let h = Harness(tunnel: .off, storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        #expect(h.model.phase == .paired)
        #expect(h.model.needsTunnel)
        #expect(h.transport.requests.isEmpty)

        h.tunnel.set(.connected)  // 사용자가 설정 앱 등에서 VPN을 켬
        for _ in 0..<100 { await Task.yield() }
        await h.model.waitForBackgroundWork()
        #expect(h.model.builds.count == 1)
        #expect(!h.model.needsTunnel)
        #expect(h.model.lastError == nil)
    }

    @Test func restoreWithTunnelOffDoesNotTouchVPNConfiguration() async {
        let h = Harness(tunnel: .off, storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        #expect(h.tunnel.prepareCount == 0)
        #expect(h.tunnel.connectCount == 0)
        #expect(h.model.lastError == ClientModel.tunnelOffMessage)
        #expect(h.model.needsTunnel)

        // 구성 저장·켜기는 사용자가 VPN을 켤 때만 한다.
        await h.model.connectTunnel()
        await h.model.waitForBackgroundWork()
        #expect(h.tunnel.prepareCount == 1)
        #expect(h.tunnel.connectCount == 1)
        #expect(h.model.builds.count == 1)
        #expect(h.model.lastError == nil)
    }

    @Test func restoreDoesNotSurfacePrepareErrors() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.tunnel.prepareError = URLError(.userCancelledAuthentication)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        #expect(h.model.builds.count == 1)
        #expect(h.model.lastError == nil)
        #expect(h.tunnel.prepareCount == 0)
    }

    @Test func refreshReportsNotPaired() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.transport.on("GET", "/v1/info", .error("not_paired", status: 403))
        await h.model.restore()
        #expect(h.model.lastError == "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요.")
        #expect(h.model.refreshError == h.model.lastError)
        #expect(h.model.phase == .paired)
    }

    @Test func refreshDetectsDifferentHost() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.transport.on("GET", "/v1/info", .json(Examples.info.replacingOccurrences(of: "h_4be0c7a1", with: "h_other000")))
        await h.model.restore()
        #expect(h.model.lastError == ClientModel.hostChangedMessage)
        #expect(h.transport.count("GET", "/v1/builds") == 0)
    }

    @Test func refreshRejectsOtherProtocolVersion() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.transport.on("GET", "/v1/info", .json(Examples.info.replacingOccurrences(of: "\"protocol\": 1", with: "\"protocol\": 2")))
        await h.model.restore()
        #expect(h.model.lastError == "Mac 앱과 통신 규약 버전이 다릅니다. iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요.")
        #expect(h.model.refreshError == h.model.lastError)
        #expect(h.transport.count("GET", "/v1/builds") == 0)
        #expect(h.model.buildsLoadedAt == nil)
    }

    @Test func refreshConnectionFailure() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.transport.on("GET", "/v1/info", .fail(.cannotConnectToHost), .json(Examples.info))
        h.transport.on("GET", "/v1/builds", .json(Examples.builds))
        await h.model.restore()
        #expect(h.model.lastError == "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요.")
        #expect(h.model.refreshError == h.model.lastError)

        // 다시 성공하면 새로고침 실패 안내를 지운다.
        await h.model.refresh()
        #expect(h.model.refreshError == nil)
        #expect(h.model.lastError == nil)
        #expect(h.model.builds.count == 1)
    }

    @Test func forgetHostClearsEverything() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        #expect(h.model.builds.count == 1)
        await h.model.forgetHost()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.host == nil)
        #expect(h.model.builds.isEmpty)
        #expect(h.model.buildsLoadedAt == nil)
        #expect(h.store.load() == nil)
        #expect(h.tunnel.disconnectCount == 1)
        #expect(h.model.tunnel == .off)
        let before = h.transport.requests.count
        await h.model.refresh()
        #expect(h.transport.requests.count == before)
    }

    @Test func forgetHostDuringRefreshIgnoresLateFailure() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        h.transport.set("GET", "/v1/info", .fail(.timedOut))
        h.transport.hold("GET", "/v1/info")
        let refresh = Task { await h.model.refresh() }
        await h.waitUntil { h.transport.waiting("GET", "/v1/info") == 1 }
        #expect(h.model.isRefreshing)
        await h.model.forgetHost()
        h.transport.release("GET", "/v1/info")
        await refresh.value
        #expect(h.model.phase == .unpaired)
        #expect(h.model.lastError == nil)
        #expect(h.model.refreshError == nil)
        #expect(!h.model.isRefreshing)
    }

    @Test func forgetHostDuringRefreshIgnoresLateBuilds() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds(Examples.emptyBuilds)
        await h.model.restore()
        h.transport.set("GET", "/v1/builds", .json(Examples.builds))
        h.transport.hold("GET", "/v1/builds")
        let refresh = Task { await h.model.refresh() }
        await h.waitUntil { h.transport.waiting("GET", "/v1/builds") == 1 }
        await h.model.forgetHost()
        h.transport.release("GET", "/v1/builds")
        await refresh.value
        #expect(h.model.builds.isEmpty)
        #expect(h.model.buildsLoadedAt == nil)
        #expect(h.model.host == nil)
    }
}

@MainActor
@Suite struct ClientModelInstallTests {
    let buildID = "b_9f3a1c2e"
    let sessionPath = "/v1/sessions/s_52d9a07e"
    let createPath = "/v1/builds/b_9f3a1c2e/sessions"

    private func pairedHarness(clock: TestClock = TestClock(), tunnel: TunnelState = .connected) async -> Harness {
        let h = Harness(tunnel: tunnel, storedHost: Harness.pairedHost, clock: clock)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        return h
    }

    @Test func installProgressesToCompletion() async throws {
        let recorder = Recorder()
        let clock = TestClock { recorder.record() }
        let h = await pairedHarness(clock: clock)
        recorder.model = h.model
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath,
            .json(try Examples.sessionStatus(.created)),
            .json(try Examples.sessionStatus(.manifestServed)),
            .json(try Examples.sessionStatus(.downloading, served: 26_214_400)),
            .json(try Examples.sessionStatus(.completed, served: 52_428_800)))

        h.model.install(try Examples.buildDescriptor())
        #expect(h.model.installs[buildID] == .preparing)
        await h.model.waitForBackgroundWork()

        #expect(h.model.installs[buildID] == .completed)
        #expect(h.model.installs[buildID]?.message == "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요. 앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요.")
        #expect(h.model.installs[buildID]?.showsDeveloperModeHint == true)
        #expect(h.opener.opened.map(\.absoluteString) == [
            "itms-services://?action=download-manifest&url=https%3A%2F%2Frd-mac-ab12cd34.example-tailnet.ts.net%2Fi%2FZm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE%2Fmanifest.plist",
        ])
        // 매니페스트를 내준 뒤(manifest_served)에도 IPA 전송이 시작되기 전까지는 설치 창을 기다리는 상태다.
        #expect(recorder.seen == [
            .waitingForInstaller,
            .waitingForInstaller,
            .waitingForInstaller,
            .transferring(bytesServed: 26_214_400, size: 52_428_800),
        ])
        #expect(recorder.progress == [nil, nil, nil, InstallProgress(bytesServed: 26_214_400, size: 52_428_800)])
        #expect(InstallState.transferring(bytesServed: 26_214_400, size: 52_428_800).fraction == 0.5)
        #expect(h.model.installProgress(for: buildID) == nil)
        #expect(h.transport.count("POST", createPath) == 1)
        #expect(h.transport.count("GET", sessionPath) == 4)
        #expect(h.transport.requests.allSatisfy { $0.url?.host == hostFQDN })

        h.model.clearInstall(buildID)
        #expect(h.model.installs[buildID] == nil)
    }

    @Test func createSessionUsesLongTimeout() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        let create = try #require(h.transport.requests.first { $0.url?.path == createPath })
        #expect(create.timeoutInterval == 60)
        let info = try #require(h.transport.requests.first { $0.url?.path == "/v1/info" })
        #expect(info.timeoutInterval == 10)
    }

    @Test func createSessionTimeoutIsNotReportedAsVPNProblem() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .fail(.timedOut))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: ClientModel.createSessionTimeoutMessage))
    }

    @Test func openerFailure() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.opener.result = false
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: "설치 창을 열지 못했습니다. 설치를 다시 누르세요."))
        #expect(h.transport.count("GET", sessionPath) == 0)
    }

    @Test func sessionExpires() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.created)), .json(try Examples.sessionStatus(.expired)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .expired)
        #expect(h.model.installs[buildID]?.message == ClientModel.sessionExpiredMessage)
        #expect(h.model.installs[buildID]?.showsDeveloperModeHint == false)
    }

    @Test func sessionFails() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.created)), .json(try Examples.sessionStatus(.failed)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: ClientModel.sessionFailedMessage))
    }

    @Test func sessionPollingTimesOut() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.downloading, served: 1)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: ClientModel.installTimeoutMessage))
        // 1초마다 600번 + 마감 뒤 마지막 확인 1번.
        #expect(h.transport.count("GET", sessionPath) == 601)
    }

    @Test func completedAfterLocalDeadlineIsTrusted() async throws {
        let clock = TestClock(mode: .blocking)
        let h = await pairedHarness(clock: clock)
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed, served: 52_428_800)))
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntilSleeping()
        h.model.stopPolling()
        await h.model.waitForBackgroundWork()

        clock.advance(by: 900)  // 앱이 15분 동안 백그라운드에 있었다
        clock.setMode(.instant)
        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .completed)
        #expect(h.transport.count("GET", sessionPath) == 1)
    }

    @Test(arguments: [
        ("build_changed", 409, "Mac에서 빌드가 바뀌었습니다. 목록을 새로고침하세요."),
        ("build_not_found", 404, "Mac에 이 빌드가 없습니다. 목록을 새로고침하세요."),
        ("not_paired", 403, "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요."),
    ])
    func createSessionErrors(_ code: String, _ status: Int, _ message: String) async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .error(code, status: status))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: message))
        #expect(h.opener.opened.isEmpty)
    }

    @Test func statusTokenInvalidFails() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .error("token_invalid", status: 403))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: "설치 세션을 확인할 수 없습니다. 다시 설치하세요."))
    }

    @Test func transientConnectionLossIsRetried() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .fail(.networkConnectionLost), .json(try Examples.sessionStatus(.completed)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .completed)
    }

    @Test func installURLForOtherHostIsNotOpened() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated.replacingOccurrences(of: "%2F%2Frd-mac-ab12cd34", with: "%2F%2Fevil"), status: 201))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: ClientModel.untrustedInstallURLMessage))
        #expect(h.opener.opened.isEmpty)
    }

    @Test func installURLMustMatchManifestURL() async throws {
        let h = await pairedHarness()
        let body = Examples.sessionCreated.replacingOccurrences(of: "\"manifestUrl\": \"https://rd-mac", with: "\"manifestUrl\": \"https://x-rd-mac")
        h.transport.on("POST", createPath, .json(body, status: 201))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .failed(message: ClientModel.untrustedInstallURLMessage))
        #expect(h.opener.opened.isEmpty)
    }

    @Test func trustedInstallURLAccepted() throws {
        let ok = try #require(URL(string: "itms-services://?action=download-manifest&url=\(enc(manifest))"))
        #expect(ClientModel.isTrustedInstallURL(ok, manifestURL: URL(string: manifest), host: hostFQDN, policy: .tailnetOnly))
        let upper = try #require(URL(string: "itms-services://?action=download-manifest&url=\(enc(manifest.replacingOccurrences(of: "rd-mac", with: "RD-MAC")))"))
        #expect(ClientModel.isTrustedInstallURL(upper, manifestURL: nil, host: hostFQDN, policy: .tailnetOnly))
        let port443 = try #require(URL(string: "itms-services://?action=download-manifest&url=\(enc("https://\(hostFQDN):443/i/\(token)/manifest.plist"))"))
        #expect(ClientModel.isTrustedInstallURL(port443, manifestURL: nil, host: hostFQDN, policy: .tailnetOnly))
    }

    @Test(arguments: [
        ("duplicate url", "itms-services://?action=download-manifest&url=\(enc(manifest))&url=\(enc("https://evil.ts.net/i/\(token)/manifest.plist"))"),
        ("duplicate action", "itms-services://?action=download-manifest&action=download-manifest&url=\(enc(manifest))"),
        ("extra item", "itms-services://?action=download-manifest&url=\(enc(manifest))&x=1"),
        ("missing action", "itms-services://?url=\(enc(manifest))"),
        ("other action", "itms-services://?action=install&url=\(enc(manifest))"),
        ("outer authority", "itms-services://evil.example?action=download-manifest&url=\(enc(manifest))"),
        ("outer path", "itms-services:///x?action=download-manifest&url=\(enc(manifest))"),
        ("outer scheme", "https://?action=download-manifest&url=\(enc(manifest))"),
        ("userinfo", "itms-services://?action=download-manifest&url=\(enc("https://user:pw@\(hostFQDN)/i/\(token)/manifest.plist"))"),
        ("port", "itms-services://?action=download-manifest&url=\(enc("https://\(hostFQDN):8443/i/\(token)/manifest.plist"))"),
        ("path", "itms-services://?action=download-manifest&url=\(enc("https://\(hostFQDN)/v1/info"))"),
        ("short token", "itms-services://?action=download-manifest&url=\(enc("https://\(hostFQDN)/i/T/manifest.plist"))"),
        ("token chars", "itms-services://?action=download-manifest&url=\(enc("https://\(hostFQDN)/i/\(token.dropLast())%2E/manifest.plist"))"),
        ("other host", "itms-services://?action=download-manifest&url=\(enc("https://evil.ts.net/i/\(token)/manifest.plist"))"),
        ("trailing dot host", "itms-services://?action=download-manifest&url=\(enc("https://\(hostFQDN)./i/\(token)/manifest.plist"))"),
        ("http", "itms-services://?action=download-manifest&url=\(enc("http://\(hostFQDN)/i/\(token)/manifest.plist"))"),
        ("other scheme", "itms-services://?action=download-manifest&url=\(enc("ftp://\(hostFQDN)/i/\(token)/manifest.plist"))"),
        ("manifest query", "itms-services://?action=download-manifest&url=\(enc(manifest + "?a=b"))"),
        ("manifest fragment", "itms-services://?action=download-manifest&url=\(enc(manifest + "#x"))"),
    ])
    func untrustedInstallURLRejected(_ name: String, _ text: String) throws {
        let url = try #require(URL(string: text), "\(name)")
        #expect(!ClientModel.isTrustedInstallURL(url, manifestURL: nil, host: hostFQDN, policy: .tailnetOnly), "\(name)")
    }

    @Test func installURLRejectedWhenManifestURLDiffers() throws {
        let ok = try #require(URL(string: "itms-services://?action=download-manifest&url=\(enc(manifest))"))
        let other = URL(string: "https://\(hostFQDN)/i/\(token.dropLast())A/manifest.plist")
        #expect(!ClientModel.isTrustedInstallURL(ok, manifestURL: other, host: hostFQDN, policy: .tailnetOnly))
    }

    @Test func loopbackTestPolicyAllowsHTTPPort() throws {
        let url = try #require(URL(string: "itms-services://?action=download-manifest&url=\(enc("http://127.0.0.1:8080/i/\(token)/manifest.plist"))"))
        #expect(ClientModel.isTrustedInstallURL(url, manifestURL: nil, host: "127.0.0.1", policy: .allowingLoopbackForTesting))
        #expect(!ClientModel.isTrustedInstallURL(url, manifestURL: nil, host: "127.0.0.1", policy: .tailnetOnly))
    }

    @Test func duplicateInstallIsIgnored() async throws {
        let clock = TestClock(mode: .blocking)
        let h = await pairedHarness(clock: clock)
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        let build = try Examples.buildDescriptor()
        h.model.install(build)
        h.model.install(build)
        await h.waitUntilSleeping()
        h.model.install(build)
        #expect(h.transport.count("POST", createPath) == 1)
        #expect(h.opener.opened.count == 1)
        #expect(h.model.installs[buildID] == .waitingForInstaller)
        h.model.clearInstall(buildID)  // 진행 중이면 지우지 않는다
        #expect(h.model.installs[buildID] == .waitingForInstaller)
        h.model.stopPolling()
        await h.model.waitForBackgroundWork()
    }

    @Test func reopenInstallerOpensSameSessionURL() async throws {
        let clock = TestClock(mode: .blocking)
        let h = await pairedHarness(clock: clock)
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntilSleeping()
        #expect(h.model.installs[buildID] == .waitingForInstaller)

        await h.model.reopenInstaller(buildID)
        #expect(h.opener.opened.count == 2)
        #expect(h.opener.opened[0] == h.opener.opened[1])
        #expect(h.transport.count("POST", createPath) == 1)
        #expect(h.model.installs[buildID] == .waitingForInstaller)
        #expect(h.model.lastError == nil)

        h.opener.result = false
        await h.model.reopenInstaller(buildID)
        #expect(h.model.lastError == ClientModel.reopenFailedMessage)
        #expect(h.model.installs[buildID] == .waitingForInstaller)
        h.model.stopPolling()
        await h.model.waitForBackgroundWork()
    }

    @Test func reopenInstallerIgnoredWhenNotWaiting() async throws {
        let h = await pairedHarness()
        await h.model.reopenInstaller(buildID)
        #expect(h.opener.opened.isEmpty)
    }

    /// iOS는 설치 창에 앱 이름을 보여 주려고 매니페스트를 먼저 받는다. 사용자가 그 창을 닫으면 세션은 manifest_served에서 멈춘다.
    @Test func reopenAndCancelStayAvailableAfterManifestServed() async throws {
        let recorder = Recorder()
        recorder.stopAtSleep = 3  // 두 번째 확인(manifest_served) 뒤 첫 대기에서 진행 확인을 멈춘다
        let clock = TestClock { recorder.record() }
        let h = await pairedHarness(clock: clock)
        recorder.model = h.model
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.created)), .json(try Examples.sessionStatus(.manifestServed)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.transport.count("GET", sessionPath) == 2)
        #expect(h.model.installs[buildID] == .waitingForInstaller)

        await h.model.reopenInstaller(buildID)
        #expect(h.opener.opened.count == 2)
        #expect(h.opener.opened[0] == h.opener.opened[1])

        h.model.cancelInstall(buildID)
        #expect(h.model.installs[buildID] == nil)
    }

    /// IPA 전송이 시작된 뒤에는 설치 창을 다시 열거나 취소하지 않는다(같은 세션에서 전송이 겹친다).
    @Test func reopenAndCancelIgnoredWhileTransferring() async throws {
        let recorder = Recorder()
        recorder.stopAtSleep = 2  // 첫 확인(전송 시작) 뒤 첫 대기에서 진행 확인을 멈춘다
        let clock = TestClock { recorder.record() }
        let h = await pairedHarness(clock: clock)
        recorder.model = h.model
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.downloading, served: 1_048_576)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        let transferring = InstallState.transferring(bytesServed: 1_048_576, size: 52_428_800)
        #expect(h.model.installs[buildID] == transferring)
        #expect(h.opener.opened.count == 1)

        await h.model.reopenInstaller(buildID)
        #expect(h.opener.opened.count == 1)
        h.model.cancelInstall(buildID)
        #expect(h.model.installs[buildID] == transferring)
    }

    @Test func cancelInstallStopsWaitingAndAllowsNewSession() async throws {
        let clock = TestClock(mode: .blocking)
        let h = await pairedHarness(clock: clock)
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        let build = try Examples.buildDescriptor()
        h.model.install(build)
        await h.waitUntilSleeping()

        h.model.cancelInstall(buildID)
        #expect(h.model.installs[buildID] == nil)
        // 진행 확인 작업이 실제로 취소됐다. 남아 있으면 마감까지 돌며 취소한 행을 되살리고 새 세션을 지운다.
        await h.waitUntil { clock.cancelledSleeps == 1 }
        #expect(clock.cancelledSleeps == 1)
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == nil)
        // 멈춘 세션을 이어 가지 않는다. 세션이 남아 있다면 바로 호스트에 물어 GET이 나가도록(멈춰서 시험이 걸리지 않게) 시계를 즉시 모드로 둔다.
        clock.setMode(.instant)
        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.transport.count("GET", sessionPath) == 0)

        // 다시 설치하면 새 세션을 만든다.
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed)))
        h.model.install(build)
        await h.model.waitForBackgroundWork()
        #expect(h.transport.count("POST", createPath) == 2)
        #expect(h.model.installs[buildID] == .completed)
    }

    @Test func cancelInstallIgnoredAfterCompletion() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed)))
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        h.model.cancelInstall(buildID)
        #expect(h.model.installs[buildID] == .completed)
    }

    @Test func pollingStopAndResumeKeepsSession() async throws {
        let clock = TestClock(mode: .blocking)
        let h = await pairedHarness(clock: clock)
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed)))
        let build = try Examples.buildDescriptor()
        h.model.install(build)
        await h.waitUntilSleeping()

        h.model.stopPolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .waitingForInstaller)
        #expect(h.transport.count("GET", sessionPath) == 0)

        clock.setMode(.instant)
        h.model.install(build)  // 멈춘 세션의 확인을 이어 간다(새 세션 없음)
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .completed)
        #expect(h.transport.count("POST", createPath) == 1)

        // 끝난 뒤에는 새 세션으로 다시 설치할 수 있다.
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed)))
        h.model.install(build)
        await h.model.waitForBackgroundWork()
        #expect(h.transport.count("POST", createPath) == 2)
    }

    @Test func resumePollingRestartsStoppedInstall() async throws {
        let clock = TestClock(mode: .blocking)
        let h = await pairedHarness(clock: clock)
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed)))
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntilSleeping()
        h.model.stopPolling()
        await h.model.waitForBackgroundWork()

        clock.setMode(.instant)
        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .completed)
    }

    @Test func stopWhileInstallerOpensKeepsSessionForResume() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed)))
        h.opener.holds = true
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntil { h.opener.isWaiting }
        h.model.stopPolling()  // 설치 알림이 뜨며 앱이 비활성으로 감
        h.opener.release(true)
        await h.model.waitForBackgroundWork()
        for _ in 0..<20 { await Task.yield() }
        #expect(h.model.installs[buildID] == .waitingForInstaller)
        #expect(h.transport.count("GET", sessionPath) == 0)

        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs[buildID] == .completed)
    }

    @Test func forgetHostWhileInstallerOpensWritesNothing() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.on("GET", sessionPath, .json(try Examples.sessionStatus(.completed)))
        h.opener.holds = true
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntil { h.opener.isWaiting }
        await h.model.forgetHost()
        h.opener.release(true)
        for _ in 0..<50 { await Task.yield() }
        await h.model.waitForBackgroundWork()
        #expect(h.model.phase == .unpaired)
        #expect(h.model.installs.isEmpty)
        h.model.resumePolling()
        await h.model.waitForBackgroundWork()
        #expect(h.transport.count("GET", sessionPath) == 0)
    }

    @Test func forgetHostDuringCreateSessionWritesNothing() async throws {
        let h = await pairedHarness()
        h.transport.on("POST", createPath, .json(Examples.sessionCreated, status: 201))
        h.transport.hold("POST", createPath)
        h.model.install(try Examples.buildDescriptor())
        await h.waitUntil { h.transport.waiting("POST", createPath) == 1 }
        await h.model.forgetHost()
        h.transport.release("POST", createPath)
        for _ in 0..<50 { await Task.yield() }
        await h.model.waitForBackgroundWork()
        #expect(h.model.installs.isEmpty)
        #expect(h.opener.opened.isEmpty)
    }

    @Test func tunnelOffBlocksInstall() async throws {
        let h = await pairedHarness()
        h.tunnel.set(.off)
        await Task.yield()
        let before = h.transport.requests.count
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.transport.requests.count == before)
        #expect(h.model.installs[buildID] == nil)
        #expect(h.model.needsTunnel)
        #expect(h.model.lastError == ClientModel.tunnelOffMessage)
    }

    @Test func installWithoutHostDoesNothing() async throws {
        let h = Harness()
        h.model.install(try Examples.buildDescriptor())
        await h.model.waitForBackgroundWork()
        #expect(h.transport.requests.isEmpty)
        #expect(h.model.installs.isEmpty)
    }
}

@MainActor
private final class Recorder {
    weak var model: ClientModel?
    var seen: [InstallState?] = []
    var progress: [InstallProgress?] = []
    /// 이 번째 대기(1부터)를 기록한 직후 진행 확인을 멈춘다. 그 시점의 상태를 그대로 둔 채 시험하기 위한 것.
    var stopAtSleep: Int?
    func record() {
        guard let model else { return }
        seen.append(model.installs["b_9f3a1c2e"])
        progress.append(model.installProgress(for: "b_9f3a1c2e"))
        if seen.count == stopAtSleep { model.stopPolling() }
    }
}
