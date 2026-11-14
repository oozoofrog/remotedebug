#if RD_SWIFTAIL_TUNNEL
import Foundation
import Network
import os
import RDModels
import Swiftail
import SwiftailBase
import SwiftailControl
import SwiftailEngine
import SwiftailMagicsock

/// Swiftail의 `TailnetNode`를 터널 확장의 호출 지점에 맞춘다. 사건과 상태를 Go 코어와 같은 모양
/// (`CoreEvent`, `CoreStatus`)으로 바꿔 내므로 앱 쪽은 그대로다.
final class SwiftailTunnelEngine: TunnelEngine, @unchecked Sendable {
    private let node: TailnetNode
    private let hostname: String
    private let logger: Logger
    private let lock = NSLock()
    private var pathPeer: String?
    private var fatalMessage: String?
    private var runTask: Task<Void, Never>?
    private var pumps: [Task<Void, Never>] = []
    private let stream: AsyncStream<CoreEvent>
    private let continuation: AsyncStream<CoreEvent>.Continuation

    init(stateDirectory: URL, hostname: String, controlURL: String, authKey: String, utunFd: Int32, mtu: Int, logger: Logger) throws {
        let control = URL(string: controlURL).flatMap { controlURL.isEmpty ? nil : $0 } ?? NodeConfiguration.defaultControlURL
        let configuration = NodeConfiguration(
            stateDirectory: stateDirectory, hostname: hostname, controlURL: control,
            authKey: authKey.isEmpty ? nil : authKey)
        node = try TailnetNode(configuration: configuration, device: .utun(fileDescriptor: utunFd, mtu: mtu))
        self.hostname = hostname
        self.logger = logger
        (stream, continuation) = AsyncStream.makeStream(of: CoreEvent.self)
        start()
    }

    private func start() {
        let node = node
        pumps.append(Task { [weak self] in
            for await event in node.events {
                guard let self else { return }
                switch event {
                case .stateChanged(let state):
                    self.logger.log("Swiftail 상태: \(String(describing: Self.backendState(state)), privacy: .public)")
                case .peerPathChanged(_, let path):
                    self.logger.log("Swiftail 경로: \(Self.pathText(path), privacy: .public)")
                }
                if let status = await self.status() { self.continuation.yield(.state(status)) }
            }
        })
        pumps.append(Task { [weak self] in
            for await settings in node.networkSettings {
                self?.continuation.yield(.networkSettings(Self.settingsEvent(settings)))
            }
        })
        runTask = Task { [weak self] in
            do throws(NodeError) {
                try await node.run()
            } catch {
                guard let self else { return }
                let message = Self.message(for: error)
                self.lock.withLock { self.fatalMessage = message }
                self.logger.error("Swiftail 노드가 끝났습니다: \(Self.kind(of: error), privacy: .public)")
                self.continuation.yield(.state(CoreStatus(backendState: .error, hostname: self.hostname, errorMessage: message)))
            }
        }
    }

    func events() -> AsyncStream<CoreEvent> { stream }

    func status() async -> CoreStatus? {
        let (peer, fatal) = lock.withLock { (pathPeer, fatalMessage) }
        if let fatal { return CoreStatus(backendState: .error, hostname: hostname, errorMessage: fatal) }
        let status = await node.status
        var path: RDModels.PeerPath?
        if let peer, let found = await node.path(toPeerNamed: peer) { path = Self.peerPath(found) }
        var authURL = ""
        if case .needsLogin(let url) = status.state { authURL = url.absoluteString }
        let settings = status.networkSettings
        return CoreStatus(
            backendState: Self.backendState(status.state),
            authURL: authURL,
            hostname: hostname,
            fqdn: status.fqdn ?? "",
            tailscaleIPs: status.addresses.map(\.description),
            certDomains: status.certDomains,
            tunnel: TunnelStatus(
                addresses: settings?.addresses.map(\.description) ?? [],
                routes: settings?.routes.map(\.description) ?? [],
                dnsServers: settings?.dnsServers.map(\.description) ?? [],
                dnsMatchDomains: settings?.dnsMatchDomains ?? [],
                mtu: settings?.mtu ?? 0,
                peerCount: status.peerCount),
            peerPath: path)
    }

    /// Swiftail에는 경로 소켓 감시가 없어 만족된 경로마다 그대로 넘긴다.
    func setDefaultInterface(_ interface: NWInterface) throws {
        let node = node
        Task { await node.setDefaultInterface(interface) }
    }

    func setPathPeer(_ fqdn: String) throws {
        lock.withLock { pathPeer = fqdn }
    }

    func stop() {
        let (run, pumps) = lock.withLock { (runTask, self.pumps) }
        let done = DispatchSemaphore(value: 0)
        Task {
            run?.cancel()
            _ = await run?.result
            for pump in pumps { pump.cancel() }
            done.signal()
        }
        done.wait()
        continuation.finish()
    }

    // MARK: 변환

    static func backendState(_ state: NodeState) -> BackendState {
        switch state {
        case .starting: .starting
        case .needsLogin: .needsLogin
        case .needsMachineAuth: .needsMachineAuth
        case .running: .running
        }
    }

    static func settingsEvent(_ settings: TunnelNetworkSettings) -> NetworkSettingsEvent {
        NetworkSettingsEvent(
            addresses: settings.addresses.map(\.description),
            routes: settings.routes.map(\.description),
            dnsServers: settings.dnsServers.map(\.description),
            dnsMatchDomains: settings.dnsMatchDomains,
            mtu: settings.mtu)
    }

    static func peerPath(_ path: SwiftailMagicsock.PeerPath) -> RDModels.PeerPath {
        switch path {
        case .direct(let endpoint): RDModels.PeerPath(direct: true, addr: endpoint.description)
        case .relayed(let region): RDModels.PeerPath(direct: false, relay: region == 0 ? nil : String(region))
        }
    }

    static func pathText(_ path: SwiftailMagicsock.PeerPath?) -> String {
        switch path {
        case .direct?: "직접"
        case .relayed(let region)?: "중계(지역 \(region))"
        case nil: "없음"
        }
    }

    /// 로그에 남기는 종류 이름(비밀 없음).
    static func kind(of error: NodeError) -> String {
        switch error {
        case .control(.authKeyRejected): "authKeyRejected"
        case .control(.registrationRejected): "registrationRejected"
        case .control(.nodeKeyExpired): "nodeKeyExpired"
        case .control(.tailnetLockEnabled): "tailnetLockEnabled"
        case .control(.storage): "storage"
        case .control: "control"
        case .invalidConfiguration: "invalidConfiguration"
        case .udpUnavailable: "udpUnavailable"
        case .stateDirectoryInUse: "stateDirectoryInUse"
        case .tunnelDeviceClosed: "tunnelDeviceClosed"
        }
    }

    /// 앱이 보여 줄 문장. 서버가 준 진단 문자열은 넣지 않는다.
    /// shortcut: 시험 빌드 전용이라 번역 파일에 넣지 않았다. 정식 교체 때 `String(localized:)`로 바꾼다.
    static func message(for error: NodeError) -> String {
        switch error {
        case .tunnelDeviceClosed: TunnelEngineMessages.tunDeviceClosed
        case .control(.authKeyRejected): "인증 키가 거부됐습니다. 새 인증 키로 다시 켜세요."
        case .control(.registrationRejected): "tailnet이 이 기기의 등록을 거절했습니다. 관리자에게 확인하세요."
        case .control(.nodeKeyExpired): "이 기기의 tailnet 키가 만료됐습니다. 다시 로그인하세요."
        case .control(.tailnetLockEnabled): "tailnet lock이 켜진 tailnet은 지원하지 않습니다."
        case .control(.storage): "저장된 로그인 정보를 읽거나 쓰지 못했습니다."
        case .control: "tailnet 제어 서버와의 연결이 끝났습니다. VPN을 다시 켜세요."
        case .invalidConfiguration: "터널 설정이 잘못됐습니다."
        case .udpUnavailable: "네트워크 소켓을 열지 못했습니다."
        case .stateDirectoryInUse: "다른 터널이 같은 로그인 정보를 쓰고 있습니다."
        }
    }
}
#endif
