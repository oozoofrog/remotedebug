import Foundation
import RDModels
import Testing
@testable import RemoteDebug

@Suite("SettingsTranslator")
struct SettingsTranslatorTests {
    private func event(
        addresses: [String] = ["100.64.0.11/32", "fd7a:115c:a1e0::b/128"],
        routes: [String] = ["100.64.0.10/32", "fd7a:115c:a1e0::/48", "100.100.100.100/32", "fd7a:115c:a1e0::53/128"],
        dnsServers: [String] = ["100.100.100.100", "fd7a:115c:a1e0::53"],
        dnsMatchDomains: [String] = ["example-tailnet.ts.net", "64.100.in-addr.arpa"],
        mtu: Int = 1280
    ) -> NetworkSettingsEvent {
        NetworkSettingsEvent(addresses: addresses, routes: routes, dnsServers: dnsServers, dnsMatchDomains: dnsMatchDomains, mtu: mtu)
    }

    @Test("docs/tunnel.md 예시: 두 패밀리, 경로, DNS, mtu")
    func documentedExample() {
        let plan = SettingsTranslator.translate(event())
        #expect(plan.tunnelRemoteAddress == "127.0.0.1")
        #expect(plan.ipv4 == .init(
            addresses: ["100.64.0.11"],
            subnetMasks: ["255.255.255.255"],
            routes: [
                .init(destination: "100.64.0.10", subnetMask: "255.255.255.255"),
                .init(destination: "100.100.100.100", subnetMask: "255.255.255.255"),
            ]
        ))
        #expect(plan.ipv6 == .init(
            addresses: ["fd7a:115c:a1e0::b"],
            prefixLengths: [128],
            routes: [
                .init(destination: "fd7a:115c:a1e0::", prefixLength: 48),
                .init(destination: "fd7a:115c:a1e0::53", prefixLength: 128),
            ]
        ))
        #expect(plan.dns == .init(servers: ["100.100.100.100", "fd7a:115c:a1e0::53"], matchDomains: ["example-tailnet.ts.net", "64.100.in-addr.arpa"]))
        #expect(plan.mtu == 1280)
    }

    @Test("접두 길이 → 점 표기 마스크", arguments: [
        (0, "0.0.0.0"), (8, "255.0.0.0"), (10, "255.192.0.0"), (24, "255.255.255.0"), (31, "255.255.255.254"), (32, "255.255.255.255"),
    ])
    func subnetMask(prefix: Int, mask: String) {
        #expect(SettingsTranslator.subnetMask(prefixLength: prefix) == mask)
    }

    @Test("경로 목적지는 네트워크 주소로 맞춘다(OneCGNAT 100.64.0.0/10 포함)")
    func routeNetworkAddress() {
        let plan = SettingsTranslator.translate(event(routes: ["100.64.0.0/10", "100.101.102.103/24", "fd7a:115c:a1e0:ab12::1/48"]))
        #expect(plan.ipv4?.routes == [
            .init(destination: "100.64.0.0", subnetMask: "255.192.0.0"),
            .init(destination: "100.101.102.0", subnetMask: "255.255.255.0"),
        ])
        #expect(plan.ipv6?.routes == [.init(destination: "fd7a:115c:a1e0::", prefixLength: 48)])
    }

    @Test("IPv4 주소만 있으면 IPv6 설정·경로·DNS 서버를 만들지 않는다")
    func ipv4Only() {
        let plan = SettingsTranslator.translate(event(addresses: ["100.64.0.11/32"]))
        #expect(plan.ipv4 != nil)
        #expect(plan.ipv6 == nil)
        #expect(plan.dns?.servers == ["100.100.100.100"])
    }

    @Test("IPv6 주소만 있으면 IPv4 설정·경로·DNS 서버를 만들지 않는다")
    func ipv6Only() {
        let plan = SettingsTranslator.translate(event(addresses: ["fd7a:115c:a1e0::b/128"]))
        #expect(plan.ipv4 == nil)
        #expect(plan.ipv6?.routes.count == 2)
        #expect(plan.dns?.servers == ["fd7a:115c:a1e0::53"])
    }

    @Test("DNS 서버가 비면 DNS 설정 없음")
    func noDNSServers() {
        #expect(SettingsTranslator.translate(event(dnsServers: [])).dns == nil)
    }

    @Test("일치 도메인이 비면(빈 문자열·점만 포함) DNS 설정 없음 — matchDomains [\"\"] 금지")
    func emptyMatchDomains() {
        #expect(SettingsTranslator.translate(event(dnsMatchDomains: [])).dns == nil)
        #expect(SettingsTranslator.translate(event(dnsMatchDomains: ["", "."])).dns == nil)
    }

    @Test("일치 도메인의 끝 점을 지우고 중복을 뺀다")
    func matchDomainNormalization() {
        let plan = SettingsTranslator.translate(event(dnsMatchDomains: ["example-tailnet.ts.net.", "example-tailnet.ts.net", "64.100.in-addr.arpa"]))
        #expect(plan.dns?.matchDomains == ["example-tailnet.ts.net", "64.100.in-addr.arpa"])
        #expect(plan.dns?.matchDomains.contains("") == false)
    }

    @Test("서버 패밀리에 주소가 없으면 DNS 설정 없음")
    func dnsServerFamilyWithoutAddress() {
        let plan = SettingsTranslator.translate(event(addresses: ["100.64.0.11/32"], dnsServers: ["fd7a:115c:a1e0::53"]))
        #expect(plan.dns == nil)
    }

    @Test("mtu는 1280...1420만 쓰고 밖이면 1280", arguments: [(1280, 1280), (1420, 1420), (1421, 1280), (1350, 1350), (0, 1280), (-1, 1280), (1500, 1280), (1279, 1280)])
    func mtu(input: Int, expected: Int) {
        #expect(SettingsTranslator.translate(event(mtu: input)).mtu == expected)
    }

    @Test("잘못된 CIDR은 건너뛴다")
    func invalidEntries() {
        let plan = SettingsTranslator.translate(event(
            addresses: ["100.64.0.11/32", "nonsense", "100.64.0.300/32", "100.64.0.12/33"],
            routes: ["100.64.0.10/32", "1.2.3/24", "fe80::1%en0/64"]
        ))
        #expect(plan.ipv4?.addresses == ["100.64.0.11"])
        #expect(plan.ipv4?.routes == [.init(destination: "100.64.0.10", subnetMask: "255.255.255.255")])
    }

    @Test("마스크를 적용한 뒤 같은 경로는 하나만 남긴다(IPv4·IPv6)")
    func routeDeduplication() {
        let plan = SettingsTranslator.translate(event(routes: [
            "100.64.0.10/24", "100.64.0.99/24", "100.64.0.10/32", "100.64.0.10/32",
            "fd7a:115c:a1e0::1/48", "fd7a:115c:a1e0:ffff::2/48", "fd7a:115c:a1e0::53/128",
        ]))
        #expect(plan.ipv4?.routes == [
            .init(destination: "100.64.0.0", subnetMask: "255.255.255.0"),
            .init(destination: "100.64.0.10", subnetMask: "255.255.255.255"),
        ])
        #expect(plan.ipv6?.routes == [
            .init(destination: "fd7a:115c:a1e0::", prefixLength: 48),
            .init(destination: "fd7a:115c:a1e0::53", prefixLength: 128),
        ])
    }

    @Test("섞인 순서의 입력은 패밀리별로 들어온 순서를 지킨다")
    func mixedFamilyOrder() {
        let plan = SettingsTranslator.translate(event(routes: [
            "fd7a:115c:a1e0::53/128", "100.100.100.100/32", "fd7a:115c:a1e0::/48", "100.64.0.10/32",
        ]))
        #expect(plan.ipv4?.routes.map(\.destination) == ["100.100.100.100", "100.64.0.10"])
        #expect(plan.ipv6?.routes.map(\.destination) == ["fd7a:115c:a1e0::53", "fd7a:115c:a1e0::"])
    }

    @Test("DNS 서버는 같은 주소를 한 번만(표기가 달라도) 쓴다")
    func dnsServerDeduplication() {
        let plan = SettingsTranslator.translate(event(dnsServers: [
            "100.100.100.100", " 100.100.100.100 ", "fd7a:115c:a1e0::53", "fd7a:115c:a1e0:0:0:0:0:53",
        ]))
        #expect(plan.dns?.servers == ["100.100.100.100", "fd7a:115c:a1e0::53"])
    }

    @Test("IPv6 주소가 있어도 범위 지정(%) 주소·경로·DNS 서버는 버린다")
    func scopedIPv6Rejected() {
        let plan = SettingsTranslator.translate(event(
            addresses: ["100.64.0.11/32", "fd7a:115c:a1e0::b/128", "fe80::1%en0/64"],
            routes: ["fe80::1%en0/64", "fd7a:115c:a1e0::/48"],
            dnsServers: ["fe80::53%en0", "fd7a:115c:a1e0::53"]
        ))
        #expect(plan.ipv6?.addresses == ["fd7a:115c:a1e0::b"])
        #expect(plan.ipv6?.routes == [.init(destination: "fd7a:115c:a1e0::", prefixLength: 48)])
        #expect(plan.dns?.servers == ["fd7a:115c:a1e0::53"])
    }

    @Test("IPv6 주소가 있을 때 잘못된 IPv6 CIDR은 파서가 거른다", arguments: [
        "fd7a:115c:a1e0::/129", "fd7a:115c:a1e0::/-1", "fd7a:115c:a1e0::zz/64", "fd7a::1::2/64", "fd7a:115c:a1e0::/48/1", "fd7a:115c:a1e0::/",
    ])
    func invalidIPv6Route(route: String) {
        #expect(SettingsTranslator.CIDR(route) == nil)
        let plan = SettingsTranslator.translate(event(routes: [route, "fd7a:115c:a1e0::53/128"]))
        // 패밀리가 있으므로 걸러진 이유는 패밀리가 아니라 형식이다.
        #expect(plan.ipv6?.routes == [.init(destination: "fd7a:115c:a1e0::53", prefixLength: 128)])
    }

    @Test("주소가 없으면 경로·DNS도 없다")
    func noAddresses() {
        let plan = SettingsTranslator.translate(event(addresses: []))
        #expect(plan.ipv4 == nil && plan.ipv6 == nil && plan.dns == nil)
    }

    @Test("자리표시 설정: 원격 주소와 mtu만")
    func placeholder() {
        let plan = SettingsTranslator.placeholder()
        #expect(plan == TunnelSettingsPlan(tunnelRemoteAddress: "127.0.0.1", ipv4: nil, ipv6: nil, dns: nil, mtu: 1280))
    }
}

@Suite("SerialApplier")
struct SerialApplierTests {
    /// 적용 완료를 손으로 부르는 가짜.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _applied: [Int] = []
        private var _done: [@Sendable () -> Void] = []

        var applied: [Int] { lock.withLock { _applied } }

        func record(_ value: Int, _ done: @escaping @Sendable () -> Void) {
            lock.withLock {
                _applied.append(value)
                _done.append(done)
            }
        }

        func finishNext() {
            let done = lock.withLock { _done.isEmpty ? nil : _done.removeFirst() }
            done?()
        }
    }

    @Test("하나만 진행하고 진행 중에 온 값은 최신 하나만 적용한다")
    func latestPendingWins() {
        let recorder = Recorder()
        let applier = SerialApplier<Int> { value, done in recorder.record(value, done) }
        applier.submit(1)
        applier.submit(2)
        applier.submit(3)
        #expect(recorder.applied == [1])
        recorder.finishNext()
        #expect(recorder.applied == [1, 3])
        #expect(applier.isApplying)
        recorder.finishNext()
        #expect(!applier.isApplying)
        applier.submit(4)
        #expect(recorder.applied == [1, 3, 4])
    }

    @Test("대기분을 버리면 진행 중인 것만 끝난다")
    func discardPending() {
        let recorder = Recorder()
        let applier = SerialApplier<Int> { value, done in recorder.record(value, done) }
        applier.submit(1)
        applier.submit(2)
        applier.discardPending()
        recorder.finishNext()
        #expect(recorder.applied == [1])
        #expect(!applier.isApplying)
    }
}

