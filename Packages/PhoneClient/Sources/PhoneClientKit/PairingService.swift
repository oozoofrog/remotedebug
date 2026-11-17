import CryptoKit
import Foundation

/// 페어링 링크·QR에서 읽은 제안(Swiftail 페어링의 `PairingOffer`를 앱 쪽 값으로 옮긴 것).
///
/// 앱이 쓰는 값(주소, 만료, 인증 키)만 드러낸다. 비밀은 `payload`에 담겨 어댑터만 꺼내 쓴다.
/// 인증 키와 비밀은 비밀이므로 화면 복원 저장소·로그·분석에 넣지 않는다(`description`과 `dump`는 가린다).
public struct PairingProposal: Sendable {
    /// Mac(여는 노드)의 MagicDNS 이름.
    public let host: String
    /// 제안이 끝나는 때. 안내에만 쓴다. 거절 여부는 Mac이 정한다.
    public let expires: Date
    /// 이 iPhone이 아직 tailnet에 로그인하지 않았을 때 VPN을 켜는 데 한 번 쓰는 1회용 키. 저장하지 않는다.
    public let authKey: String?
    /// 어댑터가 담은 원본(비밀 포함).
    public let payload: any Sendable
    /// 링크 글자의 SHA-256. 같은 링크가 다시 들어왔는지 견주는 데만 쓴다(링크 자체는 지니지 않는다).
    let fingerprint: Data

    /// - Parameter link: 읽은 링크 글자. 지문을 만드는 데만 쓰고 보관하지 않는다.
    public init(link: String, host: String, expires: Date, authKey: String?, payload: any Sendable) {
        self.host = host
        self.expires = expires
        self.authKey = authKey
        self.payload = payload
        self.fingerprint = Data(SHA256.hash(data: Data(link.utf8)))
    }
}

extension PairingProposal: Equatable {
    public static func == (lhs: PairingProposal, rhs: PairingProposal) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }
}

extension PairingProposal: CustomStringConvertible, CustomReflectable {
    public var description: String {
        "PairingProposal(host: \(host), authKey: \(authKey == nil ? "없음" : "<가림>"), secret: <가림>)"
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["host": host, "expires": expires, "authKey": authKey == nil ? "없음" : "<가림>", "secret": "<가림>"])
    }
}

/// 시작하기 전에 사용자에게 물을 페어링.
public struct PairingConfirmation: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// 앱 밖에서 배달된 링크. 링크는 어디서든 올 수 있다.
        case openedLink
        /// 이미 페어링한 Mac이나 진행 중인 페어링과 다른 Mac.
        case replacement
    }

    public let proposal: PairingProposal
    public let reason: Reason
    public var host: String { proposal.host }

    public init(proposal: PairingProposal, reason: Reason) {
        self.proposal = proposal
        self.reason = reason
    }
}

/// 짝을 맺은 Mac(Swiftail 페어링이 돌려준 값).
public struct JoinedHost: Sendable, Equatable {
    public var host: String
    /// Mac 노드의 StableID.
    public var stableID: String
    /// Mac이 알려 준 표시 이름.
    public var name: String
    public var pairedAt: Date

    public init(host: String, stableID: String, name: String, pairedAt: Date) {
        self.host = host
        self.stableID = stableID
        self.name = name
        self.pairedAt = pairedAt
    }
}

/// 링크·QR의 글자를 제안으로 읽지 못한 이유.
public enum PairingOfferIssue: Error, Equatable, Sendable {
    /// 예전 꼴(`remotedebug://pair?host=…&code=…`). Mac 앱이 예전 버전이다.
    case legacyLink
    /// 페어링 링크가 아니다.
    case notAnOffer
    case invalidHost, invalidPort, invalidSecret, invalidExpiry
    case invalidAuthKey
    /// Tailnet Lock으로 서명한(감싼) 인증 키.
    case wrappedAuthKey
    /// 주소가 정책(`.ts.net` 이름)을 통과하지 못했다.
    case hostNotAllowed

    public var userMessage: String {
        switch self {
        case .legacyLink:
            String(localized: "이 링크는 이전 버전 Mac 앱이 만든 것입니다. Mac 앱을 최신 버전으로 올린 뒤 QR 코드를 새로 여세요.")
        case .notAnOffer:
            String(localized: "RemoteDebug 페어링 링크가 아닙니다. Mac에 표시된 QR 코드나 링크를 사용하세요.")
        case .invalidHost, .invalidPort, .invalidSecret, .invalidExpiry:
            String(localized: "페어링 링크가 손상되었습니다. Mac에서 QR 코드를 새로 여세요.")
        case .invalidAuthKey:
            String(localized: "링크의 Tailscale 키가 올바르지 않습니다. Mac에서 새 QR 코드를 여세요.")
        case .wrappedAuthKey:
            String(localized: "링크의 Tailscale 키가 Tailnet Lock으로 서명된 형식이라 쓸 수 없습니다. 이 iPhone에서 먼저 Tailscale에 로그인한 뒤 Mac에서 QR 코드를 새로 여세요.")
        case .hostNotAllowed:
            String(localized: "Mac 주소는 .ts.net으로 끝나는 이름이어야 합니다. Mac에 표시된 QR 코드나 링크를 사용하세요.")
        }
    }
}

/// 짝 맺기(`PairingJoiner`)가 끝나지 못한 이유.
public enum PairingFailure: Error, Equatable, Sendable {
    /// 60초 안에 Mac에 닿지 못했다(VPN, 같은 tailnet, Tailnet Lock 서명).
    case unreachable
    /// 연결의 끝이 tailnet 주소가 아니다(VPN이 연결되지 않음).
    case notOnTailnet
    /// Mac이 제안을 받아 주지 않았다(만료, 이미 사용, 틀린 비밀).
    case rejected
    case denied
    case timedOut
    case hostNotVerified
    case protocolViolation
    /// 사용자가 그만뒀다. 안내 문구가 없다.
    case cancelled
    /// 그 밖의 실패(설정 오류 등).
    case unexpected

    /// 화면에 보일 안내. 사용자가 그만둔 경우는 `nil`.
    public var userMessage: String? {
        switch self {
        case .unreachable:
            String(localized: "60초 안에 Mac에 닿지 못했습니다. 이 iPhone의 VPN이 켜져 있고 Mac과 같은 tailnet에 있는지 확인하세요. Tailnet Lock을 쓰면 이 iPhone의 서명이 필요합니다. 확인한 뒤 같은 QR 코드를 다시 읽으세요.")
        case .notOnTailnet:
            String(localized: "이 iPhone의 VPN이 tailnet에 연결되어 있지 않아 Mac에 연결하지 않았습니다. VPN을 켠 뒤 다시 시도하세요.")
        case .rejected:
            String(localized: "Mac이 이 QR 코드를 받아 주지 않았습니다. 만료됐거나 이미 사용한 코드입니다. Mac에서 QR 코드를 새로 여세요.")
        case .denied:
            String(localized: "Mac에서 페어링을 거절했습니다. 다시 하려면 Mac에서 QR 코드를 새로 여세요.")
        case .timedOut:
            String(localized: "Mac에서 시간 안에 승인하지 않았습니다. Mac에서 QR 코드를 새로 열고 다시 시도하세요.")
        case .hostNotVerified:
            String(localized: "연결한 상대가 QR 코드를 낸 Mac인지 확인하지 못해 페어링을 멈췄습니다. Mac에서 QR 코드를 새로 열고 다시 시도하세요.")
        case .protocolViolation:
            String(localized: "Mac이 페어링 절차와 다르게 응답해 멈췄습니다. Mac 앱과 이 앱을 최신 버전으로 맞추세요.")
        case .cancelled:
            nil
        case .unexpected:
            String(localized: "페어링하지 못했습니다. 잠시 뒤 Mac에서 QR 코드를 새로 열고 다시 시도하세요.")
        }
    }
}

/// Swiftail 페어링과의 접점. 앱이 `SwiftailPairing`으로 구현하고, 시험은 가짜로 갈아 끼운다.
///
/// 터널 확장은 `SwiftailPairing`을 링크하지 않으므로 앱은 OS 소켓 판 `PairingJoiner`로 들어온다.
public protocol PairingService: Sendable {
    /// 링크·QR 글자를 제안으로 읽는다(`PairingOffer(link:)`). 읽는 쪽은 주소의 앞부분을 보지 않는다.
    func read(link: String) throws(PairingOfferIssue) -> PairingProposal

    /// 터널이 연결된 뒤에 부른다. 호출한 Task를 취소하면 연결을 끊고 `.cancelled`로 돌아온다.
    /// `awaitingApproval`은 Mac이 확인된 뒤 한 번 불리며 6자리 확인 숫자를 받는다(로그에 남기지 않는다).
    func join(
        _ proposal: PairingProposal, deviceName: String,
        awaitingApproval: @escaping @Sendable (_ confirmationCode: String) -> Void
    ) async throws(PairingFailure) -> JoinedHost
}

/// 페어링을 쓰지 않는 앱(업데이트 앱)용. 어떤 글자도 제안으로 읽지 않는다.
public struct UnavailablePairingService: PairingService {
    public init() {}

    public func read(link: String) throws(PairingOfferIssue) -> PairingProposal { throw .notAnOffer }

    public func join(
        _ proposal: PairingProposal, deviceName: String,
        awaitingApproval: @escaping @Sendable (String) -> Void
    ) async throws(PairingFailure) -> JoinedHost { throw .unexpected }
}

/// 앱이 받은 글자가 RemoteDebug 페어링 링크인지 가리고 제안으로 읽는다.
public enum PairingInput {
    /// Mac이 내는 링크의 `base`.
    public static let base = "remotedebug://pair"

    /// 글자가 페어링 링크 자리(`remotedebug://pair` 뒤에 끝, `#`, `?`와 그 앞의 `/` 하나)인가. 읽을 수 있는지는 보지 않는다.
    public static func isPairingAddress(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix(base) else { return false }
        var rest = lower.dropFirst(base.count)
        // 끝의 `/`는 하나만 받는다(`remotedebug://pair/#…`). 경로가 더 있으면 다른 주소다.
        if rest.first == "/" { rest = rest.dropFirst() }
        guard let next = rest.first else { return true }
        return next == "#" || next == "?"
    }

    /// 링크·QR 글자를 읽는다. 주소가 `remotedebug://pair`가 아니면 `.notAnOffer`, 예전 꼴이면 `.legacyLink`.
    public static func read(_ text: String, with service: any PairingService, policy: HostPolicy) throws(PairingOfferIssue) -> PairingProposal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPairingAddress(trimmed) else { throw .notAnOffer }
        let head = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let hasFragment = trimmed.contains("#")
        if head.contains("?") {
            let query = head.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).last.map { $0.lowercased() } ?? ""
            let legacy = query.split(separator: "&").contains { $0.hasPrefix("host=") || $0.hasPrefix("code=") }
            throw !hasFragment && legacy ? .legacyLink : .notAnOffer
        }
        let proposal = try service.read(link: trimmed)
        guard let valid = policy.validatedHost(proposal.host), valid == proposal.host else { throw .hostNotAllowed }
        return proposal
    }
}

/// 짝 맺기에 보내는 이 iPhone의 이름(Mac의 승인 화면에 보인다).
///
/// Swiftail은 1~64바이트이고 제어 문자(Cc)와 서식 문자(Cf)가 없는 이름만 받는다(글자를 잇는 U+200C·U+200D만 예외).
public enum PairingDeviceName {
    public static let maxBytes = 64

    public static func sanitized(_ name: String, fallback: String = "iPhone") -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .control { continue }
            if category == .format, scalar.value != 0x200C, scalar.value != 0x200D { continue }
            scalars.append(scalar)
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        var used = 0
        for character in cleaned {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            out.append(character)
            used += size
        }
        let result = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }
}
