import Foundation

/// 코드를 읽지 못한 이유.
public enum PairingCodeError: Error, Equatable, Sendable {
    /// 글자 수(하이픈·공백 제외)가 8이 아니다.
    case invalidCodeLength
    /// 쓰지 않는 글자(`U`, 기호, 영문·숫자가 아닌 글자)가 있다.
    case invalidCodeCharacters
}

/// 예전 코드 페어링(protocol §2, 서버 경로 `/v1/pair/request`)의 코드: Crockford base32 8자.
/// 앱의 페어링은 Swiftail 페어링(QR·링크)으로 옮겼고 이 앱은 코드를 입력받지 않는다. Mac 호스트 시험이
/// 서버의 예전 경로를 부르는 데만 `HostAPI.requestPairing`과 함께 남아 있다. 하이픈·공백·대소문자를 무시하고,
/// Crockford 규칙대로 `O`→`0`, `I`/`L`→`1`로 읽는다. `U`는 쓰지 않는 글자라 거부한다.
public struct PairingCode: Hashable, Sendable {
    /// 정규화한 8자(예: `K7M29QXD`). 로그에 남기지 않는다.
    public let normalized: String

    public init?(_ text: String) {
        guard let code = try? Self.parse(text) else { return nil }
        self = code
    }

    private init(normalized: String) {
        self.normalized = normalized
    }

    /// 코드를 읽는다. 쓰지 않는 글자가 있으면 `.invalidCodeCharacters`, 글자 수가 8이 아니면 `.invalidCodeLength`.
    public static func parse(_ text: String) throws(PairingCodeError) -> PairingCode {
        var out = ""
        var badCharacter = false
        for ch in text.uppercased() {
            switch ch {
            case "-", " ", "\t": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            case "U": badCharacter = true
            default:
                if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) } else { badCharacter = true }
            }
        }
        if badCharacter { throw .invalidCodeCharacters }
        guard out.count == 8 else { throw .invalidCodeLength }
        return PairingCode(normalized: out)
    }

    /// 화면 표시용(`K7M2-9QXD`).
    public var display: String {
        String(normalized.prefix(4)) + "-" + String(normalized.suffix(4))
    }
}

extension PairingCode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PairingCode(••••-••••)" }
    public var debugDescription: String { description }
}
