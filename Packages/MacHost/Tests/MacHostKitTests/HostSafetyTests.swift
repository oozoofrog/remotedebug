import Foundation
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

/// 쓸 수 없는 `identity.json`(백업 제외 표시를 남길 수 없다).
func writeReadOnlyIdentity(at paths: HostPaths) throws {
    try Data(#"{"id8":"ab12cd34"}"#.utf8).write(to: paths.identityFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: paths.identityFile.path)
}

@Suite("저장 폴더 잠금·백업 제외·실행 인자")
struct HostStorageTests {
    @Test func secondAcquireOfTheSameRootFails() throws {
        let tmp = try TempDir("lock")
        let root = tmp.path("RemoteDebug")
        let first = try StateDirLock.acquire(root: root)
        #expect(first.isHeld)
        #expect(throws: StateDirLock.Failure.held) { _ = try StateDirLock.acquire(root: root) }
        // 다른 폴더는 따로 잠긴다.
        let other = try StateDirLock.acquire(root: tmp.path("Other"))
        other.release()

        first.release()
        first.release()  // 두 번 놓아도 된다
        #expect(!first.isHeld)
        let again = try StateDirLock.acquire(root: root)
        #expect(again.isHeld)
        again.release()
    }

    @Test func lockIsReleasedWhenTheOwnerGoesAway() throws {
        let tmp = try TempDir("lock-deinit")
        let root = tmp.path("RemoteDebug")
        do {
            let held = try StateDirLock.acquire(root: root)
            _ = held
        }
        let again = try StateDirLock.acquire(root: root)
        again.release()
    }

    @Test func stateDirAndIdentityAreExcludedFromBackup() throws {
        let tmp = try TempDir("backup")
        let paths = HostPaths(root: tmp.path("host"))
        try paths.prepare()
        #expect(HostPaths.isExcludedFromBackup(paths.stateDir))
        #expect(!HostPaths.isExcludedFromBackup(paths.publishedDir), "게시본은 노드 신원이 아니다")

        _ = try HostIdentity.loadOrCreate(at: paths.identityFile)
        #expect(HostPaths.isExcludedFromBackup(paths.identityFile))

        // 표시가 지워져도 prepare를 다시 부르면 다시 적용한다.
        for target in [paths.stateDir, paths.identityFile] {
            var url = target
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try url.setResourceValues(values)
            #expect(!HostPaths.isExcludedFromBackup(target))
        }
        try paths.prepare()
        #expect(HostPaths.isExcludedFromBackup(paths.stateDir))
        #expect(HostPaths.isExcludedFromBackup(paths.identityFile))
    }

    /// 백업에서 빼지 못해도 폴더 준비는 끝나고, 빼지 못한 항목을 돌려준다(IMP2-1).
    @Test func backupExclusionFailureDoesNotFailPrepare() throws {
        let tmp = try TempDir("backup-fail")
        let paths = HostPaths(root: tmp.path("host"))
        try paths.prepare()
        try writeReadOnlyIdentity(at: paths)
        #expect(try paths.prepare() == [paths.identityFile])
    }

    /// 저장 폴더를 바꾼 실행은 기본 폴더의 감시 폴더·제어 서버를 읽지도 바꾸지도 않는다.
    @Test func stateRootNameIsolatesSavedDefaults() throws {
        let defaults = InMemoryDefaults()
        let tmp = try TempDir("isolated-defaults")
        let folder = tmp.path("Watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults.set("https://developer.example.com", forKey: LaunchOptions.controlURLKey)

        let real = LaunchOptions(defaults: defaults, environment: [:], arguments: [:])
        #expect(real.stateRootName == LaunchOptions.defaultStateRootName)
        #expect(real.folderBookmarkKey == UserDefaultsFolderBookmarks.defaultKey)
        #expect(real.savedControlURLKey == LaunchOptions.controlURLKey)
        #expect(real.controlURL == "https://developer.example.com")
        let realStore = UserDefaultsFolderBookmarks(defaults: defaults, key: real.folderBookmarkKey, securityScoped: false)
        try realStore.save(folder)

        defaults.set("RemoteDebug-smoke-2", forKey: LaunchOptions.stateRootNameKey)
        let smoke = LaunchOptions(defaults: defaults, environment: [:], arguments: [:])
        #expect(smoke.controlURL.isEmpty, "다른 저장 폴더가 기본 폴더의 제어 서버를 읽었다")
        #expect(smoke.savedControlURLKey != LaunchOptions.controlURLKey)
        #expect(smoke.folderBookmarkKey != real.folderBookmarkKey)
        let smokeStore = UserDefaultsFolderBookmarks(defaults: defaults, key: smoke.folderBookmarkKey, securityScoped: false)
        #expect(smokeStore.savedFolder() == .none, "다른 저장 폴더가 기본 폴더의 감시 폴더를 읽었다")

        smokeStore.clear()
        guard case .folder = realStore.savedFolder() else {
            Issue.record("다른 저장 폴더가 기본 폴더의 북마크를 지웠다")
            return
        }
        defaults.set("http://127.0.0.1:1", forKey: smoke.savedControlURLKey)
        #expect(LaunchOptions(defaults: defaults, environment: [:], arguments: [:]).controlURL == "http://127.0.0.1:1")
        #expect(defaults.string(forKey: LaunchOptions.controlURLKey) == "https://developer.example.com")
    }

    @Test func launchOptionsReadArgumentsAndRejectBadValues() throws {
        let defaults = InMemoryDefaults()
        defaults.set("ab12cd34", forKey: LaunchOptions.nodeID8Key)
        defaults.set(true, forKey: LaunchOptions.startSharingKey)
        defaults.set("RemoteDebug-smoke-1", forKey: LaunchOptions.stateRootNameKey)
        let options = LaunchOptions(defaults: defaults, environment: [:],
                                    arguments: [LaunchOptions.controlURLKey: " http://127.0.0.1:9911 "])
        #expect(options.controlURL == "http://127.0.0.1:9911")
        #expect(options.nodeID8 == "ab12cd34")
        #expect(options.startSharing)
        #expect(options.stateRootName == "RemoteDebug-smoke-1")
        #expect(!options.isTesting)

        for bad in ["AB12CD34", "ab12cd3", "ab12cd34x", "zz12cd34"] {
            defaults.set(bad, forKey: LaunchOptions.nodeID8Key)
            #expect(LaunchOptions(defaults: defaults, environment: [:]).nodeID8 == nil, "\(bad)")
        }
        for bad in ["../x", "a/b", "", ".hidden", String(repeating: "a", count: 65)] {
            defaults.set(bad, forKey: LaunchOptions.stateRootNameKey)
            #expect(LaunchOptions(defaults: defaults, environment: [:]).stateRootName == "RemoteDebug", "\(bad)")
        }

        #expect(LaunchOptions(defaults: defaults, environment: ["XCTestConfigurationFilePath": "/x"]).isTesting)
        defaults.set(true, forKey: LaunchOptions.testingKey)
        #expect(LaunchOptions(defaults: defaults, environment: [:]).isTesting)
    }
}

@MainActor
@Suite("허용 목록의 제어 서버 범위·페어링 가능 여부·감시 폴더 문제")
struct HostSafetyModelTests {
    struct Harness {
        let tmp: TempDir
        let core: FakeHostCore
        let model: HostModel
        let paths: HostPaths
        let bookmarks: any FolderBookmarking
    }

    func makeHarness(_ label: String, bookmarks: any FolderBookmarking = FakeBookmarks(),
                     prepare: (HostPaths) throws -> Void = { _ in }) throws -> Harness {
        let tmp = try TempDir(label)
        let paths = HostPaths(root: tmp.path("host"))
        try paths.prepare()
        try prepare(paths)
        let core = FakeHostCore()
        let model = HostModel(core: core, paths: paths, inspector: FakeInspector(), packager: FakePackager(), bookmarks: bookmarks,
                              watcherOptions: .init(useFileEvents: false), id8: "ab12cd34", hostDisplayName: "Mac",
                              appVersion: "0.1.0", openURL: { _ in })
        return Harness(tmp: tmp, core: core, model: model, paths: paths, bookmarks: bookmarks)
    }

    func saveDevices(_ devices: [DeviceEntry], controlURL: String?, at paths: HostPaths) throws {
        try JSONFile<StoredDeviceList>(url: paths.devicesFile).save(StoredDeviceList(controlURL: controlURL, devices: devices))
    }

    // MARK: 제어 서버 범위 (MACAPP-LC-2)

    @Test func devicesPairedOnAnotherControlServerAreNeverPushed() async throws {
        let h = try makeHarness("scope-other", prepare: {
            try saveDevices([sampleDevice(1), sampleDevice(2)], controlURL: "https://headscale-a.example.com", at: $0)
        })
        h.model.controlURL = "https://headscale-b.example.com"
        await h.model.start()
        #expect(h.model.isRunning)
        #expect(h.core.setDevicesCalls == [[]], "다른 서버의 기기를 코어에 보냈다: \(h.core.setDevicesCalls)")
        let conflict = try #require(h.model.deviceScopeConflict)
        #expect(conflict.savedControlURL == "https://headscale-a.example.com")
        #expect(conflict.deviceCount == 2)
        #expect(h.model.pairingAvailability != .ready, "충돌을 풀기 전에는 페어링하지 않는다")

        // 기기 제거도 다른 서버의 기기를 다시 보내지 않는다.
        await h.model.removeDevice("d_1")
        #expect(h.core.setDevicesCalls.allSatisfy { $0.isEmpty })
        await h.model.shutdown()
    }

    @Test func matchingControlServerPushesDevicesAndLegacyFilesMeanDefaultServer() async throws {
        let h = try makeHarness("scope-same", prepare: {
            try saveDevices([sampleDevice(1)], controlURL: "https://Headscale.Example.com/", at: $0)
        })
        h.model.controlURL = " https://headscale.example.com "
        await h.model.start()
        #expect(h.core.setDevicesCalls == [[sampleDevice(1)]])
        #expect(h.model.deviceScopeConflict == nil)
        await h.model.shutdown()

        // controlURL이 없는 예전 파일: 기본 제어 서버에서만 보낸다.
        let legacy = try makeHarness("scope-legacy", prepare: {
            try JSONFile<DeviceList>(url: $0.devicesFile).save(DeviceList(devices: [sampleDevice(3)]))
        })
        legacy.model.controlURL = "http://127.0.0.1:9911"
        await legacy.model.start()
        #expect(legacy.core.setDevicesCalls == [[]])
        #expect(legacy.model.deviceScopeConflict?.savedControlURL == "")
        await legacy.model.shutdown()
    }

    @Test func changingTheControlURLNeedsConfirmationAndThenClearsDevices() async throws {
        let h = try makeHarness("scope-change", prepare: {
            try saveDevices([sampleDevice(1), sampleDevice(2)], controlURL: "", at: $0)
        })
        await h.model.load()
        #expect(h.model.devicesDroppedByControlURL("https://controlplane.tailscale.com/") == 0, "기본 서버의 다른 표기")
        #expect(h.model.devicesDroppedByControlURL("https://headscale.example.com") == 2)

        // 확인 없이는 바꾸지 않는다.
        #expect(!h.model.applyControlURL("https://headscale.example.com", forgetOtherServerDevices: false))
        #expect(h.model.controlURL == "")
        #expect(h.model.devices.count == 2)

        // 확인하면 바꾸고 기기를 지운다(새 서버에서 다시 페어링해야 한다).
        #expect(h.model.applyControlURL("https://headscale.example.com", forgetOtherServerDevices: true))
        #expect(h.model.controlURL == "https://headscale.example.com")
        #expect(h.model.devices.isEmpty)
        #expect(h.model.deviceScopeConflict == nil)
        let stored = try JSONFile<StoredDeviceList>(url: h.paths.devicesFile).load()
        #expect(stored?.devices.isEmpty == true)
        #expect(stored?.controlURL == "https://headscale.example.com")

        await h.model.start()
        #expect(h.core.setDevicesCalls == [[]])
        // 공유 중에는 바꿀 수 없다.
        #expect(!h.model.applyControlURL("", forgetOtherServerDevices: true))
        await h.model.shutdown()
    }

    @Test func conflictFromLaunchArgumentIsClearedOnlyByExplicitForget() async throws {
        let h = try makeHarness("scope-forget", prepare: {
            try saveDevices([sampleDevice(1)], controlURL: "", at: $0)
        })
        h.model.controlURL = "https://headscale.example.com"
        await h.model.load()
        #expect(h.model.deviceScopeConflict != nil)
        // 다시 불러와도 그대로다(조용히 옮기지 않는다).
        #expect(try JSONFile<StoredDeviceList>(url: h.paths.devicesFile).load()?.controlURL == "")

        h.model.forgetDevicesFromOtherServer()
        #expect(h.model.devices.isEmpty)
        #expect(h.model.deviceScopeConflict == nil)
        #expect(try JSONFile<StoredDeviceList>(url: h.paths.devicesFile).load()?.controlURL == "https://headscale.example.com")
    }

    @Test func approvedDeviceIsStoredWithTheCurrentControlServer() async throws {
        let h = try makeHarness("scope-approve")
        h.model.controlURL = "https://headscale.example.com"
        await h.model.start()
        h.core.registerRequest("pr_1")
        h.model.handle(.pairRequest(PairRequestEvent(requestId: "pr_1", deviceName: "iPhone", nodeName: "rd-phone-1",
                                                     loginName: "", expiresAt: Date().addingTimeInterval(120))))
        await h.model.approve("pr_1")
        #expect(h.model.devices == [sampleDevice(1)])
        let stored = try JSONFile<StoredDeviceList>(url: h.paths.devicesFile).load()
        #expect(stored?.controlURL == "https://headscale.example.com")
        // 예전 형식으로 읽어도 기기 목록이 그대로다.
        #expect(try JSONFile<DeviceList>(url: h.paths.devicesFile).load()?.devices == [sampleDevice(1)])
        await h.model.shutdown()
    }

    /// 대소문자·끝 슬래시가 섞인 제어 서버에서도 승인한 기기를 저장한다(TQ2-3).
    @Test func approvalStoresTheNormalizedControlServer() async throws {
        let h = try makeHarness("scope-normalized")
        h.model.controlURL = " https://Headscale.Example.com/ "
        await h.model.start()
        h.core.registerRequest("pr_1")
        h.model.handle(.pairRequest(PairRequestEvent(requestId: "pr_1", deviceName: "iPhone", nodeName: "rd-phone-1",
                                                     loginName: "", expiresAt: Date().addingTimeInterval(120))))
        await h.model.approve("pr_1")
        #expect(h.model.lastPairingOutcome == PairingOutcome(requestId: "pr_1", kind: .allowed))
        #expect(h.model.devices == [sampleDevice(1)])
        h.model.handle(.deviceAdded(sampleDevice(2)))
        #expect(h.model.devices == [sampleDevice(1), sampleDevice(2)])
        let stored = try JSONFile<StoredDeviceList>(url: h.paths.devicesFile).load()
        #expect(stored?.controlURL == "https://headscale.example.com")
        await h.model.shutdown()
    }

    @Test func controlURLNormalization() {
        #expect(HostModel.normalizedControlURL("") == "")
        #expect(HostModel.normalizedControlURL("  ") == "")
        #expect(HostModel.normalizedControlURL("https://controlplane.tailscale.com") == "")
        #expect(HostModel.normalizedControlURL("HTTPS://Controlplane.Tailscale.com/") == "")
        #expect(HostModel.normalizedControlURL("https://hs.example.com//") == "https://hs.example.com")
        #expect(HostModel.normalizedControlURL("http://127.0.0.1:9911") == "http://127.0.0.1:9911")
        #expect(HostModel.normalizedControlURL("https://hs.example.com") != HostModel.normalizedControlURL("https://hs2.example.com"))
    }

    /// 페어링 결정은 어디서나 허용/거부로 쓴다(MACUI-6).
    @Test func pairingDecisionWordsAreAllowAndDeny() {
        #expect(ActivityText.pairDecided(PairDecidedEvent(requestId: "pr_1", state: .approved), deviceName: "내 iPhone") == "내 iPhone 페어링을 허용했습니다.")
        #expect(ActivityText.pairDecided(PairDecidedEvent(requestId: "pr_1", state: .denied), deviceName: "내 iPhone") == "내 iPhone 페어링을 거부했습니다.")
        for state in [PairState.approved, .denied, .expired, .pending] {
            let text = ActivityText.pairDecided(PairDecidedEvent(requestId: "pr_1", state: state), deviceName: nil)
            #expect(!text.contains("승인") && !text.contains("거절"), "\(text)")
        }
    }

    // MARK: 페어링 가능 여부 (MACUI-3)

    @Test func pairingIsOfferedOnlyWhenTheHostIsReachable() async throws {
        let h = try makeHarness("pairing-ready")
        #expect(h.model.pairingAvailability != .ready)

        let cases: [(CoreStatus, Bool)] = [
            (CoreStatus(backendState: .needsLogin, authURL: "https://login.example.com/a/1", hostname: "rd-mac-ab12cd34"), false),
            (CoreStatus(backendState: .needsMachineAuth, hostname: "rd-mac-ab12cd34"), false),
            (CoreStatus(backendState: .running, hostname: "h", fqdn: "h.example.ts.net", certDomains: [], listening: false), false),
            (CoreStatus(backendState: .running, hostname: "h", fqdn: "h.example.ts.net", certDomains: ["h.example.ts.net"],
                        tlsReady: false, listening: false), false),
            (CoreStatus(backendState: .running, hostname: "h", fqdn: "", certDomains: ["x"], tlsReady: true, listening: true), false),
            (CoreStatus(backendState: .running, hostname: "h", fqdn: "h.example.ts.net", certDomains: ["h.example.ts.net"],
                        tlsReady: true, listening: true), true),
        ]
        for (status, ready) in cases {
            h.core.state.withLock { $0.status = status }
            if !h.model.isRunning { await h.model.start() }
            await h.model.refreshStatus()
            #expect((h.model.pairingAvailability == .ready) == ready, "\(status.backendState) fqdn=\(status.fqdn) tls=\(status.tlsReady)")
            if !ready {
                let before = h.core.calls.filter { if case .openPairing = $0 { true } else { false } }.count
                await h.model.beginPairing()
                #expect(h.model.pairingCode == nil)
                #expect(h.model.lastError?.isEmpty == false)
                let after = h.core.calls.filter { if case .openPairing = $0 { true } else { false } }.count
                #expect(before == after, "닿을 수 없는데 코드를 열었다")
                h.model.lastError = nil
            }
        }
        await h.model.beginPairing()
        #expect(h.model.pairingCode != nil)
        await h.model.shutdown()
    }

    @Test func loopbackTestControlServerIsReadyWithoutCertificates() async throws {
        let h = try makeHarness("pairing-loopback")
        h.model.controlURL = "http://127.0.0.1:9911"
        h.core.state.withLock {
            $0.status = CoreStatus(backendState: .running, hostname: "h", fqdn: "h.fake.ts.net", certDomains: [], listening: true)
        }
        await h.model.start()
        #expect(h.model.guidance.kind == .ready)
        #expect(h.model.pairingAvailability == .ready)
        await h.model.shutdown()
    }

    // MARK: 저장 폴더 문제 (IMP2-1)

    /// 백업 제외 실패는 한 번만 알리고 공유·가져오기를 막지 않는다.
    @Test func backupExclusionFailureWarnsOnceAndDoesNotBlock() async throws {
        let h = try makeHarness("backup-warning", prepare: { try writeReadOnlyIdentity(at: $0) })
        await h.model.load()
        let warning = try #require(h.model.lastError)
        #expect(warning.contains("백업에서 빼지 못했습니다"))
        #expect(warning.contains(h.paths.identityFile.path))

        h.model.lastError = nil
        let app = try makeImportableApp(in: h.tmp.path("src"), name: "Good")
        guard case .accepted = await h.model.importBuild(app) else { Issue.record("수락돼야 함: \(h.model.lastError ?? "")"); return }
        await h.model.load()
        #expect(h.model.lastError == nil, "같은 안내를 다시 보였다")
        await h.model.start()
        #expect(h.model.isRunning)
        #expect(h.model.lastError == nil)
        await h.model.shutdown()
    }

    /// 지난 시도의 백업 경고가 남지 않는다(LOAD3-1): 목록을 읽지 못한 시도와 권한을 고친 뒤의 시도가 이어질 때,
    /// 다시 읽어 전부 백업에서 뺐으면 경고 없이 로드된다.
    @Test func staleBackupWarningIsDroppedWhenTheRetryExcludesEverything() async throws {
        let h = try makeHarness("backup-warning-stale", prepare: {
            try writeReadOnlyIdentity(at: $0)
            try Data("{not json".utf8).write(to: $0.buildsFile)
        })
        await h.model.load()
        let first = try #require(h.model.lastError)
        #expect(first.contains(h.paths.buildsFile.path), "목록을 읽지 못했다는 안내가 먼저 보여야 함: \(first)")

        // 권한과 목록을 고친 뒤 다시 읽는다.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: h.paths.identityFile.path)
        try JSONFile<BuildLibrary.Index>(url: h.paths.buildsFile).save(BuildLibrary.Index(builds: []))
        h.model.lastError = nil
        await h.model.load()
        #expect(h.model.lastError == nil, "지난 시도의 백업 경고가 남았다: \(h.model.lastError ?? "")")
        #expect(HostPaths.isExcludedFromBackup(h.paths.identityFile))
    }

    /// 가져오기가 거절돼도 어떤 파일을 왜 읽지 못했는지와 실제로 도움이 되는 행동을 보여 준다.
    @Test func importKeepsTheLoadErrorThatNamesTheFile() async throws {
        let h = try makeHarness("import-bad-index", prepare: { try Data("{not json".utf8).write(to: $0.buildsFile) })
        let app = try makeImportableApp(in: h.tmp.path("src"), name: "Good")
        #expect(await h.model.importBuild(app) == nil)
        let message = try #require(h.model.lastError)
        #expect(message.contains(h.paths.buildsFile.path), "\(message)")
        #expect(message.contains("빌드를 다시 가져오세요"), "\(message)")
        #expect(!message.contains("앱을 다시 실행"), "\(message)")
        #expect(BuildLibraryError.notLoaded.localizedDescription.contains("다시 가져오세요"))
        #expect(!BuildLibraryError.notLoaded.localizedDescription.contains("앱을 다시 실행"))

        // 안내대로 파일을 복구하고 다시 가져오면 된다.
        try JSONFile<BuildLibrary.Index>(url: h.paths.buildsFile).save(BuildLibrary.Index(builds: []))
        guard case .accepted = await h.model.importBuild(app) else { Issue.record("수락돼야 함: \(h.model.lastError ?? "")"); return }
    }

    // MARK: 감시 폴더 문제 (MACUI-5)

    @Test func removedWatchedFolderIsReportedAndRecovers() async throws {
        let h = try makeHarness("watch-gone")
        let folder = h.tmp.path("Builds")
        try makeImportableApp(in: folder.appendingPathComponent("Debug-iphoneos"), name: "Watched")
        await h.model.chooseFolder(folder)
        #expect(h.model.watchProblem == nil)
        #expect(h.model.builds.count == 1)

        try FileManager.default.removeItem(at: folder)
        await h.model.rescan()
        let problem = try #require(h.model.watchProblem)
        #expect(problem.path == folder.path)
        #expect(problem.message.contains("다시 고르세요"))
        #expect(h.model.watchedFolder == folder, "감시 중인 폴더는 그대로 보여 준다")

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await h.model.rescan()
        #expect(h.model.watchProblem == nil)

        await h.model.forgetFolder()
        #expect(h.model.watchProblem == nil)
        #expect(h.model.watchedFolder == nil)
    }

    final class StaleBookmarks: FolderBookmarking {
        let cleared = Mutex(false)
        func save(_ url: URL) throws {}
        func resolve() -> URL? { nil }
        func clear() { cleared.withLock { $0 = true } }
        func savedFolder() -> SavedFolder { cleared.withLock { $0 } ? .none : .unresolvable(path: "/Users/me/DerivedData/Products") }
    }

    @Test func savedFolderThatCannotBeResolvedIsReportedNotDropped() async throws {
        let bookmarks = StaleBookmarks()
        let h = try makeHarness("watch-stale", bookmarks: bookmarks)
        await h.model.load()
        await h.model.waitForFolderResume()
        let problem = try #require(h.model.watchProblem)
        #expect(problem.path == "/Users/me/DerivedData/Products")
        #expect(h.model.watchedFolder == nil)

        await h.model.forgetFolder()
        #expect(bookmarks.cleared.withLock { $0 })
        #expect(h.model.watchProblem == nil)
    }

    @Test func userDefaultsBookmarksReportUnresolvableData() throws {
        let defaults = InMemoryDefaults()
        let store = UserDefaultsFolderBookmarks(defaults: defaults, key: "k", securityScoped: false)
        #expect(store.savedFolder() == .none)

        let tmp = try TempDir("bookmark")
        let folder = tmp.path("Watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.save(folder)
        guard case .folder(let url) = store.savedFolder() else {
            Issue.record("저장한 폴더를 풀지 못했다")
            return
        }
        #expect(url.standardizedFileURL.path == folder.standardizedFileURL.path)

        defaults.set(Data("not a bookmark".utf8), forKey: "k")
        guard case .unresolvable = store.savedFolder() else {
            Issue.record("풀 수 없는 북마크를 없는 것으로 봤다")
            return
        }
        #expect(store.resolve() == nil)
    }
}
