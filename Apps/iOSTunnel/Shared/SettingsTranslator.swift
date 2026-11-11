import Foundation
import RDModels

#if canImport(Darwin)
import Darwin
#endif

/// `NEPacketTunnelNetworkSettings`로 옮기기 전의 설정(NE 타입 없음). docs/tunnel.md "터널 확장(Swift)의 책임" 2.
struct TunnelSettingsPlan: Equatable, Sendable {
    struct IPv4: Equatable, Sendable {
        var addresses: [String]
        var subnetMasks: [String]
        var routes: [Route]

        struct Route: Equatable, Sendable {
            var destination: String
            var subnetMask: String
        }
    }

    struct IPv6: Equatable, Sendable {
        var addresses: [String]
        var prefixLengths: [Int]
        var routes: [Route]

        struct Route: Equatable, Sendable {
            var destination: String
            var prefixLength: Int
        }
    }

    /// `matchDomainsNoSearch`는 늘 `true`다.
    struct DNS: Equatable, Sendable {
        var servers: [String]
        var matchDomains: [String]
    }

    var tunnelRemoteAddress: String
    var ipv4: IPv4?
    var ipv6: IPv6?
    var dns: DNS?
    var mtu: Int
}

/// 코어의 `network-settings` 이벤트를 `TunnelSettingsPlan`으로 바꾸는 순수 함수.
enum SettingsTranslator {
    /// NE가 VPN 서버로 보는 주소. 터널로 보내야 하는 주소(100.100.100.100 등)를 쓰지 않는다.
    static let tunnelRemoteAddress = "127.0.0.1"
    static let defaultMTU = 1280
    static let mtuRange = 1280...1420

    /// 첫 `network-settings` 전에 utun을 만들기 위한 자리표시 설정(원격 주소와 mtu만, 경로 없음).
    static func placeholder(mtu: Int = defaultMTU) -> TunnelSettingsPlan {
        TunnelSettingsPlan(tunnelRemoteAddress: tunnelRemoteAddress, ipv4: nil, ipv6: nil, dns: nil, mtu: clampedMTU(mtu))
    }

    static func translate(_ event: NetworkSettingsEvent) -> TunnelSettingsPlan {
        var v4Addresses: [String] = [], v4Masks: [String] = []
        var v6Addresses: [String] = [], v6Prefixes: [Int] = []
        for text in event.addresses {
            switch CIDR(text) {
            case .v4(let address, let prefix)?:
                v4Addresses.append(format(v4: address))
                v4Masks.append(subnetMask(prefixLength: prefix))
            case .v6(let address, let prefix)?:
                v6Addresses.append(format(v6: address))
                v6Prefixes.append(prefix)
            case nil:
                continue
            }
        }
        let hasV4 = !v4Addresses.isEmpty
        let hasV6 = !v6Addresses.isEmpty

        var v4Routes: [TunnelSettingsPlan.IPv4.Route] = []
        var v6Routes: [TunnelSettingsPlan.IPv6.Route] = []
        for text in event.routes {
            switch CIDR(text) {
            case .v4(let address, let prefix)? where hasV4:
                let route = TunnelSettingsPlan.IPv4.Route(destination: format(v4: network(v4: address, prefix: prefix)), subnetMask: subnetMask(prefixLength: prefix))
                if !v4Routes.contains(route) { v4Routes.append(route) }
            case .v6(let address, let prefix)? where hasV6:
                let route = TunnelSettingsPlan.IPv6.Route(destination: format(v6: network(v6: address, prefix: prefix)), prefixLength: prefix)
                if !v6Routes.contains(route) { v6Routes.append(route) }
            default:
                continue
            }
        }

        return TunnelSettingsPlan(
            tunnelRemoteAddress: tunnelRemoteAddress,
            ipv4: hasV4 ? .init(addresses: v4Addresses, subnetMasks: v4Masks, routes: v4Routes) : nil,
            ipv6: hasV6 ? .init(addresses: v6Addresses, prefixLengths: v6Prefixes, routes: v6Routes) : nil,
            dns: dns(servers: event.dnsServers, matchDomains: event.dnsMatchDomains, hasV4: hasV4, hasV6: hasV6),
            mtu: clampedMTU(event.mtu)
        )
    }

    /// 서버가 없거나 일치 도메인이 비면 DNS를 설정하지 않는다(`matchDomains = [""]`를 만들지 않는다).
    static func dns(servers: [String], matchDomains: [String], hasV4: Bool, hasV6: Bool) -> TunnelSettingsPlan.DNS? {
        var kept: [String] = []
        for server in servers {
            let text = server.trimmingCharacters(in: .whitespaces)
            let formatted: String?
            if let v4 = parseV4(text) {
                formatted = hasV4 ? format(v4: v4) : nil
            } else if let v6 = parseV6(text) {
                formatted = hasV6 ? format(v6: v6) : nil
            } else {
                formatted = nil
            }
            if let formatted, !kept.contains(formatted) { kept.append(formatted) }
        }
        guard !kept.isEmpty else { return nil }
        var domains: [String] = []
        for raw in matchDomains {
            var domain = raw.trimmingCharacters(in: .whitespaces)
            while domain.hasSuffix(".") { domain.removeLast() }
            guard !domain.isEmpty, !domains.contains(domain) else { continue }
            domains.append(domain)
        }
        guard !domains.isEmpty else { return nil }
        return .init(servers: kept, matchDomains: domains)
    }

    static func clampedMTU(_ mtu: Int) -> Int {
        mtuRange.contains(mtu) ? mtu : defaultMTU
    }

    // MARK: 주소

    enum CIDR: Equatable {
        case v4([UInt8], Int)
        case v6([UInt8], Int)

        /// `a.b.c.d/n` 또는 `x::y/n`. 접두 길이가 없으면 호스트 경로(/32, /128)로 본다.
        init?(_ text: String) {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else { return nil }
            let addressText = String(parts[0])
            if let v4 = SettingsTranslator.parseV4(addressText) {
                guard let prefix = parts.count == 2 ? Int(parts[1]) : 32, (0...32).contains(prefix) else { return nil }
                self = .v4(v4, prefix)
            } else if let v6 = SettingsTranslator.parseV6(addressText) {
                guard let prefix = parts.count == 2 ? Int(parts[1]) : 128, (0...128).contains(prefix) else { return nil }
                self = .v6(v6, prefix)
            } else {
                return nil
            }
        }
    }

    static func parseV4(_ text: String) -> [UInt8]? {
        guard !text.contains(":") else { return nil }
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    static func parseV6(_ text: String) -> [UInt8]? {
        guard text.contains(":"), !text.contains("%") else { return nil }
        var addr = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    static func format(v4 bytes: [UInt8]) -> String {
        bytes.map(String.init).joined(separator: ".")
    }

    static func format(v6 bytes: [UInt8]) -> String {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// 접두 길이를 점 표기 마스크로(24 → `255.255.255.0`).
    static func subnetMask(prefixLength: Int) -> String {
        format(v4: mask(bytes: 4, prefix: prefixLength))
    }

    static func network(v4 bytes: [UInt8], prefix: Int) -> [UInt8] {
        zip(bytes, mask(bytes: 4, prefix: prefix)).map { $0 & $1 }
    }

    static func network(v6 bytes: [UInt8], prefix: Int) -> [UInt8] {
        zip(bytes, mask(bytes: 16, prefix: prefix)).map { $0 & $1 }
    }

    private static func mask(bytes count: Int, prefix: Int) -> [UInt8] {
        (0..<count).map { index in
            let bits = min(8, max(0, prefix - index * 8))
            return bits == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
        }
    }
}
