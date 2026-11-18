import Foundation
import Network
import os
import RDModels
import Swiftail
import SwiftailBase
import SwiftailControl
import SwiftailEngine
import SwiftailMagicsock

/// Swiftail의 `TailnetNode`를 터널 확장의 호출 지점에 맞춘다. 사건과 상태를 앱이 읽는 모양
/// (`CoreEvent`, `CoreStatus`, 공용 모델 RDModels)으로 바꿔 낸다.
///
/// - `run()`은 이 객체가 만든 Task 하나에서 돈다. `stop()`은 그 Task를 취소하고 끝나기를 기다린다.
/// - 서버 쪽 로그아웃(`logOut`)은 `run()`이 돌지 않을 때만 부른다(Swiftail 계약 "로그아웃").
final class SwiftailTunnelEngine: @unchecked Sendable {
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
                case .tailnetLockChanged(let lock):
                    // 화면 안내는 아직 없다. 종류와 개수만 남긴다(키는 남기지 않는다).
                    self.logger.log("Swiftail tailnet lock: \(String(describing: lock.mode), privacy: .public), 서명 기다림 \(lock.signingRequest != nil), 걸러진 피어 \(lock.filteredPeerCount)")
                case .statusChanged:
                    // 아래에서 사건마다 상태를 다시 읽어 보낸다.
                    break
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

    /// 상태·설정·로그 사건. 구독자는 하나다.
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
            peerPath: path,
            lockWait: status.tailnetLock.signingRequest.map { LockWait(nodeKey: $0.nodeKey, lockKey: $0.lockKey) })
    }

    /// 만족된 경로를 받을 때마다 그대로 넘긴다(Swiftail은 같은 인터페이스를 다시 알려도 거른다).
    func setDefaultInterface(_ interface: NWInterface) {
        let node = node
        Task { await node.setDefaultInterface(interface) }
    }

    /// 경로(직접·중계)를 알아볼 피어의 MagicDNS 이름. 다음 상태 점검부터 `peerPath`가 채워진다.
    func setPathPeer(_ fqdn: String) {
        lock.withLock { pathPeer = fqdn }
    }

    /// 노드를 멈추고 `run()`이 끝날 때까지 기다린다. 몇 초 걸릴 수 있어 직렬 큐에서 부른다.
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

    // MARK: 서버 로그아웃

    /// 서버 쪽 로그아웃의 결과. 어느 쪽이든 호출자는 로컬 상태를 지운다.
    enum LogOutResult: Equatable, Sendable {
        case done
        /// 서버에 닿지 못했거나 거절했다(기한 10초 포함). 서버가 이미 적용했을 수도 있다. 값은 로그에 남길 종류 이름.
        case failed(String)
    }

    /// 제어 서버에 이 기기의 node 키를 만료시키라고 알린다. 상태 폴더는 건드리지 않는다.
    /// 이 프로세스에서 같은 상태 폴더의 `run()`이 돌지 않을 때만 부른다(앞의 노드를 `stop()`으로 끝낸 뒤).
    /// shortcut: Swiftail은 다른 프로세스가 같은 폴더로 `run()` 중인지는 막지 못한다(계약 "로그아웃" 동작 O1).
    /// 두 앱의 터널은 iOS가 한 번에 하나만 켜므로 두지 않았다.
    static func logOut(stateDirectory: URL, hostname: String, controlURL: String, logger: Logger) async -> LogOutResult {
        let control = URL(string: controlURL).flatMap { controlURL.isEmpty ? nil : $0 } ?? NodeConfiguration.defaultControlURL
        do {
            // 장치는 쓰지 않는다. `logOut()`은 설정과 신원 파일만 본다.
            let node = try TailnetNode(
                configuration: NodeConfiguration(stateDirectory: stateDirectory, hostname: hostname, controlURL: control),
                device: .memory())
            try await node.logOut()
            logger.log("서버 로그아웃: 완료")
            return .done
        } catch {
            let kind = (error as? NodeError).map(Self.kind(of:)) ?? "unknown"
            logger.error("서버 로그아웃 실패(\(kind, privacy: .public)). 로컬 로그인은 그대로 지웁니다")
            return .failed(kind)
        }
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
        case .control(.storage): "storage"
        case .control: "control"
        case .invalidConfiguration: "invalidConfiguration"
        case .udpUnavailable: "udpUnavailable"
        case .stateDirectoryInUse: "stateDirectoryInUse"
        case .tunnelDeviceClosed: "tunnelDeviceClosed"
        }
    }

    /// 앱이 보여 줄 문장. 서버가 준 진단 문자열은 넣지 않는다.
    static func message(for error: NodeError) -> String {
        switch error {
        case .tunnelDeviceClosed: TunnelEngineMessages.tunDeviceClosed
        case .control(.authKeyRejected): String(localized: "인증 키가 거부됐습니다. 새 인증 키로 다시 켜세요.")
        case .control(.registrationRejected): String(localized: "tailnet이 이 기기의 등록을 거절했습니다. 관리자에게 확인하세요.")
        case .control(.nodeKeyExpired): String(localized: "이 기기의 tailnet 키가 만료됐습니다. 다시 로그인하세요.")
        case .control(.storage): String(localized: "저장된 로그인 정보를 읽거나 쓰지 못했습니다.")
        case .control: String(localized: "tailnet 제어 서버와의 연결이 끝났습니다. VPN을 다시 켜세요.")
        case .invalidConfiguration: String(localized: "터널 설정이 잘못됐습니다.")
        case .udpUnavailable: String(localized: "네트워크 소켓을 열지 못했습니다.")
        case .stateDirectoryInUse: String(localized: "다른 터널이 같은 로그인 정보를 쓰고 있습니다.")
        }
    }
}
