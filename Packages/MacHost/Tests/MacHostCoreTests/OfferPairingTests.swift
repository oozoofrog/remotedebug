import CoreImage
import Foundation
import MacHostKit
import RDHostLogic
import RDModels
import Swiftail
import SwiftailHostServer
import SwiftailPairing
import Synchronization
import Testing

@testable import MacHostCore

/// 가짜 여는 쪽: 제안을 기록하고, 시험이 `join`으로 iPhone이 들어온 것처럼 `decide`를 부른다. 허용되면(그리고 `savesOnApprove`면)
/// 실제 `PairingHost`처럼 짝으로 저장한다.
final class FakePairingHost: PairingHosting, Sendable {
    struct State {
        var peers: [String: Date] = [:]
        var opened: [(lifetime: Int, authKey: String?)] = []
        var closed = 0
        var removed: [String] = []
        var savesOnApprove = true
        /// 참이면 허용된 뒤 거짓이 될 때까지 짝 저장을 미룬다(저장이 늦는 경우).
        var holdsSave = false
        /// 허용을 받은 `join` 수(저장 전).
        var approvals = 0
        var rejectsAuthKey = false
        var listening = false
        /// 승인을 기다리는 `decide` Task. 실제 `PairingHost`처럼 듣기가 끝나면 취소한다.
        var deciding: [Task<Bool, Never>] = []
    }

    static let secret = String(repeating: "A", count: 43)
    let state = Mutex(State())
    let decide: @Sendable (OfferPairingRequest) async -> Bool

    init(decide: @escaping @Sendable (OfferPairingRequest) async -> Bool) { self.decide = decide }

    func runListener() async throws {
        state.withLock { $0.listening = true }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        let deciding = state.withLock { value in
            defer { value.listening = false; value.deciding = [] }
            return value.deciding
        }
        for task in deciding { task.cancel() }
        for task in deciding { _ = await task.value }
    }

    func open(lifetimeSeconds: Int, authKey: String?) async throws(PairingError) -> PairingOffer {
        if authKey != nil, state.withLock({ $0.rejectsAuthKey }) { throw .invalidAuthKey }
        state.withLock { $0.opened.append((lifetimeSeconds, authKey)) }
        let key = authKey.map { "&k=\($0)" } ?? ""
        do {
            return try PairingOffer(link: "remotedebug://pair#v=1&h=rd-mac-0000test.example.ts.net&p=4747&s=\(Self.secret)&e=1794478500\(key)")
        } catch {
            throw .invalidConfiguration("시험 링크")
        }
    }

    func closeCurrentOffer() async { state.withLock { $0.closed += 1 } }
    func pairedAt(stableID: String) async -> Date? { state.withLock { $0.peers[stableID] } }
    func pairedStableIDs() async -> [String] { state.withLock { Array($0.peers.keys) } }
    func removePeer(stableID: String) async throws {
        state.withLock {
            $0.peers[stableID] = nil
            $0.removed.append(stableID)
        }
    }

    /// iPhone이 증명을 마치고 승인을 기다린다. 허용이면 짝으로 저장한다.
    func join(_ request: OfferPairingRequest) async -> Bool {
        let decide = decide
        let task = Task { await decide(request) }
        state.withLock { $0.deciding.append(task) }
        // iPhone이 끊는 것(이 Task의 취소)도 `decide`를 취소한다.
        let allowed = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard allowed else { return false }
        state.withLock { $0.approvals += 1 }
        while state.withLock({ $0.holdsSave }) { try? await Task.sleep(for: .milliseconds(10)) }
        if state.withLock({ $0.savesOnApprove }) { state.withLock { $0.peers[request.peer.stableID] = Date() } }
        return allowed
    }
}

/// 팩토리의 가짜가 남기는 것.
final class OfferStubs: Sendable {
    let host = Mutex<FakePairingHost?>(nil)
    let issued = Mutex<[Int]>([])
    let keyFailure = Mutex<TailscaleAPI.Failure?>(nil)
    /// 참이면 키 발급이 취소될 때까지 끝나지 않는다(관리 API가 느린 경우).
    let keyHangs = Mutex(false)
}

/// 가짜 노드 + 가짜 여는 쪽 + 가짜 키 발급으로 코어를 띄운다.
final class OfferHarness: Sendable {
    let tmp: CoreTempDir
    let fake = FakeFactory()
    let stubs = OfferStubs()
    let core: SwiftailHostCore
    let config: CoreConfig

    static let fqdn = "rd-mac-0000test.example.ts.net"
    static let key = "tskey-auth-kTEST1CNTRL-abcdef"
    static let client = TailscaleAPI.OAuthClient(id: "kClient", secret: "tskey-client-kClient-SECRET", tags: ["tag:rd-phone"])

    init(_ label: String, lockEnabled: Bool = false, saveTimeout: Duration = .seconds(1), linkBase: PairingLinkBase? = nil) throws {
        tmp = try CoreTempDir(label)
        var factory = fake.factory
        factory.makePairing = { [stubs] _, _, _, decide in
            let made = FakePairingHost(decide: decide)
            stubs.host.withLock { $0 = made }
            return made
        }
        factory.issueKey = { [stubs] _, seconds throws(TailscaleAPI.Failure) in
            stubs.issued.withLock { $0.append(seconds) }
            while stubs.keyHangs.withLock({ $0 }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            if Task.isCancelled { throw .cancelled }
            if let failure = stubs.keyFailure.withLock({ $0 }) { throw failure }
            return IssuedPairingKey(key: Self.key, expires: Date(timeIntervalSince1970: 1_794_478_800))
        }
        core = SwiftailHostCore(layout: .init(pairingDirectory: tmp.url.appending(path: "pairing"), pairingLinkBase: linkBase),
                                factory: factory, pollIntervals: (.milliseconds(20), .milliseconds(20)), offerSaveTimeout: saveTimeout)
        config = try tmp.config()
        fake.node.update {
            $0.snapshot = NodeSnapshot(state: .running, fqdn: Self.fqdn, stableID: "nMAC", certDomains: [Self.fqdn],
                                       tailnetLockEnabled: lockEnabled)
        }
    }

    var pairing: FakePairingHost { get throws { try #require(stubs.host.withLock { $0 }) } }
    var log: String { (try? String(contentsOf: tmp.paths.coreLogFile, encoding: .utf8)) ?? "" }

    static func request(_ stableID: String = "nPHONE1", code: String = "042917") -> OfferPairingRequest {
        OfferPairingRequest(peer: HostPeer(stableID: stableID, nodeName: "rd-phone-1a2b3c4d", loginName: "tagged-devices"),
                            deviceName: "시험 iPhone", confirmationCode: code)
    }
}

func pairRequests(_ sink: EventSink) -> [PairRequestEvent] {
    sink.all.compactMap { if case .pairRequest(let e) = $0 { e } else { nil } }
}

func pairDecisions(_ sink: EventSink) -> [PairDecidedEvent] {
    sink.all.compactMap { if case .pairDecided(let e) = $0 { e } else { nil } }
}

@Suite("QR 페어링")
struct OfferPairingTests {
    @Test func offerCarriesTheIssuedKeyAndClosesTheInstallPageCode() async throws {
        let h = try OfferHarness("offer-key", lockEnabled: true)
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let pairing = try h.pairing
        #expect(await eventually { pairing.state.withLock { $0.listening } })

        _ = try await h.core.openPairing(ttlSeconds: 300)
        #expect(pairing.state.withLock { $0.closed } == 1)

        let invite = try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: OfferHarness.client))
        #expect(h.stubs.issued.withLock { $0 } == [300])
        #expect(invite.authKey == .included(expires: Date(timeIntervalSince1970: 1_794_478_800)))
        // 키는 제안(QR)에만 실린다. 키가 든 링크는 내보내지 않는다.
        #expect(invite.link == nil)
        #expect(invite.qrImage != nil && invite.tailnetLockEnabled)
        #expect(pairing.state.withLock { $0.opened.map(\.lifetime) } == [300])
        #expect(pairing.state.withLock { $0.opened.map(\.authKey) } == [OfferHarness.key])
        // 설명과 로그에 비밀이 없다.
        #expect(!String(describing: invite).contains(FakePairingHost.secret) && !String(describing: invite).contains("tskey"))
        #expect(!h.log.contains(OfferHarness.key) && !h.log.contains(FakePairingHost.secret) && h.log.contains("페어링 QR을 엶(키 있음)"))

        // 제안을 열면 설치 페이지 코드는 닫혔다: 그 코드로 온 요청은 거절된다.
        let handler = try #require(h.fake.handler.withLock { $0 })
        let body = Array(#"{"code":"AAAAAAAA","deviceName":"x","platform":"ios","clientVersion":"1"}"#.utf8)
        let response = await handler.handle(HostRequest(
            method: "POST", target: "/v1/pair/request",
            headers: [(name: "host", value: OfferHarness.fqdn), (name: "content-type", value: "application/json")],
            body: BytesBody(body), contentLength: UInt64(body.count),
            origin: .tailnet(HostPeer(stableID: "nPHONE9", nodeName: "p", loginName: ""))))
        #expect(response.status == 403)
    }

    @Test func keyFailuresStillOpenAnOfferWithoutAKey() async throws {
        let h = try OfferHarness("offer-nokey")
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let pairing = try h.pairing

        let plain = try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: nil))
        let plainLink = try #require(plain.link)
        #expect(plain.authKey == .none && plainLink.absoluteString.hasPrefix("remotedebug://pair#v=1&h=rd-mac-0000test.example.ts.net&p=4747&"))
        #expect(!plainLink.absoluteString.contains("&k=") && h.stubs.issued.withLock { $0 }.isEmpty)

        h.stubs.keyFailure.withLock { $0 = .forbidden }
        let failed = try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: OfferHarness.client))
        #expect(failed.authKey == .failed(.forbidden) && failed.link?.absoluteString.contains("&k=") == false)
        #expect(h.log.contains("페어링 키를 만들지 못함(forbidden)"))

        // 발급된 키를 링크에 실을 수 없으면 키 없이 다시 연다.
        h.stubs.keyFailure.withLock { $0 = nil }
        pairing.state.withLock { $0.rejectsAuthKey = true }
        let unusable = try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: OfferHarness.client))
        #expect(unusable.authKey == .failed(.invalidResponse) && unusable.link?.absoluteString.contains("&k=") == false)
        #expect(h.log.contains("키 없이 엶") && !h.log.contains("페어링 QR을 엶(키 있음)"))

        await #expect(throws: APIErrorBody.self) {
            try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 0, oauthClient: nil))
        }
        // 노드가 아직 tailnet에 없으면 열지 않는다.
        h.fake.node.update { $0.snapshot = NodeSnapshot(state: .starting) }
        await #expect(throws: APIErrorBody.self) {
            try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: nil))
        }
    }

    @Test func withoutLinkBaseOffersUseTheCustomSchemeAndKeyedOffersAreQROnly() async throws {
        let h = try OfferHarness("offer-scheme")
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }

        let plain = try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: nil))
        #expect(plain.link?.absoluteString.hasPrefix("remotedebug://pair#v=1&") == true)
        #expect(QRText.read(plain.qrImage)?.hasPrefix("remotedebug://pair#v=1&") == true)

        let keyed = try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: OfferHarness.client))
        #expect(keyed.link == nil)
        let qr = try #require(QRText.read(keyed.qrImage))
        #expect(qr.hasPrefix("remotedebug://pair#v=1&") && qr.contains("&k=\(OfferHarness.key)"))
    }

    @Test func withLinkBaseOffersUseTheHTTPSLinkEvenWithAKey() async throws {
        let base = try #require(PairingLinkBase("https://example.com/remotedebug/pair"))
        let h = try OfferHarness("offer-https", linkBase: base)
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }

        let plain = try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: nil))
        let plainLink = try #require(plain.link).absoluteString
        #expect(plainLink.hasPrefix("https://example.com/remotedebug/pair#v=1&h=rd-mac-0000test.example.ts.net&p=4747&"))
        #expect(QRText.read(plain.qrImage) == plainLink)

        // 키를 실은 제안도 연결 도메인 링크로 낸다(복사 단추가 보인다).
        let keyed = try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: OfferHarness.client))
        let keyedLink = try #require(keyed.link).absoluteString
        #expect(keyed.authKey == .included(expires: Date(timeIntervalSince1970: 1_794_478_800)))
        #expect(keyedLink.hasPrefix("https://example.com/remotedebug/pair#v=1&") && keyedLink.contains("&k=\(OfferHarness.key)"))
        #expect(QRText.read(keyed.qrImage) == keyedLink)
        // 로그와 설명에는 링크가 없다.
        #expect(!h.log.contains("example.com") && !h.log.contains("tskey") && !String(describing: keyed).contains("example.com"))
    }

    @Test func offerLinkBaseRules() throws {
        let base = try #require(PairingLinkBase("https://example.com/remotedebug/pair"))
        #expect(SwiftailHostCore.offerLinkBase(nil, carriesKey: false) == (URL(string: "remotedebug://pair")!, true))
        #expect(SwiftailHostCore.offerLinkBase(nil, carriesKey: true) == (URL(string: "remotedebug://pair")!, false))
        #expect(SwiftailHostCore.offerLinkBase(base, carriesKey: false) == (base.url, true))
        #expect(SwiftailHostCore.offerLinkBase(base, carriesKey: true) == (base.url, true))
    }

    @Test func approvalAddsTheDeviceToTheAllowListWithTheSameEventsAsCodePairing() async throws {
        let h = try OfferHarness("offer-approve")
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let sink = EventSink(h.core.events())
        let pairing = try h.pairing
        try await h.core.setDevices([])

        let joined = Task { await pairing.join(OfferHarness.request()) }
        #expect(await eventually { pairRequests(sink).count == 1 })
        let request = try #require(pairRequests(sink).first)
        #expect(request.confirmationCode == "042917" && request.deviceName == "시험 iPhone" && request.nodeName == "rd-phone-1a2b3c4d")
        #expect(request.expiresAt > Date().addingTimeInterval(100))

        let device = try #require(try await h.core.decidePairing(requestID: request.requestId, allow: true))
        #expect(device.nodeStableId == "nPHONE1" && device.name == "시험 iPhone" && device.loginName == "tagged-devices")
        #expect(await joined.value)
        #expect(await eventually { pairDecisions(sink).contains(PairDecidedEvent(requestId: request.requestId, state: .approved)) })
        #expect(sink.all.contains(.deviceAdded(device)))
        // 허용 목록에 들어갔다: 그 기기의 요청이 통한다.
        #expect(try await h.core.status().pairedDevices == 1)
        // 확인 숫자는 로그에 없다.
        #expect(!h.log.contains("042917") && h.log.contains("QR 페어링을 허용함"))
        // 같은 요청에 두 번 답할 수 없다.
        await #expect(throws: APIErrorBody.self) { try await h.core.decidePairing(requestID: request.requestId, allow: true) }
    }

    @Test func denialAndDisconnectEndTheRequestWithoutAddingTheDevice() async throws {
        let h = try OfferHarness("offer-deny")
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let sink = EventSink(h.core.events())
        let pairing = try h.pairing

        let denied = Task { await pairing.join(OfferHarness.request()) }
        #expect(await eventually { pairRequests(sink).count == 1 })
        let first = try #require(pairRequests(sink).first)
        #expect(try await h.core.decidePairing(requestID: first.requestId, allow: false) == nil)
        #expect(await denied.value == false)
        #expect(await eventually { pairDecisions(sink).contains(PairDecidedEvent(requestId: first.requestId, state: .denied)) })

        // iPhone이 끊거나 120초가 지나 `decide`가 취소되면 곧 거절로 돌아가고 요청은 만료로 내린다.
        let gone = Task { await pairing.join(OfferHarness.request("nPHONE2")) }
        #expect(await eventually { pairRequests(sink).count == 2 })
        let second = pairRequests(sink)[1]
        gone.cancel()
        #expect(await gone.value == false)
        #expect(await eventually { pairDecisions(sink).contains(PairDecidedEvent(requestId: second.requestId, state: .expired)) })
        await #expect(throws: APIErrorBody.self) { try await h.core.decidePairing(requestID: second.requestId, allow: true) }

        #expect(!sink.all.contains { if case .deviceAdded = $0 { true } else { false } })
        #expect(try await h.core.status().pairedDevices == 0)
    }

    @Test func approvalThatThePairingHostDidNotSaveIsNotAllowed() async throws {
        let h = try OfferHarness("offer-unsaved")
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let sink = EventSink(h.core.events())
        let pairing = try h.pairing
        // 승인하는 순간 노드 신원이 바뀌었거나 저장에 실패한 경우: PairingHost가 짝으로 저장하지 않는다.
        pairing.state.withLock { $0.savesOnApprove = false }

        let joined = Task { await pairing.join(OfferHarness.request()) }
        #expect(await eventually { pairRequests(sink).count == 1 })
        let request = try #require(pairRequests(sink).first)
        await #expect(throws: APIErrorBody.self) { try await h.core.decidePairing(requestID: request.requestId, allow: true) }
        _ = await joined.value
        #expect(pairDecisions(sink).contains(PairDecidedEvent(requestId: request.requestId, state: .expired)))
        #expect(try await h.core.status().pairedDevices == 0)
    }

    /// 같은 노드의 예전 짝 기록은 이번 허용이 저장됐다는 증거가 아니다: 이번에 기록이 바뀌어야 허용 목록에 넣는다.
    @Test func anEarlierPairingOfTheSameNodeIsNotTakenAsThisApproval() async throws {
        let h = try OfferHarness("offer-earlier", saveTimeout: .milliseconds(400))
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let sink = EventSink(h.core.events())
        let pairing = try h.pairing
        // 방금(1초 안에) 짝이 된 같은 노드가 다시 페어링한다. 이번 요청은 저장되지 않는다(끊김·저장 실패).
        pairing.state.withLock {
            $0.peers["nPHONE1"] = Date()
            $0.savesOnApprove = false
        }
        try await h.core.setDevices([DeviceEntry(id: "d_1", name: "예전 이름", nodeStableId: "nPHONE1", nodeName: "rd-phone-1a2b3c4d",
                                                 loginName: "tagged-devices", pairedAt: Date())])
        let joined = Task { await pairing.join(OfferHarness.request()) }
        #expect(await eventually { pairRequests(sink).count == 1 })
        let request = try #require(pairRequests(sink).first)
        await #expect(throws: APIErrorBody.self) { try await h.core.decidePairing(requestID: request.requestId, allow: true) }
        _ = await joined.value
        #expect(pairDecisions(sink).map(\.state) == [.expired])
        #expect(!sink.all.contains { if case .deviceAdded = $0 { true } else { false } })
    }

    /// 기한이 지나 실패로 끝낸 뒤에 늦게 저장된 짝은 허용 목록에 없으므로 짝 목록에서 지운다.
    @Test func aSaveThatArrivesAfterTheTimeoutIsRemovedFromThePairedList() async throws {
        let h = try OfferHarness("offer-late", saveTimeout: .milliseconds(300))
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let sink = EventSink(h.core.events())
        let pairing = try h.pairing
        try await h.core.setDevices([])
        pairing.state.withLock { $0.holdsSave = true }

        let joined = Task { await pairing.join(OfferHarness.request()) }
        #expect(await eventually { pairRequests(sink).count == 1 })
        let request = try #require(pairRequests(sink).first)
        await #expect(throws: APIErrorBody.self) { try await h.core.decidePairing(requestID: request.requestId, allow: true) }
        #expect(pairing.state.withLock { $0.peers.isEmpty })

        pairing.state.withLock { $0.holdsSave = false }
        #expect(await joined.value)
        #expect(await eventually { pairing.state.withLock { $0.removed } == ["nPHONE1"] && pairing.state.withLock { $0.peers.isEmpty } })
        #expect(try await h.core.status().pairedDevices == 0)
    }

    /// 허용한 뒤 저장을 기다리는 사이 공유를 멈추고 다시 시작해도, 앞 실행의 허용은 새 실행의 허용 목록·사건에 들어가지 않는다.
    @Test func stoppingWhileAnApprovalIsBeingSavedDoesNotLeakIntoTheNextRun() async throws {
        let h = try OfferHarness("offer-restart", saveTimeout: .seconds(5))
        try await h.core.start(h.config)
        let sink = EventSink(h.core.events())
        let first = try h.pairing
        try await h.core.setDevices([])
        first.state.withLock { $0.holdsSave = true }

        let joined = Task { await first.join(OfferHarness.request()) }
        #expect(await eventually { pairRequests(sink).count == 1 })
        let request = try #require(pairRequests(sink).first)
        let decided = Task { try await h.core.decidePairing(requestID: request.requestId, allow: true) }
        #expect(await eventually { first.state.withLock { $0.approvals } == 1 })

        // 멈춤은 허용의 마무리를 기다린다(기한 5초보다 훨씬 빨리 끝난다). 그 요청은 만료로 끝난다.
        let clock = ContinuousClock()
        let stopTime = await clock.measure { await h.core.stop() }
        #expect(stopTime < .seconds(3))
        #expect(pairDecisions(sink).map(\.state) == [.expired])

        try await h.core.start(h.config)
        let next = EventSink(h.core.events())
        try await h.core.setDevices([])
        // 앞 실행의 PairingHost가 이제야 저장한다.
        first.state.withLock { $0.holdsSave = false }
        _ = await joined.value
        await #expect(throws: APIErrorBody.self) { try await decided.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!sink.all.contains { if case .deviceAdded = $0 { true } else { false } })
        #expect(!next.all.contains { if case .deviceAdded = $0 { true } else { false } })
        #expect(!next.all.contains { if case .pairDecided = $0 { true } else { false } })
        #expect(try await h.core.status().pairedDevices == 0)
        await h.core.stop()
    }

    /// 키를 만드는 사이 화면이 열기를 취소하면 설치 페이지 코드를 닫지 않고 제안도 열지 않는다.
    @Test func aCancelledOfferLeavesTheInstallPageCodeOpen() async throws {
        let h = try OfferHarness("offer-cancel")
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let pairing = try h.pairing
        h.stubs.keyHangs.withLock { $0 = true }
        let opening = Task { try await h.core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: OfferHarness.client)) }
        #expect(await eventually { h.stubs.issued.withLock { $0 } == [300] })
        let code = try await h.core.openPairing(ttlSeconds: 300)
        opening.cancel()
        await #expect(throws: (any Error).self) { try await opening.value }
        #expect(pairing.state.withLock { $0.opened }.isEmpty)

        // 그 코드는 아직 쓸 수 있다.
        let handler = try #require(h.fake.handler.withLock { $0 })
        let body = Array(#"{"code":"\#(code.code)","deviceName":"x","platform":"ios","clientVersion":"1"}"#.utf8)
        let response = await handler.handle(HostRequest(
            method: "POST", target: "/v1/pair/request",
            headers: [(name: "host", value: OfferHarness.fqdn), (name: "content-type", value: "application/json")],
            body: BytesBody(body), contentLength: UInt64(body.count),
            origin: .tailnet(HostPeer(stableID: "nPHONE9", nodeName: "p", loginName: ""))))
        #expect((200..<300).contains(response.status))
    }

    /// 두 목록이 어긋났을 때: 허용 목록이 기준이다. 허용 목록에만 있는 기기(코드 페어링, 옮기기 전의 짝)는 그대로 쓰고,
    /// 짝 목록에만 있는 기기(공유가 꺼졌을 때 지운 기기 등)는 짝 목록에서 지운다. 기기를 지우면 짝 목록에서도 지운다.
    @Test func pairedPeersAreKeptASubsetOfTheAllowList() async throws {
        let h = try OfferHarness("offer-reconcile")
        try await h.core.start(h.config)
        defer { Task { await h.core.stop() } }
        let pairing = try h.pairing
        pairing.state.withLock { $0.peers = ["nPHONE1": Date(), "nREMOVED": Date()] }
        func device(_ id: String) -> DeviceEntry {
            DeviceEntry(id: "d_" + id, name: id, nodeStableId: id, nodeName: id, loginName: "", pairedAt: Date())
        }

        try await h.core.setDevices([device("nPHONE1"), device("nCODEONLY")])
        #expect(pairing.state.withLock { $0.removed } == ["nREMOVED"])
        #expect(Set(await pairing.pairedStableIDs()) == ["nPHONE1"])
        #expect(try await h.core.status().pairedDevices == 2)

        try await h.core.setDevices([device("nCODEONLY")])
        #expect(pairing.state.withLock { $0.removed } == ["nREMOVED", "nPHONE1"])
        #expect(await pairing.pairedStableIDs().isEmpty)
    }

    @Test func stopCancelsAWaitingApprovalAndRestartAttachesAgain() async throws {
        let h = try OfferHarness("offer-stop")
        try await h.core.start(h.config)
        let sink = EventSink(h.core.events())
        let pairing = try h.pairing
        let waiting = Task { await pairing.join(OfferHarness.request()) }
        #expect(await eventually { pairRequests(sink).count == 1 })
        await h.core.stop()
        #expect(await waiting.value == false)
        #expect(!pairing.state.withLock { $0.listening })
        #expect(pairDecisions(sink).map(\.state) == [.expired])

        try await h.core.start(h.config)
        let again = try h.pairing
        #expect(again !== pairing)
        #expect(await eventually { again.state.withLock { $0.listening } })
        await h.core.stop()
    }

    @Test func oauthClientCheckUsesTheIssuerRules() {
        let core = SwiftailHostCore()
        #expect(core.checkOAuthClient(OfferHarness.client) == nil)
        #expect(core.checkOAuthClient(.init(id: "k Client", secret: "tskey-client-x", tags: ["tag:a"])) == .badClient)
        #expect(core.checkOAuthClient(.init(id: "k", secret: "secret", tags: ["tag:a"])) == .badClient)
        #expect(core.checkOAuthClient(.init(id: "k", secret: "tskey-client-x", tags: ["tag:1a"])) == .badTags)
        #expect(PairingKeys.failure(.clientRejected) == .clientRejected && PairingKeys.failure(.http(status: 500)) == .http(500))
        #expect(PairingKeys.failure(.cancelled) == .cancelled && PairingKeys.failure(.network) == .network)
    }
}

/// 실제 `PairingHost`(돌지 않는 Swiftail 노드 위): 다시 시작해도 짝 목록 폴더를 다시 차지할 수 있고, 노드에 아직 FQDN이 없으면
/// 제안을 열지 않는다.
@Suite("QR 페어링: 실제 PairingHost")
struct RealPairingHostTests {
    @Test func restartReattachesAndOfferNeedsARunningNode() async throws {
        let tmp = try CoreTempDir("offer-real")
        let fake = FakeFactory()
        let nodeDirectory = tmp.url.appending(path: "node")
        try FileManager.default.createDirectory(at: nodeDirectory, withIntermediateDirectories: true)
        let stubs = OfferStubs()
        var factory = fake.factory
        factory.makePairing = { [stubs] _, port, directory, decide in
            let node = try TailnetNode(configuration: NodeConfiguration(stateDirectory: nodeDirectory, hostname: "rd-mac-0000test"),
                                       device: .inProcess)
            let host = try await PairingHost(node: node, port: port, storeDirectory: directory) { request in
                await decide(OfferPairingRequest(peer: HTTPListener.peer(request.peer), deviceName: request.deviceName,
                                                 confirmationCode: request.confirmationCode))
            }
            stubs.issued.withLock { $0.append(Int(port)) }
            return host
        }
        let core = SwiftailHostCore(layout: .init(pairingDirectory: tmp.url.appending(path: "pairing")), factory: factory,
                                    pollIntervals: (.milliseconds(20), .milliseconds(20)))
        fake.node.update {
            $0.snapshot = NodeSnapshot(state: .running, fqdn: "rd-mac-0000test.example.ts.net", stableID: "nMAC")
        }
        let config = try tmp.config()
        for _ in 0..<2 {
            try await core.start(config)
            // 코어 상태는 돌지만 Swiftail 노드에는 아직 자기 FQDN이 없다: PairingHost가 notRunning으로 거절한다.
            do {
                _ = try await core.openPairingOffer(PairingInviteRequest(lifetimeSeconds: 300, oauthClient: nil))
                Issue.record("열리면 안 된다")
            } catch let error as APIErrorBody {
                #expect(error.error.code == "not_running")
            }
            await core.stop()
        }
        #expect(stubs.issued.withLock { $0 } == [4747, 4747])
        let log = (try? String(contentsOf: tmp.paths.coreLogFile, encoding: .utf8)) ?? ""
        #expect(!log.contains("QR 페어링을 준비하지 못함"))
    }
}

/// 코어가 만든 QR 그림(모듈 하나가 한 화소)을 키워서 글자를 읽는다.
enum QRText {
    static func read(_ image: CGImage?) -> String? {
        guard let image else { return nil }
        let scaled = CIImage(cgImage: image).samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: scaled).first as? CIQRCodeFeature)?.messageString
    }
}
