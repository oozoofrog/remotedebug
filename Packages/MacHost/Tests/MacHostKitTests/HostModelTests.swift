import Foundation
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

@MainActor
@Suite("HostModel")
struct HostModelTests {
    final class OpenedURLs: Sendable {
        let urls = Mutex<[URL]>([])
    }

    struct Harness {
        let tmp: TempDir
        let core: FakeHostCore
        let model: HostModel
        let paths: HostPaths
        let opened: OpenedURLs
        let bookmarks: FakeBookmarks
        let inspector: FakeInspector
        let packager: FakePackager
    }

    func makeHarness(_ label: String, clock: @escaping @Sendable () -> Date = { Date() }, port: Int = 443,
                     prepare: (HostPaths) throws -> Void = { _ in }) throws -> Harness {
        let tmp = try TempDir(label)
        let paths = HostPaths(root: tmp.path("host"))
        try paths.prepare()
        try prepare(paths)
        let core = FakeHostCore()
        let opened = OpenedURLs()
        let bookmarks = FakeBookmarks()
        let inspector = FakeInspector()
        let packager = FakePackager()
        let model = HostModel(
            core: core, paths: paths, inspector: inspector, packager: packager, bookmarks: bookmarks,
            watcherOptions: .init(useFileEvents: false), id8: "ab12cd34", hostDisplayName: "작업용 Mac", appVersion: "0.1.0",
            port: port, openURL: { url in opened.urls.withLock { $0.append(url) } }, now: clock
        )
        return Harness(tmp: tmp, core: core, model: model, paths: paths, opened: opened, bookmarks: bookmarks,
                       inspector: inspector, packager: packager)
    }

    func pairRequest(_ id: String, expiresIn: TimeInterval = 120, now: Date = Date(), deviceName: String = "내 iPhone") -> PairRequestEvent {
        PairRequestEvent(requestId: id, deviceName: deviceName, nodeName: "rd-phone-1", loginName: "user@example.com",
                         expiresAt: now.addingTimeInterval(expiresIn))
    }

    /// 코어가 요청을 받은 것처럼: 가짜 코어에 등록하고 모델에 이벤트를 넣는다.
    func receive(_ h: Harness, _ e: PairRequestEvent) {
        h.core.registerRequest(e.requestId)
        h.model.handle(.pairRequest(e))
    }

    // MARK: 시작 설정

    @Test func startBuildsConfigAndPushesSavedDevices() async throws {
        let saved = [sampleDevice(1), sampleDevice(2)]
        let h = try makeHarness("start", prepare: { paths in
            try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: saved))
        })
        let secret = "tskey-auth-SECRET-123"
        await h.model.start(authKey: secret)

        #expect(h.model.isRunning)
        #expect(h.model.devices == saved)
        let config = try #require(h.core.startConfigs.first)
        #expect(config.mode == .host)
        #expect(config.hostname == "rd-mac-ab12cd34")
        #expect(config.authKey == secret)
        #expect(config.controlURL == "")
        #expect(config.listenTLS)
        #expect(config.stateDir == h.paths.stateDir.path)
        #expect(config.publishDir == h.paths.publishedDir.path)
        #expect(config.hostDisplayName == "작업용 Mac")
        #expect(config.appVersion == "0.1.0")
        // start 다음에 저장된 기기를 밀어 넣는다
        let startIndex = try #require(h.core.calls.firstIndex { if case .start = $0 { true } else { false } })
        let setIndex = try #require(h.core.calls.firstIndex { if case .setDevices = $0 { true } else { false } })
        #expect(startIndex < setIndex)
        #expect(h.core.setDevicesCalls.first == saved)

        // 인증 키는 디스크 어디에도 남지 않는다
        let enumerator = FileManager.default.enumerator(at: h.paths.root, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            if let data = try? Data(contentsOf: file) {
                let name = file.lastPathComponent
                #expect(!String(decoding: data, as: UTF8.self).contains(secret), "인증 키가 남은 파일: \(name)")
            }
        }
    }

    @Test func loopbackControlURLDisablesTLS() throws {
        let h = try makeHarness("loopback")
        h.model.controlURL = "http://127.0.0.1:9911"
        #expect(h.model.makeConfig(authKey: "").listenTLS == false)
        h.model.controlURL = "https://controlplane.example.com"
        #expect(h.model.makeConfig(authKey: "").listenTLS == true)

        #expect(HostModel.isLoopbackHost(of: "http://localhost:8080"))
        #expect(HostModel.isLoopbackHost(of: "http://[::1]:80"))
        #expect(HostModel.isLoopbackHost(of: "http://127.8.9.10"))
        #expect(!HostModel.isLoopbackHost(of: ""))
        #expect(!HostModel.isLoopbackHost(of: "http://127.0.0.1.example.com"))
        #expect(!HostModel.isLoopbackHost(of: "http://10.0.0.1"))
    }

    @Test func startFailureLeavesStoppedWithError() async throws {
        let h = try makeHarness("startfail")
        h.core.state.withLock { $0.failStart = true }
        await h.model.start()
        #expect(!h.model.isRunning)
        #expect(h.model.lastError != nil)
        #expect(h.core.setDevicesCalls.isEmpty)
    }

    @Test func identityIsCreatedOnceAndReused() throws {
        let tmp = try TempDir("identity")
        let url = tmp.path("identity.json")
        let first = try HostIdentity.loadOrCreate(at: url)
        let second = try HostIdentity.loadOrCreate(at: url)
        #expect(first == second)
        #expect(first.count == 8)
        #expect(first.allSatisfy { $0.isHexDigit })
        #expect(HostIdentity.nodeName(id8: first) == "rd-mac-\(first)")
    }

    // MARK: 페어링

    @Test func pairingApproveSavesDeviceAndPushesAllowList() async throws {
        let h = try makeHarness("pair")
        await h.model.start()
        await h.model.beginPairing()
        #expect(h.core.calls.contains(.openPairing(300)))
        #expect(h.model.pairingCode?.displayCode == "K7M2-9QXD")
        h.core.emit(.state(CoreStatus(backendState: .running, fqdn: "rd-mac-ab12cd34.example.ts.net",
                                      certDomains: ["rd-mac-ab12cd34.example.ts.net"], tlsReady: true)))
        #expect(await eventually { h.model.status?.fqdn == "rd-mac-ab12cd34.example.ts.net" })
        #expect(h.model.pairingLink?.absoluteString == "remotedebug://pair?host=rd-mac-ab12cd34.example.ts.net&code=K7M29QXD")
        h.core.emit(.pairRequest(pairRequest("pr_1")))
        #expect(await eventually { h.model.pendingPairRequests.map(\.requestId) == ["pr_1"] })
        // 코드는 한 번만 쓸 수 있다: 요청이 오면 코드·링크를 내린다.
        #expect(h.model.pairingLink == nil)
        #expect(h.model.pairingState == .requestReceived(requestId: "pr_1"))

        await h.model.approve("pr_1")
        #expect(h.core.calls.contains(.decide("pr_1", true)))
        #expect(h.model.pendingPairRequests.isEmpty)
        #expect(h.model.pairingState == .idle)
        #expect(h.model.devices == [sampleDevice(1)])
        // 승인하면 코어가 허용 목록에 직접 넣으므로 시작 때 말고는 setDevices를 보내지 않는다.
        #expect(h.core.setDevicesCalls == [[]])
        let saved = try JSONFile<DeviceList>(url: h.paths.devicesFile).load()
        #expect(saved?.devices == [sampleDevice(1)])

        // 코어의 device-added가 같은 기기를 다시 알려도 중복되지 않는다
        h.core.emit(.deviceAdded(sampleDevice(1)))
        h.core.emit(.pairDecided(PairDecidedEvent(requestId: "pr_1", state: .approved)))
        #expect(await eventually { h.model.activity.count == 2 })
        #expect(h.model.devices.count == 1)
    }

    @Test func denyDoesNotAddDevice() async throws {
        let h = try makeHarness("deny")
        await h.model.start()
        receive(h, pairRequest("pr_2"))
        await h.model.deny("pr_2")
        #expect(h.core.calls.contains(.decide("pr_2", false)))
        #expect(h.model.devices.isEmpty)
        #expect(h.model.pendingPairRequests.isEmpty)
        #expect(h.core.setDevicesCalls == [[]])  // 시작 때 한 번뿐
    }

    @Test func expiredRequestIsNotSentToCore() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_900_000_000))
        let h = try makeHarness("expired", clock: { clock.withLock { $0 } })
        await h.model.start()
        let t0 = clock.withLock { $0 }
        receive(h, pairRequest("pr_gone", expiresIn: -1, now: t0))
        #expect(h.model.pairRequests.isEmpty)  // 이미 만료된 요청은 목록에 넣지 않는다

        receive(h, pairRequest("pr_1", expiresIn: 120, now: t0))
        #expect(h.model.pendingPairRequests.map(\.requestId) == ["pr_1"])
        clock.withLock { $0 = $0.addingTimeInterval(600) }
        #expect(h.model.pendingPairRequests.isEmpty)
        await h.model.approve("pr_1")
        #expect(!h.core.calls.contains(.decide("pr_1", true)))
        #expect(h.model.pairRequests.isEmpty)
        #expect(h.model.lastError?.contains("만료") == true)
    }

    @Test func removeDevicePushesAllowList() async throws {
        let h = try makeHarness("remove", prepare: { paths in
            try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: [sampleDevice(1), sampleDevice(2)]))
        })
        await h.model.start()
        await h.model.removeDevice("d_1")
        #expect(h.model.devices == [sampleDevice(2)])
        #expect(h.core.setDevicesCalls.last == [sampleDevice(2)])
        #expect(try JSONFile<DeviceList>(url: h.paths.devicesFile).load()?.devices == [sampleDevice(2)])
    }

    // MARK: 상태 안내

    @Test func needsLoginGuidanceAndLoginPage() async throws {
        let h = try makeHarness("login")
        await h.model.start()
        h.model.handle(.state(CoreStatus(backendState: .needsLogin, authURL: "https://login.tailscale.com/a/abc123")))
        #expect(h.model.guidance.kind == .needsLogin)
        #expect(h.model.guidance.action == .openLoginPage)
        h.model.openLoginPage()
        #expect(h.opened.urls.withLock { $0 } == [URL(string: "https://login.tailscale.com/a/abc123")!])

        h.model.handle(.state(CoreStatus(backendState: .needsLogin, authURL: "")))
        #expect(h.model.guidance.kind == .waitingForLoginURL)
        h.model.openLoginPage()
        #expect(h.opened.urls.withLock { $0.count } == 1)
        #expect(h.model.lastError != nil)
    }

    @Test func certificateGuidance() {
        let off = StatusGuidance.make(for: CoreStatus(backendState: .running, fqdn: "x.ts.net", certDomains: [], tlsReady: false))
        #expect(off.kind == .certificatesDisabled)
        #expect(off.message.contains("HTTPS 인증서 사용이 꺼져 있어 설치 주소를 만들 수 없습니다"))
        #expect(off.message.contains("DNS"))

        let issuing = StatusGuidance.make(for: CoreStatus(backendState: .running, fqdn: "x.ts.net", certDomains: ["x.ts.net"], tlsReady: false))
        #expect(issuing.kind == .issuingCertificate)
        #expect(issuing.message.contains("발급"))

        let ready = StatusGuidance.make(for: CoreStatus(backendState: .running, fqdn: "x.ts.net", certDomains: ["x.ts.net"], tlsReady: true))
        #expect(ready.kind == .ready)
        #expect(ready.message.contains("x.ts.net"))
    }

    @Test func errorAndOtherStatesGuidance() {
        let err = StatusGuidance.make(for: CoreStatus(backendState: .error, errorMessage: "인증 키가 거부됐습니다"))
        #expect(err.kind == .error)
        #expect(err.message.contains("인증 키가 거부됐습니다"))
        #expect(err.action == .restart)
        #expect(StatusGuidance.make(for: CoreStatus(backendState: .error)).message.isEmpty == false)
        #expect(StatusGuidance.make(for: nil).kind == .stopped)
        #expect(StatusGuidance.make(for: nil).action == .start)
        #expect(StatusGuidance.make(for: CoreStatus(backendState: .stopped)).kind == .stopped)
        #expect(StatusGuidance.make(for: CoreStatus(backendState: .starting)).kind == .starting)
        #expect(StatusGuidance.make(for: CoreStatus(backendState: .needsMachineAuth)).kind == .needsMachineAuth)
        #expect(StatusGuidance.make(for: CoreStatus(backendState: "Weird")).kind == .unknown)
    }

    // MARK: 이벤트

    @Test func sessionEventsReplaceAndActivityIsCapped() async throws {
        let h = try makeHarness("activity")
        await h.model.start()
        let s1 = SessionEvent(sessionId: "s_1", buildId: "b_1", nodeName: "rd-phone-1", state: .created, userAgent: "ua", bytesServed: 0)
        h.model.handle(.session(s1))
        var s2 = s1
        s2.state = .completed
        h.model.handle(.session(s2))
        #expect(h.model.activity.count == 1)
        #expect(h.model.activity.first?.text.contains("전송 완료") == true)

        h.model.handle(.denied(DeniedEvent(path: "/v1/info", reason: "not_paired", nodeName: "rd-phone-9", suppressed: 4)))
        #expect(h.model.activity.first?.text.contains("rd-phone-9") == true)
        #expect(h.model.activity.first?.text.contains("4건") == true)

        for i in 0..<250 {
            h.model.handle(.denied(DeniedEvent(path: "/v1/builds/\(i)", reason: "not_paired")))
        }
        #expect(h.model.activity.count == HostModel.activityLimit)
        for i in 0..<250 { h.model.handle(.log(LogEvent(level: "info", message: "m\(i)"))) }
        #expect(h.model.logs.count == HostModel.logLimit)
        #expect(h.model.logs.last?.message == "m249")
    }

    // MARK: 빌드·폴더

    @Test func importBeforeStartPublishesOnStart() async throws {
        let h = try makeHarness("import")
        await h.model.load()
        let app = try makeImportableApp(in: h.tmp.path("src"), name: "Early")
        let outcome = await h.model.importBuild(app)
        guard case .accepted(let b) = outcome else { Issue.record("수락돼야 함"); return }
        #expect(h.core.published.isEmpty)
        #expect(h.model.builds.map(\.id) == [b.id])

        await h.model.start()
        #expect(h.core.published.map(\.build.id) == [b.id])

        await h.model.unpublish(b.id)
        #expect(h.core.unpublished == [b.id])
        #expect(h.model.builds.isEmpty)
    }

    @Test func rejectedImportShowsReasons() async throws {
        let h = try makeHarness("rejected")
        await h.model.start()
        await h.model.importBuild(try makeImportableApp(in: h.tmp.path("src"), name: "RejectThis"))
        #expect(h.model.rejected.count == 1)
        #expect(h.model.rejected.first?.messages.isEmpty == false)
        #expect(h.core.published.isEmpty)
    }

    @Test func chosenFolderIsWatchedAndImported() async throws {
        let h = try makeHarness("folder")
        await h.model.start()
        let folder = h.tmp.path("Builds")
        try makeImportableApp(in: folder.appendingPathComponent("Debug-iphoneos"), name: "Watched")
        await h.model.chooseFolder(folder)
        #expect(h.bookmarks.resolve() == folder)
        #expect(h.model.watchedFolder == folder)
        #expect(h.model.builds.count == 1)
        #expect(h.core.published.count == 1)

        await h.model.rescan()
        #expect(h.core.published.count == 1)  // 지문이 같아 다시 검사하지 않는다
    }

    @Test func shutdownStopsNode() async throws {
        let h = try makeHarness("shutdown")
        await h.model.start()
        await h.model.chooseFolder(h.tmp.path("host"))
        await h.model.shutdown()
        #expect(h.core.calls.last == .stop)
        #expect(!h.model.isRunning)
        #expect(h.model.watchedFolder == nil)
        #expect(h.model.guidance.kind == .stopped)
    }
}
