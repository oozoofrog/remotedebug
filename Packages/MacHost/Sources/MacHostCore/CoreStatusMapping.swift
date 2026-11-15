// Swiftail 노드의 모습 → protocol §9 `CoreStatus`. 소켓도 시계도 없는 값 함수라 시험이 그대로 부른다.
//
// 화면(`StatusGuidance`)은 예전 Go 코어 때부터 쓰던 상태 이름과 오류 문구 머리(`host listener:`)로 안내를 고른다. 새 상태 이름을 만들지 않고
// 그 자리에 맞춘다:
// - 로그인 필요 두 모양(실행 중 `needsLogin(url)`, `run()`이 `nodeKeyExpired`로 끝남) → 둘 다 `NeedsLogin`.
// - 기기 승인 → `NeedsMachineAuth`.
// - HTTPS 인증서 꺼짐 → `Running` + 빈 `certDomains`(화면이 "HTTPS 인증서 꺼짐"을 고른다).
// - MagicDNS 꺼짐·이름이 cert 도메인에 없음·발급 한도 → `Error` + `host listener: …`(예전 Go 코어의 리스너 실패와 같은 자리).
// - 첫 발급(약 40초)과 물러났다 다시 하는 실패 → `Running` + `tlsReady == false`(화면의 "인증서 발급 중").
import Foundation
import RDModels
import Swiftail
import SwiftailCertificates
import SwiftailControl
import SwiftailHostServer

/// 노드 수명의 단계.
enum NodePhase: Sendable, Equatable {
    /// `run()`이 돌고 있다.
    case running
    /// `run()`이 다시 켜도 소용없는 실패로 끝났다. 사용자가 공유를 다시 시작할 때까지 그대로 둔다(다시 켜는 고리를 돌지 않는다).
    case ended(NodeEnd)
}

/// `run()`이 끝난 까닭. 문구에 키·URL·이름을 넣지 않는다.
enum NodeEnd: Sendable, Equatable {
    /// 새 node 키로도 만료(`control(.nodeKeyExpired)`). 다시 로그인해야 한다.
    case nodeKeyExpired
    /// 인증 키를 서버가 받지 않았다.
    case authKeyRejected
    /// 인증 키 없는 등록을 서버가 거절했다.
    case registrationRejected
    case stateDirectoryInUse
    case udpUnavailable
    case listenFailed
    case configuration
    case other

    init(_ error: any Error) {
        switch error {
        case let error as NodeError:
            switch error {
            case .control(let control):
                switch control {
                case .nodeKeyExpired: self = .nodeKeyExpired
                case .authKeyRejected: self = .authKeyRejected
                case .registrationRejected: self = .registrationRejected
                case .invalidConfiguration: self = .configuration
                case .storage, .connection, .http: self = .other
                }
            case .invalidConfiguration: self = .configuration
            case .udpUnavailable: self = .udpUnavailable
            case .stateDirectoryInUse: self = .stateDirectoryInUse
            case .tunnelDeviceClosed: self = .other
            }
        case is ConnectionError: self = .listenFailed
        case is CertificateError: self = .other
        default: self = .other
        }
    }

    /// `errorMessage`(화면에 나온다). 로그인 필요는 오류가 아니라 nil.
    /// `host listener:` 머리는 화면이 안내를 고르는 표지라 번역하지 않는다(`StatusGuidance`).
    var message: String? {
        switch self {
        case .nodeKeyExpired: nil
        case .authKeyRejected: String(localized: "인증 키가 받아들여지지 않았습니다. 키가 만료됐거나 이미 쓰였는지 확인하세요.")
        case .registrationRejected: String(localized: "제어 서버가 이 Mac의 등록을 거절했습니다.")
        case .stateDirectoryInUse: String(localized: "다른 노드가 같은 상태 폴더를 쓰고 있습니다.")
        case .udpUnavailable: String(localized: "tailnet에 쓸 UDP 소켓을 열지 못했습니다.")
        case .listenFailed: CoreStatusMapping.listenerPrefix + String(localized: "tailnet 포트를 열지 못했습니다.")
        case .configuration: String(localized: "노드 설정이 올바르지 않습니다.")
        case .other: String(localized: "tailnet 노드가 멈췄습니다.")
        }
    }

    /// 로그 한 줄(종류만).
    var logName: String {
        switch self {
        case .nodeKeyExpired: "nodeKeyExpired"
        case .authKeyRejected: "authKeyRejected"
        case .registrationRejected: "registrationRejected"
        case .stateDirectoryInUse: "stateDirectoryInUse"
        case .udpUnavailable: "udpUnavailable"
        case .listenFailed: "listenFailed"
        case .configuration: "invalidConfiguration"
        case .other: "other"
        }
    }
}

enum CoreStatusMapping {
    /// 화면(`StatusGuidance`)이 리스너 실패를 알아보는 머리. 번역하지 않는다.
    static let listenerPrefix = "host listener: "

    struct Input: Sendable {
        var phase: NodePhase
        var node: NodeSnapshot
        var certificate: CertificateSnapshot?
        var serving: ServingState
        var hostname: String
        var counts: (builds: Int, devices: Int)
        var direct: DirectStatus?
        var rssMiB: Double
    }

    static func status(_ input: Input) -> CoreStatus {
        var status = CoreStatus(backendState: .starting, hostname: input.hostname)
        status.fqdn = input.node.fqdn ?? ""
        status.tailscaleIPs = input.node.addresses
        status.certDomains = input.node.certDomains
        status.tlsReady = input.serving.tlsReady
        status.listening = input.serving.listening
        status.publishedBuilds = input.counts.builds
        status.pairedDevices = input.counts.devices
        status.direct = input.direct
        status.rssMiB = input.rssMiB
        // shortcut: `peerPaths`(페어링한 기기까지의 경로, addenda N)는 내지 않는다. Swiftail은 이름으로만 경로를 묻고
        // (`path(toPeerNamed:)`) 허용 목록은 안정 ID다. 필요해지는 시점: 기기 화면에 경로 표시를 되살릴 때(연결의
        // `whoIs` 이름을 안정 ID와 함께 기억하거나 Swiftail에 안정 ID 조회가 생기면).

        switch input.phase {
        case .ended(let end):
            status.tlsReady = false
            status.listening = false
            if let message = end.message {
                status.backendState = .error
                status.errorMessage = message
            } else {
                // 다시 로그인: 로그인 주소는 다시 시작한 노드가 새로 받는다.
                status.backendState = .needsLogin
            }
            return status
        case .running:
            break
        }

        switch input.node.state {
        case .starting:
            status.backendState = .starting
        case .needsLogin(let url):
            status.backendState = .needsLogin
            status.authURL = url.absoluteString
        case .needsMachineAuth:
            status.backendState = .needsMachineAuth
        case .running:
            status.backendState = .running
            status.lockWait = input.node.signingRequest
            if !status.tlsReady, let failure = input.certificate?.lastFailure, let message = userFixable(failure) {
                status.backendState = .error
                status.errorMessage = message
            }
        }
        return status
    }

    /// 사용자가 tailnet 설정을 고쳐야 하거나 시간이 지나야 풀리는 실패의 `errorMessage`. 화면은 `host listener:` 머리와
    /// `MagicDNS`·`HTTPS`·`인증서` 낱말로 안내를 고른다(그 낱말이 있으면 "HTTPS 인증서 꺼짐"이 되므로 다른 실패에는 쓰지 않는다). HTTPS 꺼짐은 빈 `certDomains`가 알리므로 여기서 다루지 않는다.
    /// 첫 발급 전(`nodeNotRunning`)과 물러났다 다시 하는 실패는 nil(발급 중으로 보인다).
    static func userFixable(_ failure: CertificateFailure) -> String? {
        switch failure {
        case .magicDNSDisabled:
            // 번역문에도 MagicDNS 낱말이 있어야 화면이 MagicDNS 안내를 고른다.
            return listenerPrefix + String(localized: "tailnet의 MagicDNS가 꺼져 있습니다.")
        case .domainNotAllowed:
            return listenerPrefix + String(localized: "이 Mac의 이름이 tailnet의 TLS 도메인 목록에 없습니다")
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return listenerPrefix + String(localized: "Let's Encrypt 발급 한도에 걸렸습니다(\(RDTimestamp.string(retryAfter)) 뒤 다시 시도)")
            }
            return listenerPrefix + String(localized: "Let's Encrypt 발급 한도에 걸렸습니다")
        case .httpsNotEnabled, .nodeNotRunning, .controlRejected, .acme, .validationFailed, .orderFailed, .unexpectedResponse,
             .invalidCertificate, .network, .timedOut:
            return nil
        }
    }

    /// 인증서 실패의 로그 이름(종류만, 연관 문자열 없이).
    static func logName(_ failure: CertificateFailure) -> String {
        switch failure {
        case .nodeNotRunning: "nodeNotRunning"
        case .magicDNSDisabled: "magicDNSDisabled"
        case .httpsNotEnabled: "httpsNotEnabled"
        case .domainNotAllowed: "domainNotAllowed"
        case .controlRejected(let status): "controlRejected(\(status))"
        case .acme(let status, _): "acme(\(status))"
        case .rateLimited: "rateLimited"
        case .validationFailed: "validationFailed"
        case .orderFailed: "orderFailed"
        case .unexpectedResponse: "unexpectedResponse"
        case .invalidCertificate: "invalidCertificate"
        case .network: "network"
        case .timedOut: "timedOut"
        }
    }

    /// 상태 이벤트를 낼지 견줄 때 메모리 값은 뺀다(예전 Go 코어의 monitor와 같은 규칙).
    static func comparable(_ status: CoreStatus) -> CoreStatus {
        var copy = status
        copy.rssMiB = 0
        return copy
    }

    /// 호스트의 기준 주소(예전 Go 코어의 `host.BaseURL`과 같은 규칙).
    static func baseURL(tls: Bool, fqdn: String, port: Int) -> String {
        let name = fqdn.hasSuffix(".") ? String(fqdn.dropLast()) : fqdn
        if tls { return port == 443 || port == 0 ? "https://\(name)" : "https://\(name):\(port)" }
        return "http://\(name):\(port)"
    }
}
