import Foundation
import Testing
@testable import RemoteDebug

@Suite struct SharedContainerTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rd-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func 예전_상태를_공용_위치로_한_번_옮긴다() throws {
        let legacy = try temp(), shared = try temp()
        let old = legacy.appendingPathComponent("RemoteDebug/tailscale")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("node-key".utf8).write(to: old.appendingPathComponent("tailscaled.state"))

        #expect(SharedContainer.migrateState(from: legacy, to: shared))
        let moved = shared.appendingPathComponent("RemoteDebug/tailscale/tailscaled.state")
        #expect(try Data(contentsOf: moved) == Data("node-key".utf8))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        // 옮길 것이 없으면 아무것도 하지 않는다.
        #expect(!SharedContainer.migrateState(from: legacy, to: shared))
    }

    @Test func 공용_위치에_상태가_있으면_덮어쓰지_않는다() throws {
        let legacy = try temp(), shared = try temp()
        for (base, text) in [(legacy, "old"), (shared, "current")] {
            let dir = base.appendingPathComponent("RemoteDebug/tailscale")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dir.appendingPathComponent("tailscaled.state"))
        }
        #expect(!SharedContainer.migrateState(from: legacy, to: shared))
        #expect(try Data(contentsOf: shared.appendingPathComponent("RemoteDebug/tailscale/tailscaled.state")) == Data("current".utf8))
    }

    @Test func 짝_앱에_보내는_요청을_읽는다() throws {
        let url = try #require(URL(string: "remotedebug-vpn://vpn?action=connect&return=1"))
        let request = try #require(AppPair.request(from: url))
        #expect(request.action == .connect && request.returning)
        let plainURL = try #require(URL(string: "remotedebug://vpn?action=disconnect"))
        let plain = try #require(AppPair.request(from: plainURL))
        #expect(plain.action == .disconnect && !plain.returning)
        // 페어링 링크와 모르는 동작은 VPN 요청이 아니다.
        let pairing = try #require(URL(string: "remotedebug://pair?host=mac.example&code=123456"))
        let unknown = try #require(URL(string: "remotedebug://vpn?action=erase"))
        #expect(AppPair.request(from: pairing) == nil)
        #expect(AppPair.request(from: unknown) == nil)
    }

    @Test func 스토어_앱은_VPN_앱을_짝으로_본다() throws {
        // 시험은 스토어 앱 안에서 돈다.
        #expect(AppPair.currentAppID.hasSuffix(AppPair.storeSuffix))
        #expect(AppPair.otherAppID.hasSuffix(AppPair.vpnSuffix))
        #expect(AppPair.url(toOther: .connect, returning: true)?.absoluteString == "remotedebug-vpn://vpn?action=connect&return=1")
    }

    @Test func tailnet_주소_범위를_가린다() {
        #expect(TailnetInterface.isTailnet(0x6440_0001))   // 100.64.0.1
        #expect(TailnetInterface.isTailnet(0x647F_FFFE))   // 100.127.255.254
        #expect(!TailnetInterface.isTailnet(0x6480_0001))  // 100.128.0.1
        #expect(!TailnetInterface.isTailnet(0xC0A8_0001))  // 192.168.0.1
    }

    @Test func VPN_상태를_공용_설정에_적고_읽는다() throws {
        let defaults = try #require(UserDefaults(suiteName: "rd-test-\(UUID().uuidString)"))
        #expect(SharedVPNState.read(defaults) == nil)
        let state = SharedVPNState(owner: "com.example.RemoteDebugVPN", connected: true, updatedAt: Date(timeIntervalSince1970: 1_794_478_500))
        state.write(defaults)
        #expect(SharedVPNState.read(defaults) == state)
    }

    @Test @MainActor func 예전_터널_설정을_공용_설정으로_한_번_옮긴다() throws {
        let legacy = try #require(UserDefaults(suiteName: "rd-legacy-\(UUID().uuidString)"))
        let shared = try #require(UserDefaults(suiteName: "rd-shared-\(UUID().uuidString)"))
        legacy.set("abc123", forKey: TunnelSettingsStore.nodeIDKey)
        #expect(TunnelSettingsStore(defaults: shared, legacy: legacy).nodeID == "abc123")
        // 한 번 옮긴 뒤에는 예전 값이 바뀌어도 공용 값을 쓴다.
        legacy.set("changed", forKey: TunnelSettingsStore.nodeIDKey)
        #expect(TunnelSettingsStore(defaults: shared, legacy: legacy).nodeID == "abc123")
    }
}
