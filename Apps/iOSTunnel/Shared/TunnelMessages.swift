import Foundation
import RDModels

/// 앱 → 확장 메시지(`sendProviderMessage`). JSON: `{"cmd":"status"}` 또는 `{"cmd":"status","peer":"mac.example.ts.net"}`.
struct TunnelAppRequest: Codable, Equatable, Sendable {
    enum Command: String, Codable, Sendable {
        case status
    }

    var cmd: Command
    /// 경로(직접·중계)를 알고 싶은 피어의 MagicDNS 이름(페어링한 Mac). 없으면 확장은 경로를 알아보지 않는다.
    var peer: String?

    static let status = TunnelAppRequest(cmd: .status)

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> TunnelAppRequest? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// 확장의 수명 단계(코어 상태와 별개).
enum TunnelExtensionPhase: String, Codable, Sendable {
    /// `startTunnel`을 받아 코어를 시작하는 중.
    case starting
    /// 코어가 돌고 있다.
    case running
    /// `stopTunnel`이나 엔진 사망으로 멈추는 중.
    case stopping
    /// 시작에 실패했거나 엔진이 멈췄다.
    case failed
}

/// 확장 → 앱 응답. 인증 키·토큰은 담지 않는다(`CoreStatus`에는 `authURL`만 있다).
///
/// ```json
/// {"phase":"running","status":{…rd_status…},"physFootprintMiB":31.5,"lastError":null}
/// ```
struct TunnelStatusReply: Codable, Equatable, Sendable {
    var phase: TunnelExtensionPhase
    /// `rd_status`. 코어가 아직 없으면 `nil`.
    var status: CoreStatus?
    /// 확장 프로세스의 phys_footprint(MiB, `TASK_VM_INFO`). 읽지 못하면 `nil`.
    var physFootprintMiB: Double?
    /// 확장이 마지막으로 겪은 오류(한국어 또는 코어 메시지).
    var lastError: String?
    /// 요청을 이해하지 못했을 때의 코드(`unknown_command`).
    var error: String?

    init(phase: TunnelExtensionPhase, status: CoreStatus? = nil, physFootprintMiB: Double? = nil, lastError: String? = nil, error: String? = nil) {
        self.phase = phase
        self.status = status
        self.physFootprintMiB = physFootprintMiB
        self.lastError = lastError
        self.error = error
    }

    static let unknownCommand = "unknown_command"

    /// 확장이 앱에 돌려줄 응답을 만든다. 코어 오류 메시지와 마지막 오류에서 인증 키(`tskey-…`)를 가린다.
    static func make(phase: TunnelExtensionPhase, status: CoreStatus?, physFootprintMiB: Double?, lastError: String?) -> TunnelStatusReply {
        var status = status
        if let message = status?.errorMessage {
            status?.errorMessage = TunnelSecretRedactor.redact(message)
        }
        return TunnelStatusReply(
            phase: phase,
            status: status,
            physFootprintMiB: physFootprintMiB,
            lastError: TunnelSecretRedactor.redact(lastError)
        )
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> TunnelStatusReply? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// 엔진이 utun을 닫았을 때 코어가 보내는 `errorMessage`(docs/tunnel.md).
enum TunnelEngineMessages {
    static let tunDeviceClosed = "TUN 장치가 닫혔습니다."
}
