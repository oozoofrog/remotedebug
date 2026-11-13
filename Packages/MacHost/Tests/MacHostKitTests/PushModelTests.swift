import CryptoKit
import Foundation
import RDModels
import Testing
@testable import MacHostKit

let otherTestToken = String(repeating: "abcd0123", count: 8)

func pushDevice(_ n: Int, token: String?, environment: String = "development") -> DeviceEntry {
    var d = sampleDevice(n)
    if let token { d.push = PushRegistration(token: token, bundleId: "com.oozoofrog.app.RemoteDebugPhone", environment: environment) }
    return d
}

/// 알림 조정자: 가짜 전송, 메모리 키 보관, 주입한 지연.
@MainActor
@Suite("iPhone 알림 조정자")
struct PushModelTests {
    struct Harness {
        let tmp: TempDir
        let core: FakeHostCore
        let model: HostModel
        let paths: HostPaths
        let push: PushModel
        let transport: FakeAPNsTransport
        let keys: MemoryAPNsKeyStore
    }

    func makeHarness(_ label: String, devices: [DeviceEntry], withKey: Bool = true, transport: FakeAPNsTransport = FakeAPNsTransport(),
                     sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) throws -> Harness {
        let tmp = try TempDir(label)
        let paths = HostPaths(root: tmp.path("host"))
        try paths.prepare()
        if !devices.isEmpty { try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: devices)) }
        let core = FakeHostCore()
        let model = HostModel(core: core, paths: paths, inspector: FakeInspector(), packager: FakePackager(), bookmarks: FakeBookmarks(),
                              watcherOptions: .init(useFileEvents: false), id8: "ab12cd34", hostDisplayName: "작업용 Mac", appVersion: "0.1.0",
                              tailscaleAPI: TailscaleAPI { _ in throw URLError(.notConnectedToInternet) },
                              tailscaleClients: MemoryTailscaleClientStore(), feedbackKeys: MemoryFeedbackKeyStore())
        let defaults = InMemoryDefaults()
        let keys = MemoryAPNsKeyStore()
        if withKey {
            try keys.save(P256.Signing.PrivateKey().pemRepresentation)
            defaults.set("KEY0000001", forKey: "RDAPNsKeyID")
            defaults.set("TEAM000001", forKey: "RDAPNsTeamID")
        }
        let push = PushModel(host: model, keys: keys, defaults: defaults, transport: transport, sleep: sleep)
        model.onLibraryChanged = { [weak push] builds, files in push?.libraryChanged(builds: builds, resources: files) }
        return Harness(tmp: tmp, core: core, model: model, paths: paths, push: push, transport: transport, keys: keys)
    }

    func library(_ ids: [String]) -> [LibraryBuild] {
        ids.map { LibraryBuild(descriptor: pushBuild($0), sourcePath: "") }
    }

    /// 기준선을 잡은 뒤 새 빌드 하나를 알린다.
    func publishNewBuild(_ h: Harness) async {
        h.push.libraryChanged(builds: library(["b_1"]), resources: [])
        h.push.libraryChanged(builds: library(["b_2", "b_1"]), resources: [])
        await h.push.waitForDelivery()
    }

    func savedDevices(_ paths: HostPaths) throws -> [DeviceEntry] {
        try RDJSON.decoder().decode(DeviceList.self, from: Data(contentsOf: paths.devicesFile)).devices
    }

    @Test func withoutAKeyNothingIsSent() async throws {
        let h = try makeHarness("push-nokey", devices: [pushDevice(1, token: testToken)], withKey: false)
        await h.model.start()
        #expect(!h.push.isConfigured)
        await publishNewBuild(h)
        #expect(h.transport.requests.isEmpty)
        #expect(h.push.testUnavailableReason != nil)
        await h.model.shutdown()
    }

    @Test func sendsToEachRegisteredDeviceOnly() async throws {
        let h = try makeHarness("push-two", devices: [pushDevice(1, token: testToken), pushDevice(2, token: otherTestToken),
                                                       pushDevice(3, token: nil), pushDevice(4, token: String(repeating: "ff", count: 32), environment: "production")])
        await h.model.start()
        await publishNewBuild(h)
        let tokens = h.transport.requests.compactMap { $0.url?.lastPathComponent }
        #expect(tokens.sorted() == [testToken, otherTestToken].sorted())
        #expect(h.push.lastDelivery?.failed == false)
        await h.model.shutdown()
    }

    @Test func devicesFromAnotherControlServerAreSkipped() async throws {
        let h = try makeHarness("push-scope", devices: [pushDevice(1, token: testToken)])
        h.model.controlURL = "https://headscale.example.com"
        await h.model.start()
        #expect(h.model.deviceScopeConflict != nil)
        await publishNewBuild(h)
        #expect(h.transport.requests.isEmpty)
        await h.model.shutdown()
    }

    @Test func nothingIsSentWhileNotSharing() async throws {
        let h = try makeHarness("push-stopped", devices: [pushDevice(1, token: testToken)])
        await h.model.load()
        #expect(!h.model.isRunning)
        await publishNewBuild(h)
        #expect(h.transport.requests.isEmpty)
    }

    @Test func goneTokenIsRemovedFromTheListTheFileAndTheCore() async throws {
        let transport = FakeAPNsTransport()
        transport.state.withLock { $0.perToken[testToken] = .status(410, "Unregistered") }
        let h = try makeHarness("push-gone", devices: [pushDevice(1, token: testToken), pushDevice(2, token: otherTestToken)], transport: transport)
        await h.model.start()
        await publishNewBuild(h)
        #expect(h.model.devices.first { $0.id == "d_1" }?.push == nil)
        #expect(h.model.devices.first { $0.id == "d_2" }?.push?.token == otherTestToken)
        #expect(try savedDevices(h.paths).first { $0.id == "d_1" }?.push == nil)
        let applied = try #require(h.core.setDevicesCalls.last)
        #expect(applied.first { $0.id == "d_1" }?.push == nil)
        #expect(applied.first { $0.id == "d_2" }?.push != nil)
        #expect(h.push.lastDelivery?.failed == true)
        #expect(h.push.lastDelivery?.text.contains(testToken) == false, "토큰 전체를 화면에 남기지 않는다")
        await h.model.shutdown()
    }

    /// 첫 기기에 보내는 사이 키를 지우면 남은 기기에는 예전 키로 보내지 않는다.
    @Test func clearingTheKeyStopsDeliveryToRemainingDevices() async throws {
        let gate = Gate()
        let transport = FakeAPNsTransport()
        transport.state.withLock { $0.gate = gate }
        let h = try makeHarness("push-clear", devices: [pushDevice(1, token: testToken), pushDevice(2, token: otherTestToken)], transport: transport)
        await h.model.start()
        h.push.libraryChanged(builds: library(["b_1"]), resources: [])
        h.push.libraryChanged(builds: library(["b_2", "b_1"]), resources: [])
        for _ in 0..<10_000 where await gate.arrivals == 0 { await Task.yield() }
        #expect(await gate.arrivals == 1)
        h.push.clearKey()
        #expect(!h.push.isConfigured)
        await gate.open()
        await h.push.waitForDelivery()
        #expect(h.transport.requests.count == 1)
        #expect(h.push.lastDelivery?.failed == true)
        #expect(h.push.lastDelivery?.text.contains("키 설정이 바뀌어") == true)
        await h.model.shutdown()
    }

    /// 한 기기에 알림 두 개를 보내는 사이 키를 지우면 두 번째는 예전 키로 보내지 않는다.
    @Test func clearingTheKeyStopsTheRestOfOneDevicesNotifications() async throws {
        let gate = Gate()
        let transport = FakeAPNsTransport()
        transport.state.withLock { $0.gate = gate }
        let h = try makeHarness("push-clear-one", devices: [pushDevice(1, token: testToken)], transport: transport)
        await h.model.start()
        h.push.libraryChanged(builds: library(["b_1"]), resources: [])
        h.push.libraryChanged(builds: library(["b_2", "b_1"]), resources: [pushFile("r_1", name: "a.txt")])
        for _ in 0..<10_000 where await gate.arrivals == 0 { await Task.yield() }
        #expect(await gate.arrivals == 1)
        h.push.clearKey()
        await gate.open()
        await h.push.waitForDelivery()
        #expect(h.transport.requests.count == 1)
        #expect(h.push.lastDelivery?.failed == true)
        #expect(h.push.lastDelivery?.text.contains("키 설정이 바뀌어") == true)
        await h.model.shutdown()
    }

    @Test func testNotificationIsRecorded() async throws {
        let h = try makeHarness("push-test", devices: [pushDevice(1, token: testToken)])
        await h.model.load()
        #expect(h.push.testUnavailableReason == nil)
        await h.push.sendTest()
        let request = try #require(h.transport.requests.first)
        let body = try jsonDict(request.httpBody)
        #expect(body["rd"] as? [String: String] == ["kind": "test"])
        let delivery = try #require(h.push.lastDelivery)
        #expect(!delivery.failed)
        #expect(delivery.text.contains("시험 알림입니다"))
    }

    @Test func filesAddedTogetherBecomeOneNotification() async throws {
        let gate = Gate()
        let h = try makeHarness("push-batch", devices: [pushDevice(1, token: testToken)], sleep: { _ in await gate.wait() })
        await h.model.start()
        var urls: [URL] = []
        for name in ["a.txt", "b.txt", "c.txt"] {
            let url = h.tmp.path(name)
            try Data(name.utf8).write(to: url)
            urls.append(url)
        }
        await h.model.shareFiles(urls)
        #expect(h.model.sharedFiles.count == 3)
        #expect(h.transport.requests.isEmpty, "조용해지기 전에는 보내지 않는다")
        await gate.open()
        await h.push.waitForDelivery()
        #expect(h.transport.requests.count == 1)
        let body = try jsonDict(h.transport.requests.first?.httpBody)
        #expect((body["aps"] as? [String: Any])?["alert"] as? [String: String] == ["title": "새 파일", "body": "파일 3개"])
        #expect(body["rd"] as? [String: String] == ["kind": "resource"])
        await h.model.shutdown()
    }

    @Test func existingItemsAtLaunchAreNotAnnounced() async throws {
        let h = try makeHarness("push-launch", devices: [pushDevice(1, token: testToken)])
        let url = h.tmp.path("old.txt")
        try Data("old".utf8).write(to: url)
        await h.model.start()
        await h.model.shareFiles([url])
        await h.push.waitForDelivery()
        #expect(h.transport.requests.count == 1)
        await h.model.shutdown()

        // 다시 켠 앱: 이미 있던 파일은 알리지 않는다.
        let again = try makeHarness("push-launch2", devices: [pushDevice(1, token: testToken)])
        try FileManager.default.removeItem(at: again.paths.root)
        try FileManager.default.copyItem(at: h.paths.root, to: again.paths.root)
        await again.model.start()
        await again.push.waitForDelivery()
        #expect(again.model.sharedFiles.count == 1)
        #expect(again.transport.requests.isEmpty)
        await again.model.shutdown()
    }

    @Test func savingValidatesTheKeyAndIDs() throws {
        let h = try makeHarness("push-save", devices: [], withKey: false)
        #expect(!h.push.save(pem: "garbage", keyID: "KEY0000001", teamID: "TEAM000001"))
        #expect(h.push.setupError == APNsKeyFailure.notP256Key.message)
        #expect(h.keys.load() == nil)
        let pem = P256.Signing.PrivateKey().pemRepresentation
        #expect(!h.push.save(pem: pem, keyID: "bad", teamID: "TEAM000001"))
        #expect(h.push.save(pem: pem, keyID: "key0000001", teamID: "team000001"))
        #expect(h.push.isConfigured)
        #expect(h.push.keyID == "KEY0000001")
        #expect(h.push.save(pem: nil, keyID: "KEY0000002", teamID: "TEAM000001"), "키는 그대로 두고 ID만 바꾼다")
        h.push.clearKey()
        #expect(!h.push.isConfigured)
        #expect(h.keys.load() == nil)
    }
}
