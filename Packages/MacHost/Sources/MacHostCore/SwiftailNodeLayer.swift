// SwiftailHostCore가 쓰는 노드 층. 실제는 SwiftailHostRuntime(Swiftail 노드 + 인증서 + tailnet 리스너)이고, 시험은 가짜를 끼운다.
import Foundation
import RDHostLogic
import RDModels
import Swiftail
import SwiftailCertificates
import SwiftailControl
import SwiftailHostServer

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
    var serving: ServingState { get }
    /// 조건을 기다리거나 물러난 인증서 발급을 곧바로 다시 본다.
    func retryCertificates() async
}

/// 노드 층을 만드는 것. 설정 오류는 던진다.
struct HostNodeFactory: Sendable {
    var make: @Sendable (HostConfiguration, any HostRequestHandling, @escaping @Sendable (HostEvent) -> Void) throws -> any HostNodeLayer
    /// `run()`이 끝난 뒤 서버 쪽 로그아웃(Swiftail `TailnetNode.logOut()`).
    var logOut: @Sendable (NodeConfiguration) async throws -> Void

    static let swiftail = HostNodeFactory(
        make: { configuration, handler, events in
            SwiftailRuntimeLayer(runtime: try SwiftailHostRuntime(configuration: configuration, handler: handler, events: events))
        },
        logOut: { configuration in
            let node = try TailnetNode(configuration: configuration, device: .inProcess)
            try await node.logOut()
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
            signingRequest: status.tailnetLock.signingRequest.map { LockWait(nodeKey: $0.nodeKey, lockKey: $0.lockKey) }
        )
    }

    func certificateSnapshot() async -> CertificateSnapshot? {
        guard let certificates = runtime.certificates else { return nil }
        let status = await certificates.status
        return CertificateSnapshot(lastFailure: status.lastFailure, nextAttempt: status.nextAttempt)
    }

    var serving: ServingState { runtime.serving }

    func retryCertificates() async { await runtime.retryCertificates() }
}
