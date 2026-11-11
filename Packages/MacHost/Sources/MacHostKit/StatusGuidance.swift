import Foundation
import RDModels

/// 공유 상태별 안내문(사용자에게 필요한 사실과 다음 행동).
public struct StatusGuidance: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case stopped
        case starting
        case needsLogin
        case waitingForLoginURL
        case needsMachineAuth
        case certificatesDisabled
        case magicDNSDisabled
        case issuingCertificate
        case ready
        case error
        case unknown
    }

    public enum Action: Sendable, Hashable {
        case start
        case openLoginPage
        case restart
    }

    public var kind: Kind
    public var title: String
    public var message: String
    public var action: Action?

    public init(kind: Kind, title: String, message: String, action: Action? = nil) {
        self.kind = kind
        self.title = title
        self.message = message
        self.action = action
    }

    /// Tailscale 관리 콘솔의 DNS 페이지(MagicDNS·HTTPS Certificates 설정).
    public static let dnsConsoleURL = "https://login.tailscale.com/admin/dns"

    static let stoppedGuidance = StatusGuidance(
        kind: .stopped, title: "공유 중지됨",
        message: "iPhone에서 이 Mac의 빌드를 볼 수 없습니다. 공유를 시작하면 이 Mac이 tailnet에 연결됩니다.",
        action: .start)

    /// 공유를 시작했지만 아직 상태를 받지 못했을 때.
    public static let startingGuidance = StatusGuidance(
        kind: .starting, title: "공유 시작 중",
        message: "tailnet 연결이 끝나면 페어링한 iPhone에서 빌드 목록을 볼 수 있습니다.")

    static let certificatesOff = StatusGuidance(
        kind: .certificatesDisabled, title: "HTTPS 인증서 꺼짐",
        message: "tailnet의 HTTPS 인증서 사용이 꺼져 있어 설치 주소를 만들 수 없습니다. Tailscale 관리 콘솔의 DNS 페이지(\(dnsConsoleURL))에서 MagicDNS와 HTTPS Certificates를 켜세요. 켜면 공유를 다시 시작하지 않아도 잠시 뒤 설치 주소가 열립니다.")

    static let magicDNSOff = StatusGuidance(
        kind: .magicDNSDisabled, title: "MagicDNS 꺼짐",
        message: "tailnet의 MagicDNS가 꺼져 있어 설치 주소를 만들 수 없습니다. Tailscale 관리 콘솔의 DNS 페이지(\(dnsConsoleURL))에서 MagicDNS와 HTTPS Certificates를 켜세요. 켜면 공유를 다시 시작하지 않아도 잠시 뒤 설치 주소가 열립니다.")

    /// `status`가 nil이면 공유하지 않는 상태로 본다.
    public static func make(for status: CoreStatus?) -> StatusGuidance {
        guard let status else { return stoppedGuidance }
        switch status.backendState {
        case .stopped:
            return stoppedGuidance
        case .starting:
            return startingGuidance
        case .needsLogin:
            if status.authURL.isEmpty {
                return StatusGuidance(
                    kind: .waitingForLoginURL, title: "로그인 필요",
                    message: "tailnet 로그인이 필요합니다. 로그인 주소를 받는 중이니 잠시 기다리세요. 계속 나타나지 않으면 인증 키를 넣어 공유를 다시 시작하세요.",
                    action: .restart)
            }
            return StatusGuidance(
                kind: .needsLogin, title: "로그인 필요",
                message: "tailnet 로그인이 필요합니다. 로그인 페이지를 열어 이 Mac을 tailnet에 추가하세요.",
                action: .openLoginPage)
        case .needsMachineAuth:
            return StatusGuidance(
                kind: .needsMachineAuth, title: "기기 승인 필요",
                message: "tailnet 관리자가 이 Mac을 승인해야 합니다. Tailscale 관리 콘솔의 Machines에서 \(status.hostname.isEmpty ? "이 Mac" : status.hostname)을 승인하세요.")
        case .running:
            if status.certDomains.isEmpty { return certificatesOff }
            if !status.tlsReady {
                return StatusGuidance(
                    kind: .issuingCertificate, title: "인증서 발급 중",
                    message: "HTTPS 인증서를 발급받고 있습니다. 발급이 끝나면 iPhone에서 설치할 수 있습니다.")
            }
            return StatusGuidance(
                kind: .ready, title: "공유 중",
                message: status.fqdn.isEmpty
                    ? "페어링한 iPhone에서 게시한 빌드를 설치할 수 있습니다."
                    : "페어링한 iPhone에서 \(status.fqdn)의 빌드를 설치할 수 있습니다.")
        case .error:
            let detail = status.errorMessage.flatMap { $0.isEmpty ? nil : $0 }
            // 코어는 HTTPS·MagicDNS가 꺼져 리스너가 3번 연속 열리지 않으면 Error로 알린다(addenda A.5).
            // 다시 시작해도 낫지 않고, 설정을 켜면 코어가 스스로 다시 연다.
            if let detail, detail.hasPrefix("host listener:") {
                if detail.contains("MagicDNS") { return magicDNSOff }
                if detail.contains("HTTPS") || detail.contains("인증서") || status.certDomains.isEmpty { return certificatesOff }
                return StatusGuidance(
                    kind: .error, title: "공유 오류",
                    message: "설치 주소를 열지 못했습니다: \(detail.dropFirst("host listener:".count).trimmingCharacters(in: .whitespaces)). 원인을 고친 뒤 공유를 다시 시작하세요.",
                    action: .restart)
            }
            return StatusGuidance(
                kind: .error, title: "공유 오류",
                message: (detail ?? "코어가 원인을 알리지 않았습니다.") + " 공유를 다시 시작하세요.",
                action: .restart)
        default:
            return StatusGuidance(kind: .unknown, title: "알 수 없는 상태",
                                  message: "코어가 알 수 없는 상태(\(status.backendState.rawValue))를 보냈습니다. 계속되면 공유를 다시 시작하세요.",
                                  action: .restart)
        }
    }
}

/// 활동 목록 한 줄.
public struct ActivityItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case denied(DeniedEvent)
        case session(SessionEvent)
        case pairDecided(PairDecidedEvent)
        case deviceAdded(DeviceEntry)
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var text: String

    public init(id: UUID = UUID(), date: Date, kind: Kind, text: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
    }

    var sessionID: String? {
        if case .session(let e) = kind { return e.sessionId }
        return nil
    }
}

enum ActivityText {
    static func denied(_ e: DeniedEvent) -> String {
        let who = e.nodeName.flatMap { $0.isEmpty ? nil : $0 } ?? "알 수 없는 기기"
        var text = "\(who)의 \(e.path) 요청을 거부했습니다. \(HostErrorText.coreCode(e.reason))"
        if let n = e.suppressed, n > 0 { text += " 같은 요청 \(n)건을 더 거부했습니다." }
        return text
    }

    static func session(_ e: SessionEvent, buildName: String?) -> String {
        let build = buildName ?? e.buildId
        let state: String = switch e.state {
        case .created: "설치 준비"
        case .manifestServed: "설치 정보 전송"
        case .downloading: "내려받는 중"
        case .completed: "설치 파일 전송 완료"
        case .expired: "만료"
        case .failed: "실패"
        }
        return "\(e.nodeName) · \(build): \(state)"
    }

    static func pairDecided(_ e: PairDecidedEvent, deviceName: String?) -> String {
        let who = deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? "iPhone"
        return switch e.state {
        case .approved: "\(who) 페어링을 허용했습니다."
        case .denied: "\(who) 페어링을 거부했습니다."
        case .expired: "\(who) 페어링 요청이 만료됐습니다. iPhone에서 다시 요청하세요."
        case .pending: "\(who) 페어링 요청이 허용을 기다립니다."
        }
    }
}
