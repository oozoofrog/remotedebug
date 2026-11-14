import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 페어링 코드(protocol §2): Crockford base32 8자. 하이픈·공백·대소문자를 무시하고,
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
    public static func parse(_ text: String) throws(PairingLinkError) -> PairingCode {
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

/// 페어링 코드를 보낼 수 있는 호스트 주소의 정책.
///
/// 호스트는 `https://<MagicDNS FQDN>`으로만 닿고 TLS 인증서도 그 이름으로 발급되므로(protocol §1),
/// 출하 정책은 `<기기>.<tailnet>.ts.net` 꼴의 이름만 받는다(라벨 경계에서 대소문자 무시). IP 주소는 받지 않는다.
public struct HostPolicy: Hashable, Sendable {
    /// 루프백(`localhost`, `127.0.0.0/8`, `::1`)도 허용한다. 테스트 전용.
    public var allowsLoopback: Bool

    public init(allowsLoopback: Bool) {
        self.allowsLoopback = allowsLoopback
    }

    /// `.ts.net` 이름만 허용한다.
    public static let tailnetOnly = HostPolicy(allowsLoopback: false)
    /// 테스트용: `.ts.net` 이름과 루프백을 허용한다.
    public static let allowingLoopbackForTesting = HostPolicy(allowsLoopback: true)

    /// 정책을 통과하면 정규화한 호스트(소문자, 끝 점 하나 제거)를, 아니면 `nil`을 돌려준다.
    public func validatedHost(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if allowsLoopback, let loopback = Self.loopbackHost(text) { return loopback }
        guard let name = Self.normalizedName(text) else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        // MagicDNS 이름은 `<기기>.<tailnet>.ts.net`이다.
        guard labels.count >= 4, labels[labels.count - 2] == "ts", labels[labels.count - 1] == "net" else { return nil }
        return name
    }

    /// DNS 이름을 소문자로 바꾸고 끝 점 하나를 지운다. 올바른 이름(라벨 1~63자, `a-z0-9-`, 하이픈으로 시작·끝나지 않음)이 아니면 `nil`.
    static func normalizedName(_ raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253, isValidHostname(host) else { return nil }
        return host
    }

    /// 루프백 주소면 정규화한 값(`localhost`, `127.x.y.z`, `::1`)을, 아니면 `nil`.
    static func loopbackHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" { return host }
        if let v4 = parseIPv4(host), v4[0] == 127 { return host }
        if host.contains(":"), let v6 = parseIPv6(host), v6 == [UInt8](repeating: 0, count: 15) + [1] { return host }
        return nil
    }

    private static func isValidHostname(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
            for ch in label.unicodeScalars {
                guard ("a"..."z").contains(ch) || ("0"..."9").contains(ch) || ch == "-" else { return false }
            }
        }
        return true
    }

    /// 엄격한 점 4개 10진수 IPv4(앞자리 0 금지).
    static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            guard p.count == 1 || p.first != "0", let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    static func parseIPv6(_ text: String) -> [UInt8]? {
        guard !text.contains("%") else { return nil }  // 영역 식별자는 받지 않는다
        var addr = in6_addr()
        let ok = text.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
        guard ok else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }
}

/// `remotedebug://pair?host=<fqdn>&code=<code>` 링크를 읽지 못한 이유.
public enum PairingLinkError: Error, Equatable, Sendable {
    /// `remotedebug://pair` 링크가 아니다.
    case notPairingLink
    case missingHost
    /// 코드가 없거나 글자 수(하이픈·공백 제외)가 8이 아니다.
    case invalidCodeLength
    /// 코드에 쓰지 않는 글자(`U`, 기호, 영문·숫자가 아닌 글자)가 있다.
    case invalidCodeCharacters
    /// 호스트가 정책(`.ts.net` 이름)을 통과하지 못했다.
    case hostNotAllowed
    /// 함께 온 Tailscale 키의 모양이 틀렸다.
    case invalidAuthKey

    public var userMessage: String {
        switch self {
        case .notPairingLink: String(localized: "RemoteDebug 페어링 링크가 아닙니다. Mac에 표시된 QR 코드나 링크를 사용하세요.")
        case .missingHost: String(localized: "링크에 Mac 주소가 없습니다. Mac에 표시된 링크를 다시 복사하세요.")
        case .invalidCodeLength: String(localized: "페어링 코드는 8자입니다. Mac에 표시된 코드를 다시 확인하세요.")
        case .invalidCodeCharacters: String(localized: "페어링 코드에 쓰지 않는 글자가 들어 있습니다. Mac에 표시된 코드를 다시 확인하세요.")
        case .hostNotAllowed: String(localized: "Mac 주소는 .ts.net으로 끝나는 이름이어야 합니다. Mac에 표시된 링크나 주소를 사용하세요.")
        case .invalidAuthKey: String(localized: "링크의 Tailscale 키가 올바르지 않습니다. Mac에서 새 QR 코드를 여세요.")
        }
    }
}

/// protocol §2 페어링 링크. 만들어진 값의 `host`는 정책을 통과한 정규화 주소다.
public struct PairingLink: Hashable, Sendable {
    public let host: String
    public let code: PairingCode
    /// Mac이 함께 넣은 1회용 Tailscale 인증 키(`tskey-auth-…`). 있으면 로그인 없이 VPN을 켠다. 로그에 남기지 않는다.
    public let authKey: String?

    public init(host: String, code: String, authKey: String? = nil, policy: HostPolicy = .tailnetOnly) throws(PairingLinkError) {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { throw .missingHost }
        guard let validHost = policy.validatedHost(host) else { throw .hostNotAllowed }
        self.code = try PairingCode.parse(code)
        self.host = validHost
        if let authKey {
            guard Self.isAuthKey(authKey) else { throw .invalidAuthKey }
            self.authKey = authKey
        } else {
            self.authKey = nil
        }
    }

    /// Tailscale 인증 키 모양: `tskey-auth-`로 시작하고 영문·숫자·하이픈만, 200자 이하.
    public static func isAuthKey(_ text: String) -> Bool {
        text.hasPrefix("tskey-auth-") && text.count <= 200
            && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    public static func parse(url: URL, policy: HostPolicy = .tailnetOnly) throws(PairingLinkError) -> PairingLink {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme?.lowercased() == "remotedebug",
              comps.host?.lowercased() == "pair",
              comps.path.isEmpty || comps.path == "/",
              comps.user == nil, comps.password == nil, comps.port == nil
        else { throw .notPairingLink }
        let items = comps.queryItems ?? []
        let hosts = items.filter { $0.name == "host" }
        let codes = items.filter { $0.name == "code" }
        let keys = items.filter { $0.name == "key" }
        guard hosts.count <= 1, codes.count <= 1, keys.count <= 1 else { throw .notPairingLink }
        guard let host = hosts.first?.value, !host.isEmpty else { throw .missingHost }
        guard let code = codes.first?.value else { throw .invalidCodeLength }
        return try PairingLink(host: host, code: code, authKey: keys.first?.value, policy: policy)
    }

    public static func parse(text: String, policy: HostPolicy = .tailnetOnly) throws(PairingLinkError) -> PairingLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw .notPairingLink }
        return try parse(url: url, policy: policy)
    }

    public init?(url: URL, policy: HostPolicy = .tailnetOnly) {
        guard let link = try? Self.parse(url: url, policy: policy) else { return nil }
        self = link
    }

    public init?(text: String, policy: HostPolicy = .tailnetOnly) {
        guard let link = try? Self.parse(text: text, policy: policy) else { return nil }
        self = link
    }

    /// 링크 문자열(공유·QR용). 코드가 들어 있으니 로그에 남기지 않는다.
    public var url: URL {
        var comps = URLComponents()
        comps.scheme = "remotedebug"
        comps.host = "pair"
        comps.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "code", value: code.normalized)]
        if let authKey { comps.queryItems?.append(URLQueryItem(name: "key", value: authKey)) }
        return comps.url!
    }
}

extension PairingLink: CustomStringConvertible, CustomDebugStringConvertible {
    /// 코드를 가린 표현.
    public var description: String { "remotedebug://pair?host=\(host)&code=••••" + (authKey == nil ? "" : "&key=••••") }
    public var debugDescription: String { description }
}
