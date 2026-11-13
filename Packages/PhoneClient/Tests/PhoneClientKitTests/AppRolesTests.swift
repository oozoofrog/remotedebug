import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

@Suite struct AppRolesTests {
    private let store = "com.example.RemoteDebugPhone"
    private let updater = "com.example.RemoteDebugVPN"

    private func build(_ id: String, _ bundleID: String, _ published: TimeInterval) throws -> BuildDescriptor {
        var build = try Examples.buildDescriptor()
        build.id = id
        build.bundleId = bundleID
        build.publishedAt = Date(timeIntervalSince1970: 1_800_000_000 + published)
        return build
    }

    @Test func RemoteDebug_앱은_자기_빌드를_숨긴다() throws {
        let builds = [try build("s1", store, 10), try build("a1", "com.example.other", 20), try build("u1", updater, 30), try build("s2", store, 40)]
        #expect(AppBuildFilter.hiding(store, in: builds).map(\.id) == ["a1", "u1"])
        // 번들 ID를 모르면 아무것도 숨기지 않는다.
        #expect(AppBuildFilter.hiding(nil, in: builds).count == 4)
        #expect(AppBuildFilter.hiding("", in: builds).count == 4)
    }

    @Test func 업데이트_앱은_RemoteDebug_빌드만_최신부터_보여_준다() throws {
        let builds = [try build("s1", store, 10), try build("a1", "com.example.other", 20), try build("u1", updater, 30), try build("s2", store, 40)]
        #expect(AppBuildFilter.only(store, in: builds).map(\.id) == ["s2", "s1"])
        #expect(AppBuildFilter.only(store, in: [try build("u1", updater, 30)]).isEmpty)
        #expect(AppBuildFilter.only("", in: builds).isEmpty)
    }

    @Test func RemoteDebug_앱은_업데이트_앱이_VPN을_켠_동안에만_넘겨받고_설치한다() {
        func takes(_ bundleID: String, _ holder: VPNHolder) -> Bool {
            InstallVPNGuard.takesOverFirst(role: .store, installing: bundleID, pairedAppID: updater, holder: holder)
        }
        #expect(takes(updater, .pairedApp))
        #expect(!takes(updater, .thisApp))
        #expect(!takes(updater, .other))
        #expect(!takes(updater, .none))
        // 다른 앱의 설치는 VPN을 건드리지 않는다.
        #expect(!takes("com.example.other", .pairedApp))
    }

    @Test func 업데이트_앱은_자기_터널이_아니면_넘겨받고_설치한다() {
        func takes(_ bundleID: String, _ holder: VPNHolder) -> Bool {
            InstallVPNGuard.takesOverFirst(role: .updater, installing: bundleID, pairedAppID: store, holder: holder)
        }
        #expect(takes(store, .pairedApp))
        #expect(takes(store, .other))
        #expect(takes(store, .none))
        #expect(!takes(store, .thisApp))
        #expect(!takes("com.example.other", .pairedApp))
        // 짝 앱의 번들 ID를 모르면 넘겨받지 않는다.
        #expect(!InstallVPNGuard.takesOverFirst(role: .updater, installing: "", pairedAppID: "", holder: .pairedApp))
    }

    @Test @MainActor func 페어링한_Mac을_공용_설정으로_한_번_옮긴다() throws {
        let legacyName = "rd-legacy-\(UUID().uuidString)", sharedName = "rd-shared-\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        let shared = try #require(UserDefaults(suiteName: sharedName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            shared.removePersistentDomain(forName: sharedName)
        }
        let first = PairedHost(hostId: "h_1", hostName: "Mac 1", fqdn: "rd-mac-1a2b3c4d.tail0001.ts.net", pairedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try UserDefaultsPairedHostStore(defaults: legacy).save(first)

        // RemoteDebug 앱이 열리면 예전 값이 공용 설정으로 간다.
        #expect(UserDefaultsPairedHostStore(defaults: shared, legacy: legacy).load() == first)
        // 업데이트 앱은 예전 저장소 없이 같은 값을 읽는다.
        #expect(UserDefaultsPairedHostStore(defaults: shared).load() == first)

        // 한 번 옮긴 뒤에는 예전 값이 바뀌어도, 공용 값을 지워도 다시 옮기지 않는다.
        let second = PairedHost(hostId: "h_2", hostName: "Mac 2", fqdn: "rd-mac-5e6f7a8b.tail0001.ts.net", pairedAt: Date(timeIntervalSince1970: 1_800_000_600))
        try UserDefaultsPairedHostStore(defaults: legacy).save(second)
        #expect(UserDefaultsPairedHostStore(defaults: shared, legacy: legacy).load() == first)
        UserDefaultsPairedHostStore(defaults: shared).clear()
        #expect(UserDefaultsPairedHostStore(defaults: shared, legacy: legacy).load() == nil)
    }

    @Test @MainActor func 공용_설정에_이미_있는_Mac은_예전_값으로_덮지_않는다() throws {
        let legacyName = "rd-legacy-\(UUID().uuidString)", sharedName = "rd-shared-\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        let shared = try #require(UserDefaults(suiteName: sharedName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            shared.removePersistentDomain(forName: sharedName)
        }
        let old = PairedHost(hostId: "h_old", hostName: "Mac", fqdn: "rd-mac-1a2b3c4d.tail0001.ts.net", pairedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let current = PairedHost(hostId: "h_new", hostName: "Mac", fqdn: "rd-mac-5e6f7a8b.tail0001.ts.net", pairedAt: Date(timeIntervalSince1970: 1_800_000_600))
        try UserDefaultsPairedHostStore(defaults: legacy).save(old)
        try UserDefaultsPairedHostStore(defaults: shared).save(current)
        #expect(UserDefaultsPairedHostStore(defaults: shared, legacy: legacy).load() == current)
    }

    @Test @MainActor func 같은_저장소면_옮기지_않는다() throws {
        let name = "rd-same-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        _ = UserDefaultsPairedHostStore(defaults: defaults, legacy: defaults)
        #expect(!defaults.bool(forKey: UserDefaultsPairedHostStore.migratedKey))
    }

    @Test func VPN이_꺼져_있고_자동으로_켤_수_없으면_설치_전에_이_앱의_VPN을_켠다() {
        #expect(InstallVPNGuard.connectsOwnFirst(state: .off, holder: .none, configuration: .missing))
        #expect(InstallVPNGuard.connectsOwnFirst(state: .off, holder: .none, configuration: .disabled))
        // 자동으로 켤 수 있으면 모델이 켠다.
        #expect(!InstallVPNGuard.connectsOwnFirst(state: .off, holder: .none, configuration: .ready))
        // 다른 VPN이 켜져 있거나 이미 연결돼 있으면 건드리지 않는다.
        #expect(!InstallVPNGuard.connectsOwnFirst(state: .off, holder: .other, configuration: .missing))
        #expect(!InstallVPNGuard.connectsOwnFirst(state: .connected, holder: .none, configuration: .missing))
        #expect(!InstallVPNGuard.connectsOwnFirst(state: .needsLogin(authURL: nil), holder: .none, configuration: .missing))
        // 실패로 멈춘 VPN은 구성이 준비돼 있어도 설치 요청으로 다시 켠다.
        #expect(InstallVPNGuard.connectsOwnFirst(state: .failed(message: "끊김"), holder: .none, configuration: .ready))
        #expect(!InstallVPNGuard.connectsOwnFirst(state: .failed(message: "끊김"), holder: .other, configuration: .ready))
    }
}
