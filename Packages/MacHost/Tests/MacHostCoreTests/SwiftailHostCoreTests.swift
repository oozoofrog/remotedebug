import CryptoKit
import Foundation
import MacHostKit
import RDHostLogic
import RDModels
import Swiftail
import SwiftailCertificates
import SwiftailControl
import SwiftailHostServer
import Synchronization
import Testing

@testable import MacHostCore

// MARK: 도우미

/// 빌드 디스크 아래 임시 폴더(`RD_TEST_TMPDIR`).
final class CoreTempDir: @unchecked Sendable {
    let url: URL

    init(_ label: String) throws {
        let base = ProcessInfo.processInfo.environment["RD_TEST_TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("core-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var paths: HostPaths { HostPaths(root: url) }

    func config(listenTLS: Bool = true, directListen: Bool = false) throws -> CoreConfig {
        try paths.prepare()
        return CoreConfig(mode: .host, stateDir: paths.stateDir.path, hostname: "rd-mac-0000test", listenTLS: listenTLS,
                          publishDir: paths.publishedDir.path, logPath: paths.coreLogFile.path, hostDisplayName: "Mac",
                          appVersion: "0.2.0", directListen: directListen)
    }
}

/// 가짜 노드 층: 상태를 시험이 정하고, `run()`은 취소되거나 정한 실패로 끝난다.
final class FakeNode: HostNodeLayer, Sendable {
    struct State {
        var snapshot = NodeSnapshot()
        var certificate: CertificateSnapshot? = CertificateSnapshot(lastFailure: .nodeNotRunning)
        var serving = ServingState(listening: true, tlsReady: false)
        var runs = 0
        var retries = 0
        var failure: (any Error)?
    }

    let state = Mutex(State())
    /// 기다리는 `run()`과, 그것이 기다리기 전에 온 취소. 취소가 먼저 와도 잊지 않는다
    /// (`stop()`이 `start()` 바로 뒤에 오면 `onCancel`이 continuation보다 먼저 돈다).
    private let failGate = Mutex<(waiting: CheckedContinuation<Void, Never>?, cancelled: Bool)>((nil, false))

    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }

    /// `run()`을 이 실패로 끝낸다.
    func end(with error: any Error) {
        state.withLock { $0.failure = error }
        failGate.withLock { $0.waiting.take() }?.resume()
    }

    func run() async throws {
        state.withLock { $0.runs += 1 }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // 실패·취소 확인과 등록을 같은 잠금 안에서 한다: `end`·`onCancel`이 그 사이에 와도 놓치지 않는다.
                let resumeNow = failGate.withLock { gate -> Bool in
                    if gate.cancelled || state.withLock({ $0.failure != nil }) { return true }
                    gate.waiting = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            failGate.withLock { gate in
                gate.cancelled = true
                return gate.waiting.take()
            }?.resume()
        }
        failGate.withLock { $0.cancelled = false }
        if let failure = state.withLock({ $0.failure }) { throw failure }
    }

    func snapshot() async -> NodeSnapshot { state.withLock { $0.snapshot } }
    func certificateSnapshot() async -> CertificateSnapshot? { state.withLock { $0.certificate } }
    var serving: ServingState { state.withLock { $0.serving } }
    func retryCertificates() async { state.withLock { $0.retries += 1 } }
}

final class FakeFactory: Sendable {
    let node = FakeNode()
    let configurations = Mutex<[HostConfiguration]>([])
    let logOuts = Mutex<[NodeConfiguration]>([])
    let logOutError = Mutex<NodeError?>(nil)
    /// 노드 층이 받은 처리기(로직). 시험이 tailnet 요청을 흉내 내 직접 부른다.
    let handler = Mutex<(any HostRequestHandling)?>(nil)

    var factory: HostNodeFactory {
        HostNodeFactory(
            make: { [self] configuration, handler, _ in
                configurations.withLock { $0.append(configuration) }
                self.handler.withLock { $0 = handler }
                return node
            },
            logOut: { [self] configuration in
                logOuts.withLock { $0.append(configuration) }
                if let error = logOutError.withLock({ $0 }) { throw error }
            }
        )
    }

    func core(paths: HostPaths) -> SwiftailHostCore {
        SwiftailHostCore(layout: .init(directDirectory: paths.directDir, legacyStateDirectory: paths.legacyStateDir), factory: factory,
                         pollIntervals: (.milliseconds(20), .milliseconds(20)), directLoopbackOnly: true)
    }
}

/// 이벤트를 모은다.
final class EventSink: Sendable {
    final class Store: Sendable {
        let events = Mutex<[CoreEvent]>([])
        let ended = Mutex(false)
    }

    let store = Store()
    let task: Task<Void, Never>

    init(_ stream: AsyncStream<CoreEvent>) {
        let store = store
        task = Task {
            for await event in stream { store.events.withLock { $0.append(event) } }
            store.ended.withLock { $0 = true }
        }
    }

    var ended: Bool { store.ended.withLock { $0 } }
    var all: [CoreEvent] { store.events.withLock { $0 } }
    var states: [CoreStatus] { all.compactMap { if case .state(let s) = $0 { s } else { nil } } }
    var logs: [LogEvent] { all.compactMap { if case .log(let l) = $0 { l } else { nil } } }
}

/// 요청 본문(시험용).
final class BytesBody: HostBodyReader, Sendable {
    private let rest: Mutex<ArraySlice<UInt8>>
    init(_ bytes: [UInt8]) { rest = Mutex(bytes[...]) }
    func read(upTo count: Int) async throws -> [UInt8]? {
        rest.withLock { value in
            guard !value.isEmpty else { return nil }
            let chunk = Array(value.prefix(count))
            value = value.dropFirst(chunk.count)
            return chunk
        }
    }
}

func eventually(_ seconds: Double = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: 상태 대응

@Suite("상태 대응")
struct CoreStatusMappingTests {
    func status(_ phase: NodePhase = .running, node: NodeSnapshot, certificate: CertificateSnapshot? = nil,
                serving: ServingState = ServingState(listening: true, tlsReady: false)) -> CoreStatus {
        CoreStatusMapping.status(.init(phase: phase, node: node, certificate: certificate, serving: serving, hostname: "rd-mac-1a2b3c4d",
                                       counts: (2, 3), direct: nil, rssMiB: 12))
    }

    let running = NodeSnapshot(state: .running, addresses: ["100.64.0.1", "fd7a:115c:a1e0::1"], fqdn: "rd-mac-1a2b3c4d.tail0001.ts.net",
                               stableID: "nSTABLE", certDomains: ["rd-mac-1a2b3c4d.tail0001.ts.net"], peerCount: 2)

    @Test func nodeStatesMapToBackendStates() throws {
        #expect(status(node: NodeSnapshot(state: .starting)).backendState == .starting)
        let login = status(node: NodeSnapshot(state: .needsLogin(try #require(URL(string: "https://login.example.com/a/1")))))
        #expect(login.backendState == .needsLogin && login.authURL == "https://login.example.com/a/1")
        #expect(status(node: NodeSnapshot(state: .needsMachineAuth)).backendState == .needsMachineAuth)
        #expect(StatusGuidance.make(for: status(node: NodeSnapshot(state: .needsMachineAuth))).kind == .needsMachineAuth)

        let ready = status(node: running, serving: ServingState(listening: true, tlsReady: true))
        #expect(ready.backendState == .running && ready.tlsReady && ready.listening)
        #expect(ready.fqdn == "rd-mac-1a2b3c4d.tail0001.ts.net" && ready.tailscaleIPs.count == 2)
        #expect(ready.publishedBuilds == 2 && ready.pairedDevices == 3 && ready.hostname == "rd-mac-1a2b3c4d")
        #expect(ready.authURL.isEmpty && ready.lockWait == nil)
        #expect(StatusGuidance.make(for: ready).kind == .ready)
    }

    /// 로그인 필요의 두 모양(실행 중 needsLogin, `run()`이 nodeKeyExpired로 끝남)이 같은 상태로 보인다.
    @Test func bothLoginShapesShowNeedsLogin() throws {
        let ended = status(.ended(.nodeKeyExpired), node: running)
        #expect(ended.backendState == .needsLogin && ended.authURL.isEmpty && ended.errorMessage == nil)
        #expect(!ended.tlsReady && !ended.listening)
        let again = status(node: NodeSnapshot(state: .needsLogin(try #require(URL(string: "https://login.example.com/a/2")))))
        #expect(again.backendState == .needsLogin)
        #expect([StatusGuidance.Kind.waitingForLoginURL, .needsLogin].contains(StatusGuidance.make(for: ended).kind))
        #expect(NodeEnd(NodeError.control(.nodeKeyExpired)) == .nodeKeyExpired)
    }

    @Test func endedRunsAreErrors() {
        for end in [NodeEnd.authKeyRejected, .registrationRejected, .stateDirectoryInUse, .udpUnavailable, .other] {
            let s = status(.ended(end), node: running)
            #expect(s.backendState == .error && s.errorMessage?.isEmpty == false)
        }
        #expect(NodeEnd(NodeError.control(.authKeyRejected("x"))) == .authKeyRejected)
        #expect(NodeEnd(NodeError.stateDirectoryInUse) == .stateDirectoryInUse)
        #expect(NodeEnd(ConnectionError.addressInUse) == .listenFailed)
    }

    @Test func lockWaitOnlyWhileRunning() {
        var node = running
        node.signingRequest = LockWait(nodeKey: "nodekey:00", lockKey: "tlpub:00")
        #expect(status(node: node).lockWait?.signCommand == "tailscale lock sign nodekey:00 tlpub:00")
        #expect(StatusGuidance.make(for: status(node: node)).kind == .needsLockSignature)
        node.state = .starting
        #expect(status(node: node).lockWait == nil)
    }

    /// 사용자가 고칠 인증서 실패는 화면이 이미 아는 자리로 간다. 첫 발급 중과 물러난 실패는 "발급 중"이다.
    @Test func certificateFailuresUseExistingGuidance() {
        func kind(_ failure: CertificateFailure?, node: NodeSnapshot? = nil) -> StatusGuidance.Kind {
            StatusGuidance.make(for: status(node: node ?? running, certificate: CertificateSnapshot(lastFailure: failure))).kind
        }
        #expect(kind(nil) == .issuingCertificate)
        #expect(kind(.nodeNotRunning) == .issuingCertificate)
        #expect(kind(.acme(status: 500, type: "")) == .issuingCertificate)
        #expect(kind(.network("x")) == .issuingCertificate)
        #expect(kind(.timedOut) == .issuingCertificate)
        #expect(kind(.magicDNSDisabled) == .magicDNSDisabled)
        var noDomains = running
        noDomains.certDomains = []
        #expect(kind(.httpsNotEnabled, node: noDomains) == .certificatesDisabled)
        #expect(kind(.domainNotAllowed) == .error)
        #expect(kind(.rateLimited(retryAfter: Date(timeIntervalSince1970: 1_800_000_000))) == .error)
        // 쥔 인증서로 서 있으면 갱신 실패는 공유를 막지 않는다.
        let serving = status(node: running, certificate: CertificateSnapshot(lastFailure: .magicDNSDisabled),
                             serving: ServingState(listening: true, tlsReady: true))
        #expect(serving.backendState == .running)
    }

    @Test func baseURL() {
        #expect(CoreStatusMapping.baseURL(tls: true, fqdn: "a.ts.net.", port: 443) == "https://a.ts.net")
        #expect(CoreStatusMapping.baseURL(tls: true, fqdn: "a.ts.net", port: 8443) == "https://a.ts.net:8443")
        #expect(CoreStatusMapping.baseURL(tls: false, fqdn: "a.ts.net", port: 80) == "http://a.ts.net:80")
    }
}

// MARK: 코어

@Suite("SwiftailHostCore", .serialized, .timeLimit(.minutes(1)))
struct SwiftailHostCoreTests {
    @Test func callsBeforeStartReportNotRunning() async throws {
        let tmp = try CoreTempDir("idle")
        let core = FakeFactory().core(paths: tmp.paths)
        do {
            _ = try await core.status()
            Issue.record("상태가 나왔다")
        } catch let error as APIErrorBody {
            #expect(error.error.code == "not_running")
        }
        var count = 0
        for await _ in core.events() { count += 1 }
        #expect(count == 0)
        await core.stop()
    }

    @Test func configurationReachesTheNode() async throws {
        let tmp = try CoreTempDir("config")
        let fake = FakeFactory()
        let core = fake.core(paths: tmp.paths)
        var config = try tmp.config()
        config.authKey = "tskey-auth-example"
        config.controlURL = "https://control.example.com"
        try await core.start(config)
        defer { Task { await core.stop() } }
        let configuration = try #require(fake.configurations.withLock { $0.first })
        #expect(configuration.node.stateDirectory.path == tmp.paths.stateDir.path)
        #expect(configuration.node.hostname == "rd-mac-0000test")
        #expect(configuration.node.authKey == "tskey-auth-example")
        #expect(configuration.node.controlURL.absoluteString == "https://control.example.com")
        #expect(configuration.certificates?.directoryURL == CertificateConfiguration.letsEncryptDirectoryURL)
        #expect(configuration.certificates?.trustAnchors == nil)
        #expect(configuration.port == 443)
        await #expect(throws: APIErrorBody.self) { try await core.start(config) }
        await core.stop()

        var plain = try tmp.config(listenTLS: false)
        plain.port = 8080
        try await core.start(plain)
        #expect(fake.configurations.withLock { $0.last?.certificates } == nil)
        #expect(fake.configurations.withLock { $0.last?.port } == 8080)
        await core.stop()
    }

    @Test func invalidConfigurationIsRefused() async throws {
        let tmp = try CoreTempDir("invalid")
        let core = FakeFactory().core(paths: tmp.paths)
        var proxy = try tmp.config()
        proxy.mode = .proxy
        await #expect(throws: APIErrorBody.self) { try await core.start(proxy) }
        var noPublish = try tmp.config()
        noPublish.publishDir = tmp.url.appendingPathComponent("missing").path
        await #expect(throws: APIErrorBody.self) { try await core.start(noPublish) }
        var badControl = try tmp.config()
        badControl.controlURL = "ftp://x"
        await #expect(throws: APIErrorBody.self) { try await core.start(badControl) }
    }

    @Test func stateEventsFollowTheNodeAndStreamEndsOnStop() async throws {
        let tmp = try CoreTempDir("events")
        let fake = FakeFactory()
        let core = fake.core(paths: tmp.paths)
        try await core.start(try tmp.config())
        let sink = EventSink(core.events())
        #expect(await eventually { sink.states.last?.backendState == .starting })
        let url = try #require(URL(string: "https://login.example.com/a/secret-token"))
        fake.node.update { $0.snapshot.state = .needsLogin(url) }
        #expect(await eventually { sink.states.last?.authURL == url.absoluteString })
        fake.node.update {
            $0.snapshot = NodeSnapshot(state: .running, fqdn: "rd-mac-0000test.tail0001.ts.net", stableID: "nSELF",
                                       certDomains: ["rd-mac-0000test.tail0001.ts.net"])
            $0.serving.tlsReady = true
        }
        #expect(await eventually { sink.states.last?.backendState == .running && sink.states.last?.tlsReady == true })
        let status = try await core.status()
        #expect(status.fqdn == "rd-mac-0000test.tail0001.ts.net" && status.authURL.isEmpty)

        await core.stop()
        #expect(await eventually { sink.ended })
        await #expect(throws: APIErrorBody.self) { try await core.status() }
        // 로그인 URL은 로그 파일과 로그 이벤트에 남지 않는다.
        let log = (try? String(contentsOf: tmp.paths.coreLogFile, encoding: .utf8)) ?? ""
        #expect(!log.contains("secret-token") && log.contains("노드 상태: needsLogin"))
        #expect(!sink.logs.contains { $0.message.contains("secret-token") })
    }

    /// `run()`이 nodeKeyExpired로 끝나면 다시 로그인 상태가 되고, 노드를 다시 켜지 않는다.
    @Test func nodeKeyExpiryEndsInNeedsLoginWithoutRestart() async throws {
        let tmp = try CoreTempDir("expired")
        let fake = FakeFactory()
        let core = fake.core(paths: tmp.paths)
        try await core.start(try tmp.config())
        let sink = EventSink(core.events())
        fake.node.update { $0.snapshot.state = .running }
        fake.node.end(with: NodeError.control(.nodeKeyExpired))
        #expect(await eventually { sink.states.last?.backendState == .needsLogin })
        #expect(sink.states.last?.authURL.isEmpty == true)
        #expect(sink.logs.contains { $0.level == "warn" })
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.node.state.withLock { $0.runs } == 1)
        #expect(try await core.status().backendState == .needsLogin)
        await core.stop()
    }

    @Test func certificateRetryOnStartAndWhenDomainsChange() async throws {
        let tmp = try CoreTempDir("retry")
        let fake = FakeFactory()
        let core = fake.core(paths: tmp.paths)
        try await core.start(try tmp.config())
        #expect(await eventually { fake.node.state.withLock { $0.retries } == 1 })
        fake.node.update { $0.snapshot = NodeSnapshot(state: .running, fqdn: "a.tail0001.ts.net", certDomains: []) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(fake.node.state.withLock { $0.retries } == 1)
        fake.node.update {
            $0.snapshot.certDomains = ["a.tail0001.ts.net"]
            $0.certificate = CertificateSnapshot(lastFailure: .httpsNotEnabled)
        }
        #expect(await eventually { fake.node.state.withLock { $0.retries } == 2 })
        await core.stop()
    }

    /// 첫 `.running` 뒤에 Go 코어의 상태 폴더를 지운다. 직접 연결 신원은 먼저 옮기고, 관문 폴더는 건드리지 않는다.
    @Test func legacyStateIsRemovedAfterFirstRunKeepingDirectIdentity() async throws {
        let tmp = try CoreTempDir("legacy")
        let legacy = tmp.paths.legacyStateDir
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let goIdentity = try DirectIdentity(directory: legacy)
        try Data("go-state".utf8).write(to: legacy.appendingPathComponent("tailscaled.state"))
        let gate = tmp.url.appendingPathComponent("swiftail-gate")
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)

        let fake = FakeFactory()
        let core = fake.core(paths: tmp.paths)
        try await core.start(try tmp.config())
        // 노드가 뜨기 전에도 직접 연결은 옮긴 신원을 쓴다.
        try await core.setDirect(true)
        let before = try await core.status()
        #expect(before.direct?.id == goIdentity.id && before.direct?.listening == true)
        #expect(FileManager.default.fileExists(atPath: legacy.path))

        fake.node.update { $0.snapshot = NodeSnapshot(state: .running, stableID: "nSELF") }
        #expect(await eventually { !FileManager.default.fileExists(atPath: legacy.path) })
        #expect(FileManager.default.fileExists(atPath: gate.path))
        let moved = try DirectIdentity(directory: tmp.paths.directDir)
        #expect(moved.spki == goIdentity.spki && moved.id == goIdentity.id)
        // tailnet 노드의 안정 ID로 hostId를 기억한다(다음 실행에서 노드보다 먼저 답할 때 쓴다).
        #expect(await eventually { (try? DirectIdentity(directory: tmp.paths.directDir).hostID) == HostIDs.hostID(stableID: "nSELF") })

        try await core.setDirect(false)
        #expect(try await core.status().direct?.listening == false)
        await core.stop()
    }

    @Test func logOutRunsAfterStopAndToleratesFailure() async throws {
        let tmp = try CoreTempDir("logout")
        let fake = FakeFactory()
        let core = fake.core(paths: tmp.paths)
        let config = try tmp.config()
        // 등록한 적이 없으면 서버에 알리지 않는다.
        await core.logOut(config)
        #expect(fake.logOuts.withLock { $0.isEmpty })

        try Data("{}".utf8).write(to: tmp.paths.stateDir.appendingPathComponent("identity.json"))
        try await core.start(config)
        // 노드가 도는 동안에는 알리지 않는다(먼저 멈춰야 한다).
        await core.logOut(config)
        #expect(fake.logOuts.withLock { $0.isEmpty })
        await core.stop()
        #expect(fake.node.state.withLock { $0.runs } == 1)

        fake.logOutError.withLock { $0 = .control(.connection("timeout")) }
        await core.logOut(config)
        #expect(fake.logOuts.withLock { $0.map(\.stateDirectory.path) } == [tmp.paths.stateDir.path])
        let log = try String(contentsOf: tmp.paths.coreLogFile, encoding: .utf8)
        #expect(log.contains("로그아웃: 서버에 알리지 못함(control.connection)"))
    }

    /// 로직의 사건이 RDModels JSON에 없는 값(크래시를 받은 시각, 에이전트 요청의 노드 이름, 멈춤 요청의 기기 id)을 싣고
    /// 로직이 낸 순서대로 오며, `stop()`은 열린 세션의 `failed`까지 넘긴 뒤 스트림을 끝낸다.
    @Test func logicEventsCarryDetailsInOrderAndStopDrainsThem() async throws {
        let tmp = try CoreTempDir("details")
        let fake = FakeFactory()
        let core = fake.core(paths: tmp.paths)
        let config = try tmp.config()
        try await core.start(config)
        let sink = EventSink(core.events())
        let handler = try #require(fake.handler.withLock { $0 })
        let peer = HostPeer(stableID: "nPHONE1", nodeName: "rd-phone-1a2b3c4d", loginName: "")
        try await core.setDevices([DeviceEntry(id: "d_1", name: "시험 iPhone", nodeStableId: peer.stableID, nodeName: peer.nodeName,
                                               loginName: "", pairedAt: Date())])
        try await core.setAgentBoard(Data(#"{"enabled":true,"projects":[],"agents":[],"requests":[]}"#.utf8))
        func post(_ path: String, _ json: String = "") async -> Int {
            let body = Array(json.utf8)
            let headers = [("host", "rd-mac-0000test.example.ts.net")] + (body.isEmpty ? [] : [("content-type", "application/json")])
            return await handler.handle(HostRequest(method: "POST", target: path, headers: headers.map { (name: $0.0, value: $0.1) },
                                                    body: body.isEmpty ? nil : BytesBody(body), contentLength: UInt64(body.count),
                                                    origin: .tailnet(peer))).status
        }

        let before = Date()
        #expect(await post("/v1/crashes", #"{"kind":"feedback","name":"n","bundleId":"com.example.app","appVersion":"1.0","crashedAt":"2026-01-01T00:00:00Z","text":"t"}"#) == 202)
        #expect(await post("/v1/agent/requests", #"{"text":"hi","project":"","agent":"","continues":""}"#) == 202)
        let request = try #require(await { () async -> AgentRequestEvent? in
            _ = await eventually { sink.all.contains { if case .agentRequest = $0 { true } else { false } } }
            return sink.all.compactMap { if case .agentRequest(let e) = $0 { e } else { nil } }.first
        }())
        #expect(request.nodeName == peer.nodeName && request.deviceId == "d_1")
        #expect(await post("/v1/agent/requests/\(request.requestId)/cancel") == 202)
        #expect(await eventually { sink.all.contains { if case .agentCancel = $0 { true } else { false } } })
        let crash = try #require(sink.all.compactMap { if case .deviceCrash(let e) = $0 { e } else { nil } }.first)
        let receivedAt = try #require(crash.receivedAt)
        #expect(receivedAt >= before.addingTimeInterval(-1) && receivedAt <= Date())
        let cancel = try #require(sink.all.compactMap { if case .agentCancel(let e) = $0 { e } else { nil } }.first)
        #expect(cancel.deviceId == "d_1")
        let order = sink.all.compactMap { event -> String? in
            switch event {
            case .deviceCrash, .agentRequest, .agentCancel: event.type
            default: nil
            }
        }
        #expect(order == ["device-crash", "agent-request", "agent-cancel"])

        // 열린 세션: stop()이 끝나기 전에 그 `failed`가 스트림에 들어 있다.
        let ipa = tmp.paths.publishedDir.appendingPathComponent("a.ipa")
        let data = Data("0123456789".utf8)
        try data.write(to: ipa)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let buildID = HostIDs.buildID(bundleID: "com.example.app", sha256: sha)
        try await core.publish(PublishRequest(build: BuildDescriptor(
            id: buildID, bundleId: "com.example.app", displayName: "Sample", version: "1.0", buildNumber: "1", minOS: "26.0",
            debug: true, configuration: "Debug", configurationEvidence: .path,
            signing: .init(teamId: "EXAMPLE", profileName: "Example", profileExpires: Date().addingTimeInterval(3600),
                           provisionedDeviceCount: 1, getTaskAllow: true),
            ipa: .init(size: Int64(data.count), sha256: sha), publishedAt: Date()), ipaPath: ipa.path))
        #expect(await post("/v1/builds/\(buildID)/sessions") == 201)
        await core.stop()
        #expect(await eventually { sink.ended })
        let sessions = sink.all.compactMap { if case .session(let e) = $0 { e.state } else { nil } }
        #expect(sessions.first == .created && sessions.last == .failed)
    }
}
