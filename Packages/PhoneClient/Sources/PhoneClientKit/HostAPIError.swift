import Foundation

/// 호스트 REST 호출 실패. 호스트 오류 본문(protocol §8)이면 `status`·`code`·`message`가 그대로 들어 있고,
/// 클라이언트에서 판정한 실패(연결 실패 등)는 `status == 0`이다.
public struct HostAPIError: Error, Equatable, Sendable {
    public var status: Int
    public var code: String
    /// 호스트가 보낸 설명(디버깅용). 화면에는 `userMessage`를 쓴다.
    public var message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    // 클라이언트 판정 코드
    public static let connectionFailedCode = "connection_failed"
    public static let protocolMismatchCode = "protocol_mismatch"
    public static let invalidResponseCode = "invalid_response"
    /// 제한 시간 안에 응답이 오지 않았다. 연결 실패의 한 종류로 다룬다(`isConnectionFailure`).
    public static let timedOutCode = "timed_out"
    /// 받은 파일의 크기나 SHA-256이 목록과 다르다.
    public static let fileMismatchCode = "file_mismatch"

    static func connectionFailed(_ detail: String) -> HostAPIError {
        HostAPIError(status: 0, code: connectionFailedCode, message: detail)
    }

    static func timedOut(_ detail: String) -> HostAPIError {
        HostAPIError(status: 0, code: timedOutCode, message: detail)
    }

    static func protocolMismatch(_ detail: String) -> HostAPIError {
        HostAPIError(status: 0, code: protocolMismatchCode, message: detail)
    }

    static func invalidResponse(status: Int, _ detail: String) -> HostAPIError {
        HostAPIError(status: status, code: invalidResponseCode, message: detail)
    }

    /// 연결 실패나 응답 시간 초과. 진행 확인(폴링)은 이 오류를 일시적인 것으로 보고 다시 시도한다.
    public var isConnectionFailure: Bool { code == Self.connectionFailedCode || code == Self.timedOutCode }

    /// 사용자에게 보여 줄 한국어 안내(사실 + 다음 행동).
    public var userMessage: String {
        switch code {
        case "not_paired":
            "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요."
        case "pair_code_invalid":
            "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요."
        case "too_many_attempts":
            "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요."
        case "token_invalid":
            "설치 세션을 확인할 수 없습니다. 다시 설치하세요."
        case "session_expired":
            "설치 세션이 만료되었습니다. 다시 설치하세요."
        case "build_not_found":
            "Mac에 이 빌드가 없습니다. 목록을 새로고침하세요."
        case "resource_not_found":
            "Mac에서 이 파일을 지웠습니다. 목록을 새로고침하세요."
        case Self.fileMismatchCode:
            "받은 파일이 Mac의 파일과 다릅니다. 다시 받으세요."
        case "build_changed":
            "Mac에서 빌드가 바뀌었습니다. 목록을 새로고침하세요."
        case "not_debug_build":
            "디버그 빌드가 아니라서 설치할 수 없습니다. Mac에서 Debug 빌드를 게시하세요."
        case "not_found", "method_not_allowed", "bad_request":
            "Mac 앱이 이 요청을 처리하지 못했습니다. iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요."
        case "internal":
            "Mac 앱에서 오류가 났습니다. 잠시 뒤 다시 시도하세요."
        case Self.connectionFailedCode, Self.timedOutCode:
            "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요."
        case Self.protocolMismatchCode:
            "Mac 앱과 통신 규약 버전이 다릅니다. iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요."
        default:
            "Mac에서 알 수 없는 응답을 받았습니다. 잠시 뒤 다시 시도하세요."
        }
    }
}
