import Foundation
import MacHostCore
import MacHostKit
import PhoneClientKit
import RDModels

@MainActor
final class RecordingOpener: URLOpening {
    private(set) var opened: [URL] = []

    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return true
    }
}

/// 언제나 연결된 VPN. 실제 터널·NetworkExtension은 시험 범위 밖이다.
@MainActor
final class ConnectedTunnel: TunnelControlling {
    func currentState() -> TunnelState { .connected }
    func stateUpdates() -> AsyncStream<TunnelState> { AsyncStream { _ in } }
    func prepare() async throws {}
    func connect() async throws {}
    func disconnect() async {}
}

/// iPhone 하나: 실제 `ClientModel` + 실제 `HostAPI`(모델 안) + 출하 정책·기본 시간 제한.
@MainActor
final class Phone {
    static let client = ClientInfo(osVersion: "26.1", appVersion: "0.1.0")

    let deviceName: String
    let transport: TailnetTransport
    let opener = RecordingOpener()
    let store: InMemoryPairedHostStore
    let model: ClientModel

    init(deviceName: String, transport: TailnetTransport, savedHost: PairedHost? = nil) {
        self.deviceName = deviceName
        self.transport = transport
        store = InMemoryPairedHostStore(host: savedHost)
        model = ClientModel(deviceName: deviceName, client: Self.client, transport: transport, store: store,
                            opener: opener, tunnel: ConnectedTunnel(), hostPolicy: .tailnetOnly)
    }

    var installer: InstallerPlayer { InstallerPlayer(transport: transport) }

    func api() throws -> HostAPI {
        guard let api = HostAPI(host: transport.fqdn, policy: .tailnetOnly, transport: transport, client: Self.client) else {
            throw E2EError("출하 정책이 호스트 주소를 받지 않았다: \(transport.fqdn)")
        }
        return api
    }
}

/// 사용자에게 보이는 문장은 제품 코드가 만드는 그대로 비교한다.
enum ProductText {
    static func api(_ code: String) -> String { HostAPIError(status: 0, code: code, message: "").userMessage }
    static var notPaired: String { api("not_paired") }
    static var pairCodeInvalid: String { api("pair_code_invalid") }
    static var buildNotFound: String { api("build_not_found") }
    static var cannotReachMac: String { api(HostAPIError.connectionFailedCode) }
}

/// 시험 환경: 가짜 제어 서버, 실제 Go 코어로 공유하는 Mac, 노드 둘(A·B).
@MainActor
final class World {
    static let macPort = 8080
    static let nodeA = "rd-phone-e2ea"
    static let nodeB = "rd-phone-e2eb"

    let binary: String
    let tmp: URL
    let logs: URL
    let control: FakeControl
    let paths: HostPaths
    let mac: HostModel
    let fqdn: String
    let forwarderA: Forwarder
    let forwarderB: Forwarder
    let transportA: TailnetTransport
    let transportB: TailnetTransport

    private var finished = false

    init(binary: String, tmp: URL, logs: URL, control: FakeControl, paths: HostPaths, mac: HostModel, fqdn: String, forwarderA: Forwarder, forwarderB: Forwarder) {
        self.binary = binary
        self.tmp = tmp
        self.logs = logs
        self.control = control
        self.paths = paths
        self.mac = mac
        self.fqdn = fqdn
        self.forwarderA = forwarderA
        self.forwarderB = forwarderB
        transportA = TailnetTransport(fqdn: fqdn, forwarderPort: forwarderA.port, macPort: Self.macPort)
        transportB = TailnetTransport(fqdn: fqdn, forwarderPort: forwarderB.port, macPort: Self.macPort)
    }

    static func start(binary: String, tmp: URL, logs: URL) async throws -> World {
        let control = try await FakeControl(binary: binary)
        // 루프백 제어 서버를 쓰면 `HostModel`이 `listenTLS=false`로 코어를 띄운다(protocol §9, §11).
        let paths = HostPaths(root: tmp.appendingPathComponent("host", isDirectory: true))
        let mac = HostModel(core: RDCoreHost(), paths: paths, bookmarks: NoFolderBookmarks(), id8: randomID8(),
                            hostDisplayName: "E2E Mac", appVersion: "0.1.0", port: macPort)
        mac.controlURL = control.url
        await mac.start()
        if let error = mac.lastError { throw E2EError("공유를 시작하지 못했다: \(error)") }
        try await until("호스트가 Running·listening이 된다", timeout: .seconds(60)) {
            await mac.refreshStatus()
            return mac.status?.backendState == .running && mac.status?.listening == true
        }
        guard let fqdn = mac.status?.fqdn, !fqdn.isEmpty else { throw E2EError("호스트 fqdn이 없다") }
        let target = "\(fqdn):\(macPort)"
        async let a = Forwarder(binary: binary, control: control.url, stateDir: tmp.appendingPathComponent("node-a"), nodeName: nodeA, target: target)
        async let b = Forwarder(binary: binary, control: control.url, stateDir: tmp.appendingPathComponent("node-b"), nodeName: nodeB, target: target)
        let forwarderA = try await a
        let forwarderB = try await b
        // 노드가 실제로 호스트에 닿는지 먼저 증명한다. 이것이 안 되면 뒤의 ‘연결 실패’는 아무 뜻이 없다.
        try await proveRoute(forwarderA)
        try await proveRoute(forwarderB)
        return World(binary: binary, tmp: tmp, logs: logs, control: control, paths: paths, mac: mac, fqdn: fqdn, forwarderA: forwarderA, forwarderB: forwarderB)
    }

    /// forward → tailnet → 호스트 경로로 HTTP 응답을 받았음을 확인한다.
    static func proveRoute(_ forwarder: Forwarder) async throws {
        let result = await rawHTTPProbe(port: forwarder.port, timeout: .seconds(120))
        guard case .responded(let head) = result, head.hasPrefix("HTTP/1.1 404"), head.lowercased().contains("x-rd-protocol: 1") else {
            throw E2EError("forward(\(forwarder.nodeName))가 호스트에 닿지 않는다: \(result)\n\(forwarder.child.err.string.suffix(1500))")
        }
    }

    func link() throws -> URL {
        guard let link = mac.pairingLink else { throw E2EError("페어링 링크가 없다: \(mac.pairingState), \(mac.lastError ?? "")") }
        return link
    }

    /// 성공·실패와 상관없이 부른다: 코어를 멈추고 하위 프로세스를 끝내고 로그를 옮긴다.
    func finish() async {
        guard !finished else { return }
        finished = true
        await mac.shutdown()
        writeLogs()
        ChildRegistry.terminateAll()
    }

    private func writeLogs() {
        let fm = FileManager.default
        try? forwarderA.child.err.string.write(to: logs.appendingPathComponent("forward-a.err"), atomically: true, encoding: .utf8)
        try? forwarderB.child.err.string.write(to: logs.appendingPathComponent("forward-b.err"), atomically: true, encoding: .utf8)
        try? control.child.err.string.write(to: logs.appendingPathComponent("control.err"), atomically: true, encoding: .utf8)
        try? fm.copyItem(at: paths.coreLogFile, to: logs.appendingPathComponent("core.log"))
        let lines = (transportA.exchanges.map { "A \($0.summary)" } + transportB.exchanges.map { "B \($0.summary)" }).joined(separator: "\n")
        try? lines.write(to: logs.appendingPathComponent("exchanges.log"), atomically: true, encoding: .utf8)
    }
}
