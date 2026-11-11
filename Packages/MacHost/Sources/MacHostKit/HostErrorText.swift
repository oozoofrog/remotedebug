import Foundation
import RDModels

/// 오류를 사용자에게 보여 줄 문장으로 바꾼다. 앱 전체에서 이 함수 하나만 쓴다(타입 덤프를 보여 주지 않는다).
public enum HostErrorText {
    public static func message(for error: any Error) -> String {
        if let api = error as? APIErrorBody {
            return api.error.message.isEmpty ? coreCode(api.error.code) : api.error.message
        }
        if error is CancellationError { return "작업을 취소했습니다." }
        if let localized = error as? LocalizedError, let d = localized.errorDescription, !d.isEmpty { return d }
        return (error as NSError).localizedDescription
    }

    /// 코어 오류 코드(protocol §8, addenda B.1)를 한국어 문장으로. 모르는 코드만 그대로 보인다.
    public static func coreCode(_ code: String) -> String {
        switch code {
        case "not_paired": "페어링되지 않은 기기입니다. 이 기기를 쓰려면 페어링하세요."
        case "pair_code_invalid": "페어링 코드가 틀렸거나 만료됐습니다. 새 코드로 다시 시도하세요."
        case "too_many_attempts": "페어링 코드를 너무 많이 틀려 코드가 폐기됐습니다. 새 코드를 여세요."
        case "token_invalid": "설치 주소가 맞지 않습니다. iPhone에서 설치를 다시 시작하세요."
        case "session_expired": "설치 세션이 끝났습니다. iPhone에서 설치를 다시 시작하세요."
        case "build_not_found": "게시되지 않은 빌드입니다."
        case "build_changed": "게시본 파일이 바뀌었습니다. 빌드를 다시 가져오세요."
        case "not_debug_build": "디버그 빌드가 아니라 게시할 수 없습니다."
        case "hash_mismatch": "IPA 파일이 검사한 내용과 다릅니다. 빌드를 다시 가져오세요."
        case "path_outside_publish_dir": "게시 폴더 밖의 파일은 게시할 수 없습니다. 빌드를 다시 가져오세요."
        case "not_running": "공유가 꺼져 있습니다. 공유를 시작하세요."
        case "bad_request", "not_found", "method_not_allowed": "잘못된 요청입니다."
        case "internal": "코어 내부 오류가 발생했습니다. 공유를 중지했다가 다시 시작하세요."
        default: "알 수 없는 오류(\(code))"
        }
    }

    static func isBuildNotFound(_ error: any Error) -> Bool {
        (error as? APIErrorBody)?.error.code == "build_not_found"
    }
}
