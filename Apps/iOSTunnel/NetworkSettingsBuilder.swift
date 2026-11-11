import NetworkExtension

/// `TunnelSettingsPlan`을 NE 타입으로 옮기는 얇은 코드. 판단은 `SettingsTranslator`가 한다.
enum NetworkSettingsBuilder {
    static func make(_ plan: TunnelSettingsPlan) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: plan.tunnelRemoteAddress)
        settings.mtu = NSNumber(value: plan.mtu)
        if let v4 = plan.ipv4 {
            let ipv4 = NEIPv4Settings(addresses: v4.addresses, subnetMasks: v4.subnetMasks)
            ipv4.includedRoutes = v4.routes.map { NEIPv4Route(destinationAddress: $0.destination, subnetMask: $0.subnetMask) }
            settings.ipv4Settings = ipv4
        }
        if let v6 = plan.ipv6 {
            let ipv6 = NEIPv6Settings(addresses: v6.addresses, networkPrefixLengths: v6.prefixLengths.map { NSNumber(value: $0) })
            ipv6.includedRoutes = v6.routes.map { NEIPv6Route(destinationAddress: $0.destination, networkPrefixLength: NSNumber(value: $0.prefixLength)) }
            settings.ipv6Settings = ipv6
        }
        if let dns = plan.dns {
            let dnsSettings = NEDNSSettings(servers: dns.servers)
            dnsSettings.matchDomains = dns.matchDomains
            dnsSettings.matchDomainsNoSearch = true
            settings.dnsSettings = dnsSettings
        } else {
            settings.dnsSettings = nil
        }
        // 프록시 설정은 쓰지 않는다(TN3120).
        settings.proxySettings = nil
        return settings
    }
}
