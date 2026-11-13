import Foundation
import RDModels
import Synchronization

@testable import PhoneClientKit

let hostFQDN = "rd-mac-ab12cd34.example-tailnet.ts.net"
let t0 = Date(timeIntervalSince1970: 1_794_387_600)  // 2026-11-11T09:00:00Z

/// docs/protocol.md 예제 문자열.
enum Examples {
    static let info = """
    {
      "hostId": "h_4be0c7a1",
      "hostName": "작업용 Mac",
      "fqdn": "rd-mac-ab12cd34.example-tailnet.ts.net",
      "protocol": 1,
      "appVersion": "0.1.0",
      "buildCount": 1
    }
    """
    static let emptyBuilds = #"{ "builds": [] }"#
    static let build = """
    {
      "id": "b_9f3a1c2e",
      "bundleId": "com.example.app.Sample",
      "displayName": "Sample",
      "version": "1.4.0",
      "buildNumber": "128",
      "minOS": "26.0",
      "debug": true,
      "configuration": "Debug",
      "configurationEvidence": "path",
      "signing": {
        "teamId": "ABCDE12345",
        "profileName": "iOS Team Provisioning Profile: com.example.app.Sample",
        "profileExpires": "2027-05-01T00:00:00Z",
        "provisionedDeviceCount": 27,
        "getTaskAllow": true
      },
      "ipa": {
        "size": 52428800,
        "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
      },
      "publishedAt": "2026-11-11T09:00:00Z"
    }
    """
    static var builds: String { #"{ "builds": [ "# + build + " ] }" }
    static let pairPending = """
    {
      "requestId": "pr_7c1e55d0",
      "state": "pending",
      "expiresAt": "2026-11-11T09:07:00Z"
    }
    """
    static let pairApproved = """
    {
      "requestId": "pr_7c1e55d0",
      "state": "approved",
      "host": {
        "hostId": "h_4be0c7a1",
        "hostName": "작업용 Mac",
        "fqdn": "rd-mac-ab12cd34.example-tailnet.ts.net"
      }
    }
    """
    static func pair(_ state: String) -> String { #"{"requestId":"pr_7c1e55d0","state":"\#(state)"}"# }
    static let sessionCreated = """
    {
      "sessionId": "s_52d9a07e",
      "state": "created",
      "manifestUrl": "https://rd-mac-ab12cd34.example-tailnet.ts.net/i/Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE/manifest.plist",
      "installUrl": "itms-services://?action=download-manifest&url=https%3A%2F%2Frd-mac-ab12cd34.example-tailnet.ts.net%2Fi%2FZm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE%2Fmanifest.plist",
      "expiresAt": "2026-11-11T09:03:00Z"
    }
    """
    static func sessionStatus(_ state: SessionState, served: Int64 = 0) throws -> String {
        let s = SessionStatus(sessionId: "s_52d9a07e", buildId: "b_9f3a1c2e", state: state, bytesServed: served, size: 52_428_800, expiresAt: t0.addingTimeInterval(180))
        return String(decoding: try RDJSON.encoder().encode(s), as: UTF8.self)
    }

    static func buildDescriptor() throws -> BuildDescriptor {
        try RDJSON.decoder().decode(BuildDescriptor.self, from: Data(build.utf8))
    }
}

struct Reply: Sendable {
    var status: Int
    var body: String
    var headers: [String: String]
    var failure: URLError?

    static func json(_ body: String, status: Int = 200) -> Reply {
        Reply(status: status, body: body, headers: ["X-RD-Protocol": "1", "Content-Type": "application/json"])
    }

    static func error(_ code: String, status: Int) -> Reply {
        json(#"{"error":{"code":"\#(code)","message":"host says \#(code)"}}"#, status: status)
    }

    static func fail(_ code: URLError.Code) -> Reply {
        Reply(status: 0, body: "", headers: [:], failure: URLError(code))
    }
}

/// 경로별 응답 큐. 마지막 응답은 계속 반복한다.
/// `hold`한 경로의 요청은 `release`할 때까지 응답하지 않고 멈춘다(진행 중 요청과 겹치는 경쟁 시험용).
final class FakeTransport: HTTPTransport {
    private struct State {
        var routes: [String: [Reply]] = [:]
        var requests: [URLRequest] = []
        var held: Set<String> = []
        var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    }
    private let state = Mutex(State())

    func on(_ method: String, _ path: String, _ replies: Reply...) {
        state.withLock { $0.routes["\(method) \(path)", default: []].append(contentsOf: replies) }
    }

    /// 이 경로의 응답 큐를 바꾼다.
    func set(_ method: String, _ path: String, _ replies: Reply...) {
        state.withLock { $0.routes["\(method) \(path)"] = replies }
    }

    /// 이 경로의 다음 요청부터 응답을 멈춘다.
    func hold(_ method: String, _ path: String) {
        _ = state.withLock { $0.held.insert("\(method) \(path)") }
    }

    /// 멈춘 요청을 모두 이어 가고 더는 멈추지 않는다.
    func release(_ method: String, _ path: String) {
        let key = "\(method) \(path)"
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.held.remove(key)
            return s.waiters.removeValue(forKey: key) ?? []
        }
        for waiter in waiters { waiter.resume() }
    }

    /// 멈춰 있는 요청 수.
    func waiting(_ method: String, _ path: String) -> Int {
        state.withLock { $0.waiters["\(method) \(path)"]?.count ?? 0 }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func count(_ method: String, _ path: String) -> Int {
        requests.filter { $0.httpMethod == method && $0.url?.path == path }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        state.withLock { $0.requests.append(request) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                guard s.held.contains(key) else { return true }
                s.waiters[key, default: []].append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
        let reply: Reply? = state.withLock { s in
            guard var queue = s.routes[key], let first = queue.first else { return nil }
            if queue.count > 1 { queue.removeFirst(); s.routes[key] = queue }
            return first
        }
        guard let reply else {
            let body = Data(#"{"error":{"code":"not_found","message":"no route"}}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["X-RD-Protocol": "1"])!)
        }
        if let failure = reply.failure { throw failure }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}

@MainActor
final class FakeOpener: URLOpening {
    var result = true
    /// `true`면 `release(_:)`할 때까지 `open`이 돌아오지 않는다(설치 창이 떠 있는 동안).
    var holds = false
    private(set) var opened: [URL] = []
    private var pending: CheckedContinuation<Bool, Never>?

    var isWaiting: Bool { pending != nil }

    func open(_ url: URL) async -> Bool {
        opened.append(url)
        guard holds else { return result }
        return await withCheckedContinuation { pending = $0 }
    }

    func release(_ result: Bool) {
        holds = false
        pending?.resume(returning: result)
        pending = nil
    }
}

@MainActor
final class FakeTunnel: TunnelControlling {
    var state: TunnelState
    var connectError: (any Error)?
    var prepareError: (any Error)?
    private(set) var prepareCount = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    /// 자동으로 켜기: 구성 상태, 켠 뒤의 상태, 켜기 오류, 부른 횟수.
    var autoStartConfiguration: VPNConfigurationState = .missing
    var autoStartResult: TunnelState = .connected
    var autoStartError: (any Error)?
    private(set) var autoStartCount = 0
    /// 지금 VPN을 켠 쪽. `nil`이면 상태에서 정한다(꺼짐이면 없음, 아니면 이 앱).
    var holder: VPNHolder?
    var vpnHolder: VPNHolder { holder ?? (state == .off ? .none : .thisApp) }
    private var continuations: [AsyncStream<TunnelState>.Continuation] = []

    func connectAutomatically() async throws {
        autoStartCount += 1
        if let autoStartError { throw autoStartError }
        set(autoStartResult)
    }

    init(_ state: TunnelState = .connected) {
        self.state = state
    }

    func currentState() -> TunnelState { state }

    func stateUpdates() -> AsyncStream<TunnelState> {
        let (stream, continuation) = AsyncStream<TunnelState>.makeStream()
        continuations.append(continuation)
        return stream
    }

    func set(_ new: TunnelState) {
        state = new
        for c in continuations { c.yield(new) }
    }

    func prepare() async throws {
        prepareCount += 1
        if let prepareError { throw prepareError }
    }

    func connect() async throws {
        connectCount += 1
        if let connectError { throw connectError }
        set(.connected)
    }

    func disconnect() async {
        disconnectCount += 1
        set(.off)
    }
}

/// 가상 시계. `instant`는 대기 시간만큼 시각을 앞당기고 바로 돌아오고, `blocking`은 취소될 때까지 멈춘다.
final class TestClock: PollingClock {
    enum Mode { case instant, blocking }
    private struct State {
        var now: Date
        var mode: Mode = .instant
        var sleeps = 0
        /// `blocking`에서 대기 중에 취소된 횟수(모델이 진행 확인 작업을 실제로 취소했는지 확인하는 용도).
        var cancelledSleeps = 0
    }
    private let state: Mutex<State>
    /// 대기마다 호출(모델 상태를 기록하는 용도).
    let onSleep: (@MainActor @Sendable () -> Void)?

    init(now: Date = t0, mode: Mode = .instant, onSleep: (@MainActor @Sendable () -> Void)? = nil) {
        state = Mutex(State(now: now, mode: mode))
        self.onSleep = onSleep
    }

    var now: Date { state.withLock { $0.now } }
    var sleeps: Int { state.withLock { $0.sleeps } }
    var cancelledSleeps: Int { state.withLock { $0.cancelledSleeps } }
    func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }
    /// 시각만 앞당긴다(앱이 백그라운드에 있던 시간).
    func advance(by seconds: TimeInterval) { state.withLock { $0.now = $0.now.addingTimeInterval(seconds) } }

    func sleep(for duration: Duration) async throws {
        let mode = state.withLock { s in
            s.sleeps += 1
            return s.mode
        }
        if let onSleep { await onSleep() }
        switch mode {
        case .instant:
            try Task.checkCancellation()
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            state.withLock { $0.now = $0.now.addingTimeInterval(seconds) }
            await Task.yield()
            try Task.checkCancellation()
        case .blocking:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                state.withLock { $0.cancelledSleeps += 1 }
                throw error
            }
        }
    }
}

@MainActor
struct Harness {
    let transport = FakeTransport()
    let opener = FakeOpener()
    let tunnel: FakeTunnel
    let store: InMemoryPairedHostStore
    let clock: TestClock
    let model: ClientModel

    init(
        tunnel: TunnelState = .connected,
        storedHost: PairedHost? = nil,
        clock: TestClock = TestClock(),
        policy: HostPolicy = .tailnetOnly,
        timing: ClientModel.Timing = .standard
    ) {
        self.tunnel = FakeTunnel(tunnel)
        self.store = InMemoryPairedHostStore(host: storedHost)
        self.clock = clock
        self.model = ClientModel(
            deviceName: "내 iPhone",
            client: ClientInfo(osVersion: "26.1", appVersion: "0.1.0"),
            transport: transport,
            store: store,
            opener: opener,
            tunnel: self.tunnel,
            clock: clock,
            hostPolicy: policy,
            timing: timing
        )
    }

    static let pairedHost = PairedHost(hostId: "h_4be0c7a1", hostName: "작업용 Mac", fqdn: hostFQDN, pairedAt: t0)

    func serveHostInfoAndBuilds(_ builds: String = Examples.builds) {
        transport.on("GET", "/v1/info", .json(Examples.info))
        transport.on("GET", "/v1/builds", .json(builds))
    }

    /// 조건이 참이 될 때까지 메인 액터를 양보한다.
    func waitUntil(_ condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 10_000 {
            spins += 1
            await Task.yield()
        }
    }

    /// 백그라운드 작업이 대기(sleep)에 들어갈 때까지 메인 액터를 양보한다.
    func waitUntilSleeping(atLeast count: Int = 1) async {
        var spins = 0
        while clock.sleeps < count, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
