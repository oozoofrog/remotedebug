import Foundation
import Network
import RDHostLogic

/// 같은 네트워크 직접 연결 리스너(docs/protocol-addenda.md O). Go `core/internal/direct`의 `Listen`과 `filtered`를 옮겼다.
///
/// 저장한 포트에서 듣고, 묶지 못하면 새 포트를 골라 저장한다. TLS 1.3이고, 사설(RFC 1918, IPv6 고유 로컬)·링크 로컬
/// 상대만 받는다. 거르는 것은 TLS 바이트를 주고받기 전이다. 요청은 `HostOrigin.direct(remoteIP:)`로 같은 로직에 간다.
public enum DirectListener {
    /// 받을 상대인가. CGNAT(100.64.0.0/10)과 Tailscale의 IPv6 대역(fd7a:115c:a1e0::/48)은 tailnet 상대이므로 받지 않는다.
    public static func isLANAddress(_ text: String) -> Bool {
        let host = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            return isLANv4(bytes)
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        // IPv4 대응 주소는 IPv4로 본다(Go `Unmap`).
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return isLANv4(Array(bytes[12...])) }
        if bytes.prefix(6) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] { return false }
        // fc00::/7(고유 로컬), fe80::/10(링크 로컬 유니캐스트).
        return bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
    }

    static func isLANv4(_ bytes: [UInt8]) -> Bool {
        switch (bytes[0], bytes[1]) {
        case (10, _), (192, 168), (169, 254): true
        case (172, 16...31): true
        default: false
        }
    }

    /// 듣기 시작한다. 저장한 포트를 먼저 쓰고, 안 되면 시스템이 고른 포트를 저장한다.
    ///
    /// - Parameters:
    ///   - loopbackOnly: 시험 전용. `127.0.0.1`에 묶고 그 상대를 받는다(Go `direct.Options.Host`·`Allow`).
    public static func start(identity: DirectIdentity, handler: any HostRequestHandling, limits: HTTPServerLimits = HTTPServerLimits(),
                             loopbackOnly: Bool = false,
                             events: @escaping @Sendable (HTTPListener.Event) -> Void = { _ in }) async throws -> HTTPListener {
        let security = HTTPListener.Security.tls(try identity.tlsIdentity())
        let admission: HTTPListener.Admission = loopbackOnly ? .loopback : .direct(allow: isLANAddress)
        func binding(_ port: UInt16) -> HTTPListener.Binding {
            loopbackOnly ? .loopback(port: port) : .anyInterface(port: port)
        }
        let saved = identity.port
        if saved > 0, saved <= 65_535,
           let listener = try? await HTTPListener.start(binding: binding(UInt16(saved)), security: security, admission: admission,
                                                        handler: handler, limits: limits, events: events) {
            return listener
        }
        let listener = try await HTTPListener.start(binding: binding(0), security: security, admission: admission, handler: handler,
                                                    limits: limits, events: events)
        do {
            try identity.setPort(Int(listener.port))
        } catch {
            listener.close()
            throw error
        }
        return listener
    }
}
