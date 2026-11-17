// SwiftailHostCore가 쓰는 노드 층. 실제는 SwiftailHostRuntime(Swiftail 노드 + 인증서 + tailnet 리스너)이고, 시험은 가짜를 끼운다.
import Foundation
import MacHostKit
import RDHostLogic
import RDModels
import Swiftail
import SwiftailCertificates
import SwiftailControl
import SwiftailHostServer
import SwiftailPairing

/// 노드의 지금 모습에서 코어 상태에 쓰는 것만.
struct NodeSnapshot: Sendable, Equatable {
    var state: NodeState = .starting
    var addresses: [String] = []
    var fqdn: String?
    var stableID: String?
    var certDomains: [String] = []
    var peerCount = 0
    /// tailnet lock이 켜졌고 이 노드가 서명을 기다리면 서명 기기에 넣을 두 공개 키.
    var signingRequest: LockWait?
    /// tailnet lock이 켜진 tailnet이다(이 노드가 서명됐든 아니든). 페어링 QR의 키로 새로 들어온 노드는 서명 전까지 잠긴다.
    var tailnetLockEnabled = false
}

/// 인증서 관리자의 모습에서 코어 상태에 쓰는 것만. 인증서를 쓰지 않으면(평문 모드) nil.
struct CertificateSnapshot: Sendable, Equatable {
    var lastFailure: CertificateFailure?
    var nextAttempt: Date?
}

/// 노드 하나의 수명. `run()`은 부른 Task가 취소될 때까지 돌고, 취소되면 노드와 인증서 관리자가 끝난 뒤 돌아온다.
protocol HostNodeLayer: Sendable {
    func run() async throws
    func snapshot() async -> NodeSnapshot
    func certificateSnapshot() async -> CertificateSnapshot?
    /// 안정 ID로 꼽은 피어까지의 지금 경로. netmap에 없거나 경로가 없는 피어는 뺀다.
    func peerPaths(to stableIDs: [String]) async -> [String: RDModels.PeerPath]
    var serving: ServingState { get }
    /// 조건을 기다리거나 물러난 인증서 발급을 곧바로 다시 본다.
    func retryCertificates() async
}

/// 노드 층을 만드는 것. 설정 오류는 던진다.
struct HostNodeFactory: Sendable {
    var make: @Sendable (HostConfiguration, any HostRequestHandling, @escaping @Sendable (HostEvent) -> Void) throws -> any HostNodeLayer
    /// `run()`이 끝난 뒤 서버 쪽 로그아웃(Swiftail `TailnetNode.logOut()`).
    var logOut: @Sendable (NodeConfiguration) async throws -> Void
    /// 노드 층에 QR·링크 페어링의 여는 쪽을 붙인다. 붙일 수 없는 층(시험의 가짜)이면 nil.
    var makePairing: @Sendable (_ layer: any HostNodeLayer, _ port: UInt16, _ directory: URL,
                                _ decide: @escaping @Sendable (OfferPairingRequest) async -> Bool) async throws -> (any PairingHosting)? = { _, _, _, _ in nil }
    /// 1회용 Tailscale 인증 키를 만든다(Swiftail `AuthKeyIssuer`). 시험은 가짜를 넣는다.
    var issueKey: @Sendable (TailscaleAPI.OAuthClient, Int) async throws(TailscaleAPI.Failure) -> IssuedPairingKey = { client, seconds throws(TailscaleAPI.Failure) in
        try await PairingKeys.issue(client: client, lifetimeSeconds: seconds)
    }

    static let swiftail = HostNodeFactory(
        make: { configuration, handler, events in
            SwiftailRuntimeLayer(runtime: try SwiftailHostRuntime(configuration: configuration, handler: handler, events: events))
        },
        logOut: { configuration in
            let node = try TailnetNode(configuration: configuration, device: .inProcess)
            try await node.logOut()
        },
        makePairing: { layer, port, directory, decide in
            guard let layer = layer as? SwiftailRuntimeLayer else { return nil }
            return try await PairingHost(node: layer.runtime.node, port: port, storeDirectory: directory) { request in
                await decide(OfferPairingRequest(peer: HTTPListener.peer(request.peer), deviceName: request.deviceName,
                                                 confirmationCode: request.confirmationCode))
            }
        }
    )
}

struct SwiftailRuntimeLayer: HostNodeLayer {
    let runtime: SwiftailHostRuntime

    func run() async throws { try await runtime.run() }

    func snapshot() async -> NodeSnapshot {
        let status = await runtime.node.status
        return NodeSnapshot(
            state: status.state,
            addresses: status.addresses.map(\.description),
            fqdn: status.fqdn,
            stableID: status.stableID,
            certDomains: status.certDomains,
            peerCount: status.peerCount,
            signingRequest: status.tailnetLock.signingRequest.map { LockWait(nodeKey: $0.nodeKey, lockKey: $0.lockKey) },
            tailnetLockEnabled: status.tailnetLock.mode != .disabled
        )
    }

    func peerPaths(to stableIDs: [String]) async -> [String: RDModels.PeerPath] {
        var paths: [String: RDModels.PeerPath] = [:]
        for id in stableIDs {
            switch await runtime.node.path(toPeerWithStableID: id) {
            case .direct(let endpoint)?: paths[id] = RDModels.PeerPath(direct: true, addr: endpoint.description)
            case .relayed(let region)?: paths[id] = RDModels.PeerPath(direct: false, relay: region == 0 ? nil : String(region))
            case nil: break
            }
        }
        return paths
    }

    func certificateSnapshot() async -> CertificateSnapshot? {
        guard let certificates = runtime.certificates else { return nil }
        let status = await certificates.status
        return CertificateSnapshot(lastFailure: status.lastFailure, nextAttempt: status.nextAttempt)
    }

    var serving: ServingState { runtime.serving }

    func retryCertificates() async { await runtime.retryCertificates() }
}

extension HostNodeLayer {
    /// 경로를 모르는 노드 층(시험용 가짜)의 기본값.
    func peerPaths(to stableIDs: [String]) async -> [String: RDModels.PeerPath] { [:] }
}
