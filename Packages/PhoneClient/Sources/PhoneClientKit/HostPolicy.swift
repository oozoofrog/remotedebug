import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 페어링할 수 있는 호스트 주소의 정책.
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
