import Foundation
import RDModels
import Testing
@testable import MacHostKit

@MainActor
final class FakeAdvertiser: DirectAdvertising {
    private(set) var current: (id: String, port: Int)?
    private(set) var advertiseCount = 0
    private(set) var stopCount = 0

    func advertise(id: String, port: Int) {
        if let current, current.id == id, current.port == port { return }
        current = (id, port)
        advertiseCount += 1
    }

    func stop() {
        if current != nil { stopCount += 1 }
        current = nil
    }
}

/// 같은 네트워크 직접 연결(docs/protocol-addenda.md O)의 Mac 쪽: 스위치, Bonjour 광고, 토큰 해시 저장.
@MainActor
@Suite("직접 연결")
struct DirectTests {
    struct Harness {
        let tmp: TempDir
        let core: FakeHostCore
        let model: HostModel
        let paths: HostPaths
        let advertiser: FakeAdvertiser
    }

    func makeHarness(_ label: String, devices: [DeviceEntry] = []) throws -> Harness {
        let tmp = try TempDir(label)
        let paths = HostPaths(root: tmp.path("host"))
        try paths.prepare()
        if !devices.isEmpty { try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: devices)) }
        let core = FakeHostCore()
        let advertiser = FakeAdvertiser()
        let model = HostModel(core: core, paths: paths, inspector: FakeInspector(), packager: FakePackager(), bookmarks: FakeBookmarks(),
                              watcherOptions: .init(useFileEvents: false), id8: "ab12cd34", hostDisplayName: "작업용 Mac", appVersion: "0.1.0",
                              tailscaleAPI: TailscaleAPI { _ in throw URLError(.notConnectedToInternet) },
                              tailscaleClients: MemoryTailscaleClientStore(), advertiser: advertiser)
        return Harness(tmp: tmp, core: core, model: model, paths: paths, advertiser: advertiser)
    }

    private func listening(_ core: FakeHostCore) {
        core.state.withLock { $0.status.direct = DirectStatus(listening: true, port: 49152, id: "0123456789abcdef") }
    }

    private func savedDevices(_ paths: HostPaths) throws -> [DeviceEntry] {
        try RDJSON.decoder().decode(DeviceList.self, from: Data(contentsOf: paths.devicesFile)).devices
    }

    // MARK: 설정

    @Test func settingDefaultsToOnAndIsSavedPerStateRoot() {
        let defaults = InMemoryDefaults()
        let fresh = LaunchOptions(defaults: defaults, environment: [:], arguments: [:])
        #expect(fresh.directListen, "저장한 적이 없으면 켠다")
        #expect(fresh.savedDirectListenKey == LaunchOptions.directListenKey)

        defaults.set(false, forKey: fresh.savedDirectListenKey)
        #expect(!LaunchOptions(defaults: defaults, environment: [:], arguments: [:]).directListen)

        // 다른 저장 폴더는 기본 폴더의 스위치를 읽지 않는다.
        defaults.set("RemoteDebug-smoke-2", forKey: LaunchOptions.stateRootNameKey)
        let smoke = LaunchOptions(defaults: defaults, environment: [:], arguments: [:])
        #expect(smoke.directListen)
        #expect(smoke.savedDirectListenKey != LaunchOptions.directListenKey)
    }

    @Test func startConfigCarriesTheSwitch() async throws {
        let off = try makeHarness("direct-off")
        await off.model.start()
        #expect(off.core.startConfigs.first?.directListen == false)
        #expect(off.advertiser.current == nil)

        let on = try makeHarness("direct-on")
        on.model.directEnabled = true
        listening(on.core)
        await on.model.start()
        #expect(on.core.startConfigs.first?.directListen == true)
        // 리스너가 열린 뒤에만, 무작위 식별자와 포트로 광고한다.
        #expect(on.advertiser.current?.id == "0123456789abcdef")
        #expect(on.advertiser.current?.port == 49152)
    }

    @Test func switchingOffStopsTheListenerAndTheAdvertisement() async throws {
        let h = try makeHarness("direct-toggle")
        h.model.directEnabled = true
        listening(h.core)
        await h.model.start()
        #expect(h.advertiser.current != nil)

        await h.model.setDirectEnabled(false)
        #expect(!h.model.directEnabled)
        #expect(h.core.calls.contains(.setDirect(false)))
        #expect(h.advertiser.current == nil)
        #expect(h.model.status?.direct?.listening == false)

        await h.model.setDirectEnabled(true)
        #expect(h.core.calls.contains(.setDirect(true)))
        #expect(h.advertiser.current?.port == 49152)

        // 공유를 멈추면 광고도 멈춘다.
        await h.model.stop()
        #expect(h.advertiser.current == nil)
    }

    @Test func switchBeforeSharingOnlyRemembersTheChoice() async throws {
        let h = try makeHarness("direct-idle")
        await h.model.setDirectEnabled(true)
        #expect(h.model.directEnabled)
        #expect(!h.core.calls.contains(.setDirect(true)))
        #expect(h.advertiser.current == nil)
    }

    @Test func listenerFailureIsReportedAndNothingIsAdvertised() async throws {
        let h = try makeHarness("direct-fail")
        await h.model.start()
        h.core.state.withLock { $0.failSetDirect = true }
        await h.model.setDirectEnabled(true)
        #expect(h.model.lastError?.contains("직접 연결") == true)
        #expect(h.advertiser.current == nil)
    }

    @Test func advertisedRecordCarriesOnlyTheVersion() {
        #expect(BonjourAdvertiser.serviceType == "_remotedebug._tcp.")
        #expect(BonjourAdvertiser.txtRecord == ["v": Data("1".utf8)])
    }

    // MARK: 토큰 해시 저장

    @Test func enrolledHashIsSavedAndPushedOnTheNextStart() async throws {
        let h = try makeHarness("direct-hash", devices: [sampleDevice(1), sampleDevice(2)])
        await h.model.start()
        var enrolled = sampleDevice(1)
        enrolled.directTokenHash = String(repeating: "ab", count: 32)
        let activity = h.model.activity.count
        h.model.handle(.deviceUpdated(enrolled))

        #expect(h.model.devices.first?.directTokenHash == enrolled.directTokenHash)
        #expect(h.model.devices.first?.isDirectEnrolled == true)
        #expect(h.model.devices.last?.isDirectEnrolled == false)
        #expect(h.model.activity.count == activity, "등록은 활동 기록에 남기지 않는다")
        #expect(try savedDevices(h.paths).first?.directTokenHash == enrolled.directTokenHash)

        // 다시 시작하면 해시를 코어에 그대로 넣는다(iPhone이 다시 등록하지 않아도 된다).
        await h.model.stop()
        let again = HostModel(core: h.core, paths: h.paths, inspector: FakeInspector(), packager: FakePackager(), bookmarks: FakeBookmarks(),
                              watcherOptions: .init(useFileEvents: false), id8: "ab12cd34",
                              tailscaleAPI: TailscaleAPI { _ in throw URLError(.notConnectedToInternet) },
                              tailscaleClients: MemoryTailscaleClientStore())
        await again.start()
        #expect(h.core.setDevicesCalls.last?.first?.directTokenHash == enrolled.directTokenHash)
    }

    @Test func updateForARemovedDeviceIsIgnored() async throws {
        let h = try makeHarness("direct-removed", devices: [sampleDevice(1)])
        await h.model.start()
        await h.model.removeDevice("d_1")
        #expect(h.core.setDevicesCalls.last == [], "지운 기기는 코어의 허용 목록에서 빠진다(직접 연결 토큰도 함께 무효)")
        var late = sampleDevice(1)
        late.directTokenHash = String(repeating: "cd", count: 32)
        h.model.handle(.deviceUpdated(late))
        #expect(h.model.devices.isEmpty)
        #expect(try savedDevices(h.paths).isEmpty)
    }

    @Test func removingADeviceKeepsOtherDevicesHashes() async throws {
        var one = sampleDevice(1)
        one.directTokenHash = String(repeating: "11", count: 32)
        let h = try makeHarness("direct-keep", devices: [one, sampleDevice(2)])
        await h.model.start()
        await h.model.removeDevice("d_2")
        #expect(h.core.setDevicesCalls.last == [one])
    }
}
