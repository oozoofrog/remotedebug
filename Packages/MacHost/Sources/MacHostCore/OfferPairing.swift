// QR·링크 페어링(protocol-addenda B.5)의 코어 쪽 조각: Swiftail `PairingHost`를 감싸는 모양, 1회용 키 발급, 승인 대기.
//
// 짝 맺기 절차는 `PairingHost`가 하고, 권한은 RemoteDebug 허용 목록(로직의 `devices`)이 판정한다. 짝 목록은 허용 목록의
// 부분집합으로 맞춘다(`SwiftailHostCore.reconcilePairing`): 허용 목록에만 있는 기기(코드 페어링, 옮기기 전에 짝이 된 기기)는
// 그대로 쓰고, 짝 목록에만 있는 기기(공유가 꺼졌을 때 지운 기기, 허용 목록에 넣지 못한 기기)는 짝 목록에서 지운다.
//
// 로그와 사건에는 제안의 링크·비밀·인증 키·확인 숫자를 넣지 않는다(확인 숫자는 화면에 보일 `pair-request` 값에만, JSON에는 없다).
import Foundation
import MacHostKit
import RDHostLogic
import RDModels
import Swiftail
import SwiftailHostServer
import SwiftailPairing
import Synchronization

/// `PairingHost`가 묻는 승인 하나를 로직의 상대 모양으로.
struct OfferPairingRequest: Sendable, Equatable {
    var peer: HostPeer
    /// 상대가 스스로 밝힌 이름. 확인된 값이 아니다.
    var deviceName: String
    var confirmationCode: String
}

/// 코어가 쓰는 여는 쪽의 모양. 실제는 Swiftail `PairingHost`, 시험은 가짜다.
protocol PairingHosting: Sendable {
    /// 페어링 포트를 듣는다. 부른 Task가 취소될 때까지 돌아오지 않는다.
    func runListener() async throws
    func open(lifetimeSeconds: Int, authKey: String?) async throws(PairingError) -> PairingOffer
    func closeCurrentOffer() async
    /// 이 노드가 짝으로 저장된 때. 짝이 아니면 nil.
    func pairedAt(stableID: String) async -> Date?
    func pairedStableIDs() async -> [String]
    func removePeer(stableID: String) async throws
}

extension PairingHost: PairingHosting {
    func runListener() async throws { try await run() }

    func open(lifetimeSeconds: Int, authKey: String?) async throws(PairingError) -> PairingOffer {
        try await openOffer(lifetime: .seconds(lifetimeSeconds), authKey: authKey)
    }

    func closeCurrentOffer() async { closeOffer() }

    func pairedAt(stableID: String) async -> Date? { pairedPeer(withStableID: stableID)?.pairedAt }

    func pairedStableIDs() async -> [String] { pairedPeers.map(\.peer.stableID) }

    func removePeer(stableID: String) async throws { try removePairedPeer(withStableID: stableID) }
}

/// 만든 1회용 키. 키는 비밀이라 `description`에서 가린다.
struct IssuedPairingKey: Sendable, CustomStringConvertible {
    var key: String
    var expires: Date
    var description: String { "IssuedPairingKey(key: <가림>, expires: \(expires))" }
}

/// Swiftail `AuthKeyIssuer`로 키를 만들고 오류를 화면의 값으로 옮긴다.
enum PairingKeys {
    static func issue(client: TailscaleAPI.OAuthClient, lifetimeSeconds: Int) async throws(TailscaleAPI.Failure) -> IssuedPairingKey {
        do throws(AuthKeyIssueError) {
            let issuer = try AuthKeyIssuer(client: TailscaleOAuthClient(id: client.id, secret: client.secret, tags: client.tags))
            let issued = try await issuer.issue(lifetime: .seconds(lifetimeSeconds))
            return IssuedPairingKey(key: issued.key, expires: issued.expires)
        } catch {
            throw failure(error)
        }
    }

    static func failure(_ error: AuthKeyIssueError) -> TailscaleAPI.Failure {
        switch error {
        case .invalidClient: .badClient
        case .invalidTags: .badTags
        case .clientRejected: .clientRejected
        case .unauthorized: .unauthorized
        case .forbidden: .forbidden
        case .http(let status): .http(status)
        case .invalidLifetime, .invalidBaseURL, .invalidResponse: .invalidResponse
        case .network: .network
        case .cancelled: .cancelled
        }
    }

    /// 형식 검사만(관리 API에 보내지 않는다). 계약 K4.
    static func check(_ client: TailscaleAPI.OAuthClient) -> TailscaleAPI.Failure? {
        do throws(AuthKeyIssueError) {
            _ = try AuthKeyIssuer(client: TailscaleOAuthClient(id: client.id, secret: client.secret, tags: client.tags))
            return nil
        } catch {
            return failure(error)
        }
    }
}

/// 사용자의 답을 기다리는 QR 페어링 요청들. `PairingHost`의 `decide`가 등록하고, 화면의 허용·거부(`decidePairing`)가 푼다.
/// `decide`의 Task가 취소되면(iPhone이 끊음, 120초) 곧 거절로 돌아간다(계약 P5).
final class PendingOffers: Sendable {
    struct Request: Sendable {
        var peer: HostPeer
        var name: String
    }

    private enum Slot {
        case waiting(CheckedContinuation<Bool, Never>)
        /// 등록 전에 취소가 왔다.
        case cancelledEarly
        /// 답했다. 허용이면 짝 목록 저장을 기다리는 중이다.
        case answered
    }

    private struct State {
        var slots: [String: Slot] = [:]
        var requests: [String: Request] = [:]
    }

    private let state = Mutex(State())

    /// 사용자의 답을 기다린다. `announce`는 등록한 뒤(허용·거부가 이 요청을 찾을 수 있게 된 뒤) 한 번 부른다.
    /// 취소되면 false를 돌려주고 `cancelled`가 참이다.
    func wait(id: String, request: Request, announce: () -> Void) async -> (allowed: Bool, cancelled: Bool) {
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let registered = state.withLock { value -> Bool in
                    if case .cancelledEarly = value.slots[id] { return false }
                    value.slots[id] = .waiting(continuation)
                    value.requests[id] = request
                    return true
                }
                if registered { announce() } else { continuation.resume(returning: false) }
            }
        } onCancel: {
            let waiting = state.withLock { value -> CheckedContinuation<Bool, Never>? in
                switch value.slots[id] {
                case .waiting(let continuation):
                    value.slots[id] = nil
                    value.requests[id] = nil
                    return continuation
                case nil:
                    value.slots[id] = .cancelledEarly
                    return nil
                case .cancelledEarly, .answered:
                    return nil
                }
            }
            waiting?.resume(returning: false)
        }
        let cancelled = state.withLock { value -> Bool in
            defer { if case .cancelledEarly = value.slots[id] { value.slots[id] = nil } }
            if case .answered = value.slots[id] { return false }
            return true
        }
        return (allowed, cancelled && !allowed)
    }

    /// 기다리는 요청이면 답하고 그 요청을 돌려준다. 이미 답했거나 끊겼거나 모르는 요청이면 nil.
    func answer(id: String, allow: Bool) -> Request? {
        let (continuation, request) = state.withLock { value -> (CheckedContinuation<Bool, Never>?, Request?) in
            guard case .waiting(let continuation) = value.slots[id], let request = value.requests[id] else { return (nil, nil) }
            value.slots[id] = .answered
            if !allow { value.requests[id] = nil }
            return (continuation, request)
        }
        continuation?.resume(returning: allow)
        return request
    }

    /// 이 코어가 아는 요청인지(기다리는 중이거나, 허용한 뒤 저장을 기다리는 중).
    func knows(_ id: String) -> Bool { state.withLock { $0.requests[id] != nil } }

    /// 허용한 요청의 처리가 끝났다.
    func finish(_ id: String) {
        state.withLock { value in
            value.slots[id] = nil
            value.requests[id] = nil
        }
    }

    /// 허용한 뒤 짝 목록 저장을 기다리는 노드(짝 목록 맞추기에서 지우지 않는다).
    var admittingStableIDs: Set<String> {
        state.withLock { value in
            Set(value.slots.compactMap { id, slot in
                if case .answered = slot { value.requests[id]?.peer.stableID } else { nil }
            })
        }
    }
}
