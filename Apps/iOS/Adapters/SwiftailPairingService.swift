import Foundation
import PhoneClientKit
import SwiftailPairing

/// `PairingService`를 `SwiftailPairing`으로 구현한다.
///
/// 이 앱의 tailnet 노드는 터널 확장에 있고 터널 확장은 `SwiftailPairing`을 링크하지 않는다.
/// 그래서 앱은 OS 소켓 판 `PairingJoiner`로 들어온다(터널이 연결된 뒤. 이름은 터널의 MagicDNS가 푼다).
struct SwiftailPairingService: PairingService {
    func read(link: String) throws(PairingOfferIssue) -> PairingProposal {
        let offer: PairingOffer
        do throws(PairingOfferError) {
            offer = try PairingOffer(link: link)
        } catch {
            throw Self.issue(for: error)
        }
        // 비밀은 `PairingOffer` 안에 있고 앱에는 내보내지 않는다. 앱 값에는 주소·만료·인증 키만 옮긴다.
        return PairingProposal(link: link, host: offer.host, expires: offer.expires, authKey: offer.authKey, payload: offer)
    }

    func join(
        _ proposal: PairingProposal, deviceName: String,
        awaitingApproval: @escaping @Sendable (String) -> Void
    ) async throws(PairingFailure) -> JoinedHost {
        guard let offer = proposal.payload as? PairingOffer else { throw .unexpected }
        do throws(PairingError) {
            let paired = try await PairingJoiner.pair(with: offer, deviceName: deviceName, awaitingApproval: awaitingApproval)
            return JoinedHost(host: paired.host, stableID: paired.stableID, name: paired.name, pairedAt: paired.pairedAt)
        } catch {
            throw Self.failure(for: error)
        }
    }

    /// `PairingOfferError` → 앱 쪽 이유.
    static func issue(for error: PairingOfferError) -> PairingOfferIssue {
        switch error {
        case .notAnOffer: .notAnOffer
        case .invalidHost: .invalidHost
        case .invalidPort: .invalidPort
        case .invalidSecret: .invalidSecret
        case .invalidExpiry: .invalidExpiry
        case .invalidAuthKey: .invalidAuthKey
        case .wrappedAuthKey: .wrappedAuthKey
        }
    }

    /// `PairingError` → 앱 쪽 이유. 들어오는 쪽에서 나오지 않는 것(여는 쪽·짝 목록의 오류)은 `.unexpected`다.
    static func failure(for error: PairingError) -> PairingFailure {
        switch error {
        case .unreachable: .unreachable
        case .notOnTailnet: .notOnTailnet
        case .rejected: .rejected
        case .denied: .denied
        case .timedOut: .timedOut
        case .hostNotVerified: .hostNotVerified
        case .protocolViolation: .protocolViolation
        case .cancelled: .cancelled
        case .invalidConfiguration, .invalidAuthKey, .notRunning, .storeUnreadable, .storeInUse, .storeWriteFailed: .unexpected
        }
    }
}
