import Foundation

/// 확장이 NE 프로세스 경계를 넘겨 보내는 오류(`startTunnel` 완료 처리기, `cancelTunnelWithError`).
///
/// Swift `LocalizedError`는 다른 프로세스에서 설명이 사라지므로 늘 `NSError`로 만든다.
/// 도메인과 코드는 고정이고, 설명은 `NSLocalizedDescriptionKey`에 한국어로 담는다.
/// 앱은 `fetchLastDisconnectError()`로 받은 오류를 `userMessage(for:)`로 안내 문구로 바꾼다.
enum TunnelProviderError: Int, CaseIterable, Sendable {
    case missingConfiguration = 1
    case placeholderFailed = 2
    case utunNotFound = 3
    case coreStart = 4
    case engineStopped = 5
    case stoppedDuringStart = 6

    static let domain = "com.oozoofrog.app.RemoteDebugPhone.Tunnel"

    /// 코드별 기본 안내. `coreStart`는 코어 메시지를 덧붙인다.
    var message: String {
        switch self {
        case .missingConfiguration: "VPN 구성을 읽지 못했습니다. 앱에서 VPN을 다시 켜세요."
        case .placeholderFailed: "VPN 네트워크 설정을 적용하지 못했습니다. VPN을 다시 켜세요."
        case .utunNotFound: "VPN 장치(utun)를 찾지 못했습니다. VPN을 다시 켜세요."
        case .coreStart: "tailnet 연결을 시작하지 못했습니다. VPN을 다시 켜세요."
        case .engineStopped: TunnelEngineMessages.tunDeviceClosed + " 앱에서 VPN을 다시 켜세요."
        case .stoppedDuringStart: "VPN을 켜는 중에 꺼졌습니다. 필요하면 VPN을 다시 켜세요."
        }
    }

    /// 경계를 넘길 `NSError`. `detail`은 `coreStart`의 코어 메시지.
    func nsError(detail: String? = nil) -> NSError {
        var text = message
        if self == .coreStart, let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            text = "tailnet 연결을 시작하지 못했습니다: \(TunnelSecretRedactor.redact(detail))"
        }
        return NSError(domain: Self.domain, code: rawValue, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// 이 확장이 보낸 오류면 그 종류를, 아니면 `nil`. NE가 감싼 경우(`NSUnderlyingErrorKey`)도 찾는다.
    static func kind(of error: any Error) -> TunnelProviderError? {
        find(in: error)?.kind
    }

    /// 이 확장이 보낸 오류면 안내 문구를, 아니면 `nil`. NE가 감싼 경우(`NSUnderlyingErrorKey`)도 찾는다.
    static func userMessage(for error: any Error) -> String? {
        guard let (candidate, known) = find(in: error) else { return nil }
        let text = (candidate.userInfo[NSLocalizedDescriptionKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? known.message : text
    }

    /// 바깥 오류부터 `NSUnderlyingErrorKey`를 따라(최대 4단계) 처음 만나는 이 확장의 오류.
    private static func find(in error: any Error) -> (error: NSError, kind: TunnelProviderError)? {
        var current: NSError? = error as NSError
        var depth = 0
        while let candidate = current, depth < 4 {
            if candidate.domain == domain, let known = TunnelProviderError(rawValue: candidate.code) {
                return (candidate, known)
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}

/// 문자열에 섞인 Tailscale 인증 키(`tskey-…`)를 가린다. 확장은 키를 보관하지 않지만
/// 코어 오류 메시지에 키가 들어 있을 수 있으므로 앱으로 보내는 글자에는 늘 이것을 거친다.
enum TunnelSecretRedactor {
    static let placeholder = "[인증 키 가림]"

    static func redact(_ text: String) -> String {
        guard text.range(of: "tskey", options: .caseInsensitive) != nil else { return text }
        var output = ""
        var rest = Substring(text)
        while let range = rest.range(of: "tskey", options: .caseInsensitive) {
            output += rest[..<range.lowerBound]
            output += placeholder
            var end = range.upperBound
            while end < rest.endIndex, isKeyCharacter(rest[end]) { end = rest.index(after: end) }
            rest = rest[end...]
        }
        output += rest
        return output
    }

    static func redact(_ text: String?) -> String? {
        text.map { redact($0) }
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }
}
