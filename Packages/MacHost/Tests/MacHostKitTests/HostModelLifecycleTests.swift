import Foundation
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

extension HostModelTests {
    /// 저장된 빌드 하나를 만들어 둔다(공유 시작 때 게시되는지 보려고).
    func addSavedBuild(_ h: Harness) async throws -> String {
        await h.model.load()
        guard case .accepted(let b) = await h.model.importBuild(try makeImportableApp(in: h.tmp.path("src"), name: "Saved")) else {
            throw FakeError()
        }
        return b.id
    }

    // MARK: 수명 주기

    @Test(arguments: [false, true])
    func stopDuringStartEndsStopped(viaShutdown: Bool) async throws {
        let h = try makeHarness("stop-during-start")
        _ = try await addSavedBuild(h)
        let gate = Gate()
        h.core.state.withLock { $0.startGates = [gate] }
        let starting = Task { await h.model.start() }
        #expect(await eventually { await gate.arrivals == 1 })
        #expect(h.model.isStarting)
        #expect(h.model.guidance.kind == .starting)

        let stopping = Task { viaShutdown ? await h.model.shutdown() : await h.model.stop() }
        #expect(await eventually { !h.model.isStarting })
        await gate.open()
        await starting.value
        await stopping.value

        #expect(!h.model.isRunning)
        #expect(!h.model.isStarting)
        #expect(h.core.startConfigs.count == 1)
        #expect(h.core.stopCount == 1)
        #expect(h.core.calls.last == .stop)
        #expect(h.core.published.isEmpty)
        #expect(await h.model.library.isActive == false)
        #expect(h.model.guidance.kind == .stopped)
    }

    @Test func secondStartWaitsForTheFirst() async throws {
        let h = try makeHarness("start-start")
        let gate = Gate()
        h.core.state.withLock { $0.startGates = [gate] }
        let first = Task { await h.model.start() }
        #expect(await eventually { await gate.arrivals == 1 })
        let second = Task { await h.model.start() }
        for _ in 0..<20 { await Task.yield() }
        await gate.open()
        await first.value
        await second.value
        #expect(h.core.startConfigs.count == 1)
        #expect(h.model.isRunning)
        #expect(!h.model.isStarting)
    }

    @Test func startStopStartEndsRunning() async throws {
        let h = try makeHarness("start-stop-start")
        let saved = try await addSavedBuild(h)
        let gate = Gate()
        h.core.state.withLock { $0.startGates = [gate] }
        let first = Task { await h.model.start() }
        #expect(await eventually { await gate.arrivals == 1 })
        let stopping = Task { await h.model.stop() }
        #expect(await eventually { !h.model.isStarting })
        let second = Task { await h.model.start() }
        #expect(await eventually { h.model.isStarting })
        await gate.open()
        await first.value
        await stopping.value
        await second.value

        #expect(h.model.isRunning)
        #expect(!h.model.isStarting)
        #expect(h.core.startConfigs.count == 2)
        #expect(h.core.stopCount == 1)
        #expect(h.core.published.map(\.build.id) == [saved])
        #expect(await h.model.library.isActive)
        let stopIndex = try #require(h.core.calls.firstIndex(of: .stop))
        let publishIndex = try #require(h.core.calls.firstIndex { if case .publish = $0 { true } else { false } })
        #expect(stopIndex < publishIndex)
    }

    @Test func startDoesNotWaitForWatchedFolderImport() async throws {
        let h = try makeHarness("bg-import")
        let folder = h.tmp.path("Builds")
        try makeImportableApp(in: folder.appendingPathComponent("Debug-iphoneos"), name: "Watched")
        try h.bookmarks.save(folder)
        let gate = Gate()
        h.inspector.hooks.withLock { $0.gate = gate }

        let starting = Task { await h.model.start() }
        #expect(await eventually { h.model.isRunning && !h.model.isStarting })
        #expect(h.core.startConfigs.count == 1)
        #expect(await eventually { await gate.arrivals == 1 })  // 가져오기는 아직 검사 중
        #expect(h.core.published.isEmpty)

        await gate.open()
        await starting.value
        await h.model.waitForFolderResume()
        #expect(await eventually { h.core.published.count == 1 })
        #expect(h.model.builds.count == 1)
        #expect(h.model.watchedFolder == folder)
    }

    @Test func importAfterStopIsPublishedOnNextStart() async throws {
        let h = try makeHarness("stop-import")
        await h.model.start()
        await h.model.stop()
        #expect(await h.model.library.isActive == false)
        guard case .accepted(let b) = await h.model.importBuild(try makeImportableApp(in: h.tmp.path("src"), name: "Later")) else {
            Issue.record("수락돼야 함"); return
        }
        #expect(h.core.published.isEmpty)
        #expect(h.model.builds.map(\.id) == [b.id])
        await h.model.start()
        #expect(h.core.published.map(\.build.id) == [b.id])
    }

    @Test(arguments: [true, false])
    func stopMarksOpenSessionsFailed(coreSendsFailure: Bool) async throws {
        let h = try makeHarness("stop-sessions")
        await h.model.start()
        let s = SessionEvent(sessionId: "s_1", buildId: "b_1", nodeName: "rd-phone-1", state: .downloading, userAgent: "ua", bytesServed: 10)
        h.core.emit(.session(s))
        #expect(await eventually { h.model.activity.first?.text.contains("내려받는 중") == true })
        if coreSendsFailure {
            var failed = s
            failed.state = .failed
            h.core.state.withLock { $0.stopEvents = [.session(failed)] }
        }
        await h.model.stop()
        #expect(h.model.activity.count == 1)
        #expect(h.model.activity.first?.text.hasSuffix("실패") == true)
    }

    @Test func republishFailureIsReportedAndKept() async throws {
        let h = try makeHarness("restore-fail")
        let saved = try await addSavedBuild(h)
        h.core.state.withLock { $0.failPublish = true }
        await h.model.start()
        #expect(h.model.isRunning)
        #expect(h.model.lastError?.contains("다시 게시하지 못했습니다") == true)
        #expect(h.model.lastError?.contains("사본을 만들지 못했습니다") == true)
        #expect(h.model.builds.map(\.id) == [saved])
    }

    // MARK: 저장된 목록을 읽지 못했을 때 (SBX-1)

    @Test func startIsRefusedWhenTheIndexCannotBeRead() async throws {
        let bad = Data("{not json".utf8)
        let h = try makeHarness("bad-index", prepare: { paths in
            try bad.write(to: paths.buildsFile)
            try Data("ipa".utf8).write(to: paths.ipaURL(forBuildID: "b_keepme"))
        })
        await h.model.load()
        #expect(h.model.lastError?.contains("읽지 못했습니다") == true)
        await h.model.start()
        #expect(h.model.lastError?.contains("읽지 못했습니다") == true, "\(h.model.lastError ?? "")")
        #expect(!h.model.isRunning)
        #expect(!h.model.isStarting)
        #expect(h.core.startConfigs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.paths.ipaURL(forBuildID: "b_keepme").path))
        #expect(try Data(contentsOf: h.paths.buildsFile) == bad)

        // 파일을 복구하면 다음 시작 때 다시 읽고 시작한다.
        try JSONFile<BuildLibrary.Index>(url: h.paths.buildsFile).save(BuildLibrary.Index(builds: []))
        await h.model.start()
        #expect(h.model.isRunning)
        #expect(h.core.startConfigs.count == 1)
        await h.model.shutdown()
    }

    @Test func startIsRefusedWhenPrepareFails() async throws {
        let index = Data(#"{"builds":[]}"#.utf8)
        let h = try makeHarness("bad-prepare", prepare: { paths in
            try index.write(to: paths.buildsFile)
            try Data("ipa".utf8).write(to: paths.ipaURL(forBuildID: "b_keepme"))
        })
        // state 폴더 자리를 일반 파일이 막고 있어 prepare가 실패한다.
        try FileManager.default.removeItem(at: h.paths.stateDir)
        try Data("not a folder".utf8).write(to: h.paths.stateDir)

        await h.model.start()
        #expect(h.model.lastError?.contains("저장 폴더를 준비하지 못했습니다") == true, "\(h.model.lastError ?? "")")
        #expect(!h.model.isRunning)
        #expect(h.core.startConfigs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.paths.ipaURL(forBuildID: "b_keepme").path))
        #expect(try Data(contentsOf: h.paths.buildsFile) == index)
    }

    @Test func startIsRefusedWhenSavedDevicesCannotBeRead() async throws {
        let bad = Data("{not json".utf8)
        let h = try makeHarness("bad-devices", prepare: { try bad.write(to: $0.devicesFile) })
        await h.model.start()
        #expect(!h.model.isRunning)
        #expect(h.core.startConfigs.isEmpty)
        #expect(h.model.lastError?.contains("기기 목록") == true)
        #expect(try Data(contentsOf: h.paths.devicesFile) == bad)
    }

    // MARK: 불러오기 한 번만 (LC2-RECHECK-2, LC-R2)

    /// Work 폴더에 남은 파일을 지우는 동안 두 번째 호출이 먼저 돌아오면 안 된다.
    @Test func concurrentLoadsShareOneReadAndWaitForIt() async throws {
        let saved = [sampleDevice(1)]
        let h = try makeHarness("load-twice", prepare: { paths in
            try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: saved))
            for i in 0..<400 { try Data().write(to: paths.workDir.appendingPathComponent("left-\(i)")) }
        })
        let first = Task { await h.model.load() }
        await Task.yield()
        await h.model.load()
        #expect(h.model.devices == saved, "두 번째 호출이 읽기가 끝나기 전에 돌아왔다")
        await first.value
    }

    /// 동시에 불러도 읽기는 한 번이다(TQ2-6). 불러오기가 끝날 때마다 저장된 폴더를 한 번 읽으므로 그 횟수로 센다.
    @Test func concurrentLoadsRunExactlyOneRead() async throws {
        let h = try makeHarness("load-once")
        let first = Task { await h.model.load() }
        let second = Task { await h.model.load() }
        await first.value
        await second.value
        await h.model.waitForFolderResume()
        #expect(h.bookmarks.resolveCount.withLock { $0 } == 1)
    }

    /// 읽지 못한 결과를 기억하지 않는다. 파일을 복구하면 다음 호출이 읽는다.
    @Test func failedLoadIsNotCached() async throws {
        let saved = [sampleDevice(1)]
        let h = try makeHarness("load-retry", prepare: { try Data("{not json".utf8).write(to: $0.devicesFile) })
        await h.model.load()
        await h.model.waitForFolderResume()
        #expect(h.model.devices.isEmpty)
        #expect(h.model.lastError?.contains("기기 목록") == true)
        #expect(h.bookmarks.resolveCount.withLock { $0 } == 0, "읽지 못했는데 폴더 감시를 시작했다")

        try JSONFile<DeviceList>(url: h.paths.devicesFile).save(DeviceList(devices: saved))
        await h.model.load()
        await h.model.waitForFolderResume()
        #expect(h.model.devices == saved)
        #expect(h.bookmarks.resolveCount.withLock { $0 } == 1)
    }

    /// 다시 읽을 때는 읽지 못한 쪽만 읽는다. 빌드 쪽을 다시 돌면 막아 둔 state 폴더 때문에 실패한다(IMP2-2).
    @Test func retryReadsOnlyThePartThatFailed() async throws {
        let saved = [sampleDevice(1)]
        let h = try makeHarness("load-part", prepare: { try Data("{not json".utf8).write(to: $0.devicesFile) })
        await h.model.load()
        #expect(h.model.lastError?.contains("기기 목록") == true)

        try FileManager.default.removeItem(at: h.paths.stateDir)
        try Data("not a folder".utf8).write(to: h.paths.stateDir)
        try JSONFile<DeviceList>(url: h.paths.devicesFile).save(DeviceList(devices: saved))
        h.model.lastError = nil
        await h.model.load()
        #expect(h.model.lastError == nil, "\(h.model.lastError ?? "")")
        #expect(h.model.devices == saved)
    }

    /// 기기 목록을 읽지 못해도 뒤따른 가져오기가 앞선 가져오기의 임시 파일을 지우면 안 된다(IMP2-2).
    @Test(.timeLimit(.minutes(1)))
    func overlappingImportsKeepTheirTempFilesWhenDevicesCannotBeRead() async throws {
        let h = try makeHarness("reload-work", prepare: { try Data("{not json".utf8).write(to: $0.devicesFile) })
        let gate = Gate()
        h.inspector.hooks.withLock { $0.beforeIPA = { _ in await gate.wait() } }
        let first = try makeImportableApp(in: h.tmp.path("src"), name: "First", bundleId: "com.example.first")
        let second = try makeImportableApp(in: h.tmp.path("src"), name: "Second", bundleId: "com.example.second")
        func workFiles() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: h.paths.workDir.path) }

        let importingFirst = Task { await h.model.importBuild(first) }
        try #require(await eventually { await gate.arrivals == 1 })
        let temp = try workFiles()
        #expect(temp.count == 1)

        let importingSecond = Task { await h.model.importBuild(second) }
        try #require(await eventually { await h.model.library.waitingCount == 1 })  // 둘째가 불러오기를 마치고 줄을 섰다
        #expect(try workFiles() == temp, "가져오는 중인 임시 파일을 지웠다")

        await gate.open()
        guard case .accepted = await importingFirst.value else { Issue.record("첫 가져오기 실패: \(h.model.lastError ?? "")"); return }
        guard case .accepted = await importingSecond.value else { Issue.record("둘째 가져오기 실패: \(h.model.lastError ?? "")"); return }
        #expect(h.model.builds.count == 2)
        #expect(h.model.rejected.isEmpty)
    }

    @Test func startDuringLoadPushesTheSavedDevices() async throws {
        let saved = [sampleDevice(1), sampleDevice(2)]
        let h = try makeHarness("start-during-load", prepare: { paths in
            try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: saved))
            for i in 0..<400 { try Data().write(to: paths.workDir.appendingPathComponent("left-\(i)")) }
        })
        let loading = Task { await h.model.load() }
        await Task.yield()
        await h.model.start()
        await loading.value
        #expect(h.core.setDevicesCalls == [saved], "\(h.core.setDevicesCalls)")
        #expect(try JSONFile<DeviceList>(url: h.paths.devicesFile).load()?.devices == saved)
        await h.model.shutdown()
    }

    // MARK: 종료는 끝이다 (LC-R3)

    @Test func nothingStartsAfterShutdown() async throws {
        let h = try makeHarness("shutdown-final")
        let folder = h.tmp.path("Builds")
        try makeImportableApp(in: folder.appendingPathComponent("Debug-iphoneos"), name: "Watched")
        await h.model.load()
        await h.model.shutdown()

        await h.model.start()
        #expect(h.core.startConfigs.isEmpty)
        #expect(!h.model.isRunning)
        #expect(!h.model.isStarting)

        await h.model.chooseFolder(folder)
        #expect(h.model.watchedFolder == nil)
        #expect(h.inspector.count == 0)
        #expect(h.bookmarks.resolve() == nil)

        let app = try makeImportableApp(in: h.tmp.path("src"), name: "Late")
        #expect(await h.model.importBuild(app) == nil)
        #expect(h.model.builds.isEmpty)
    }

    @Test func savedFolderIsNotResumedWhenShutdownLandsDuringLoad() async throws {
        let h = try makeHarness("shutdown-during-load", prepare: { paths in
            for i in 0..<400 { try Data().write(to: paths.workDir.appendingPathComponent("left-\(i)")) }
        })
        let folder = h.tmp.path("Builds")
        try makeImportableApp(in: folder.appendingPathComponent("Debug-iphoneos"), name: "Watched")
        try h.bookmarks.save(folder)

        let launch = Task {
            await h.model.load()
            await h.model.start()
        }
        await Task.yield()
        await h.model.shutdown()
        await launch.value
        await h.model.waitForFolderResume()

        #expect(h.core.startConfigs.isEmpty)
        #expect(h.model.watchedFolder == nil)
        #expect(h.inspector.count == 0)
    }

    /// 폴더를 바꾸는 도중 종료가 끼어들면 새 폴더의 감시를 시작하지 않는다.
    @Test func folderChangeInFlightDoesNotStartWatchingAfterShutdown() async throws {
        let h = try makeHarness("shutdown-during-choose")
        let first = h.tmp.path("First")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = h.tmp.path("Second")
        try makeImportableApp(in: second.appendingPathComponent("Debug-iphoneos"), name: "Watched")
        await h.model.chooseFolder(first)
        #expect(h.model.watchedFolder == first)

        let choosing = Task { await h.model.chooseFolder(second) }
        await Task.yield()
        await h.model.shutdown()
        await choosing.value

        #expect(h.model.watchedFolder == nil)
        #expect(h.inspector.count == 0)
    }

    // MARK: 종료 순서 (LC-R1)

    @Test func secondTerminateDuringShutdownKeepsWaiting() async throws {
        let sequence = TerminationSequence()
        let gate = Gate()
        let shutdowns = Mutex(0)
        let finishes = Mutex(0)
        let shutdown: @MainActor () async -> Void = {
            shutdowns.withLock { $0 += 1 }
            await gate.wait()
        }
        let finish: @MainActor () -> Void = { finishes.withLock { $0 += 1 } }

        #expect(sequence.request(shutdown: shutdown, finish: finish) == .later)
        #expect(await eventually { await gate.arrivals == 1 })
        #expect(sequence.request(shutdown: shutdown, finish: finish) == .later, "정리 중에는 끝내면 안 된다")
        #expect(sequence.phase == .shuttingDown)
        #expect(finishes.withLock { $0 } == 0)

        await gate.open()
        #expect(await eventually { sequence.phase == .finished })
        #expect(shutdowns.withLock { $0 } == 1)
        #expect(finishes.withLock { $0 } == 1)
        #expect(sequence.request(shutdown: shutdown, finish: finish) == .now)
        #expect(finishes.withLock { $0 } == 1)
    }

    // MARK: 기기를 허용한 코어의 제어 서버 (LC2-RECHECK-1)

    @Test func decisionThatLandsAfterTheServerChangedIsNotStored() async throws {
        let h = try makeHarness("decide-url-change")
        h.model.controlURL = "https://headscale-a.example.com"
        await h.model.start()
        receive(h, pairRequest("pr_1"))
        let gate = Gate()
        h.core.state.withLock { $0.decideGates = [gate] }
        let approving = Task { await h.model.approve("pr_1") }
        #expect(await eventually { await gate.arrivals == 1 })

        await h.model.stop()
        #expect(h.model.applyControlURL("https://headscale-b.example.com", forgetOtherServerDevices: true))
        await gate.open()
        await approving.value

        #expect(h.model.devices.isEmpty, "다른 서버의 기기를 저장했다")
        #expect(h.model.lastError?.contains("제어 서버가 바뀌어") == true)
        #expect(h.model.lastPairingOutcome == PairingOutcome(requestId: "pr_1", kind: .notAdded))
        let stored = try JSONFile<StoredDeviceList>(url: h.paths.devicesFile).load()
        #expect(stored?.devices.isEmpty ?? true)

        await h.model.start()
        #expect(h.core.setDevicesCalls.last == [], "\(h.core.setDevicesCalls)")
        await h.model.shutdown()
    }

    @Test func deviceIsBoundToTheCoreThatApprovedIt() async throws {
        let h = try makeHarness("decide-bound")
        h.model.controlURL = "https://headscale-a.example.com"
        await h.model.start()
        receive(h, pairRequest("pr_1"))
        await h.model.approve("pr_1")
        #expect(try JSONFile<StoredDeviceList>(url: h.paths.devicesFile).load()?.controlURL == "https://headscale-a.example.com")
        #expect(h.model.lastPairingOutcome == PairingOutcome(requestId: "pr_1", kind: .allowed))

        // 코어 이벤트도 같다: 코어가 시작할 때의 서버와 지금 설정이 다르면 넣지 않는다.
        h.model.controlURL = "https://headscale-b.example.com"
        h.model.handle(.deviceAdded(sampleDevice(2)))
        #expect(h.model.devices == [sampleDevice(1)])
        await h.model.shutdown()
    }

    @Test func denyOfAnAlreadyPairedDeviceReportsDenied() async throws {
        let h = try makeHarness("deny-paired", prepare: { paths in
            try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: [sampleDevice(1)]))
        })
        await h.model.start()
        receive(h, pairRequest("pr_1"))
        await h.model.deny("pr_1")
        #expect(h.model.lastPairingOutcome == PairingOutcome(requestId: "pr_1", kind: .denied))
        h.core.emit(.pairDecided(PairDecidedEvent(requestId: "pr_1", state: .denied)))
        #expect(await eventually { !h.model.activity.isEmpty })
        #expect(h.model.lastPairingOutcome?.kind == .denied)
        await h.model.shutdown()
    }

    // MARK: 기기

    @Test func removeDeviceKeepsDeviceWhenCoreFails() async throws {
        let h = try makeHarness("remove-fail", prepare: { paths in
            try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: [sampleDevice(1), sampleDevice(2)]))
        })
        await h.model.start()
        h.core.state.withLock { $0.failSetDevices = true }
        await h.model.removeDevice("d_1")
        #expect(h.model.devices == [sampleDevice(1), sampleDevice(2)])
        #expect(try JSONFile<DeviceList>(url: h.paths.devicesFile).load()?.devices == [sampleDevice(1), sampleDevice(2)])
        #expect(h.model.lastError?.contains("다시 시도") == true)

        h.core.state.withLock { $0.failSetDevices = false }
        await h.model.removeDevice("d_1")
        #expect(h.model.devices == [sampleDevice(2)])
    }

    @Test func allowListUpdatesReachCoreInOrder() async throws {
        let h = try makeHarness("devices-order", prepare: { paths in
            try JSONFile<DeviceList>(url: paths.devicesFile).save(DeviceList(devices: [sampleDevice(1), sampleDevice(2), sampleDevice(3)]))
        })
        await h.model.start()
        // 첫 호출이 늦게 끝나도 두 번째가 먼저 적용되면 안 된다.
        h.core.state.withLock { $0.setDevicesDelays = [.milliseconds(150), .zero] }
        let a = Task { await h.model.removeDevice("d_1") }
        let b = Task { await h.model.removeDevice("d_2") }
        await a.value
        await b.value
        let applied = h.core.state.withLock { $0.appliedDevices }
        #expect(applied.suffix(2) == [[sampleDevice(2), sampleDevice(3)], [sampleDevice(3)]])
        #expect(h.model.devices == [sampleDevice(3)])
    }

    // MARK: 페어링

    @Test func pairingCodeDecodesCoreJSON() throws {
        let json = #"{"code":"K7M29QXD","expiresAt":"2026-11-11T09:07:00Z"}"#
        let code = try RDJSON.decoder().decode(PairingCode.self, from: Data(json.utf8))
        #expect(code.code == "K7M29QXD")
        #expect(code.displayCode == "K7M2-9QXD")
        #expect(code.expiresAt == RDTimestamp.parse("2026-11-11T09:07:00Z"))
        let again = try RDJSON.decoder().decode(PairingCode.self, from: RDJSON.encoder().encode(code))
        #expect(again == code)
        let fractional = #"{"code":"K7M29QXD","expiresAt":"2026-11-11T09:07:00.123456789Z"}"#
        #expect(try RDJSON.decoder().decode(PairingCode.self, from: Data(fractional.utf8)).expiresAt > code.expiresAt)
    }

    @Test func burnedOrExpiredCodeIsCleared() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_900_000_000))
        let h = try makeHarness("burn", clock: { clock.withLock { $0 } })
        let t0 = clock.withLock { $0 }
        h.core.state.withLock { $0.pairing = PairingCode(code: "K7M29QXD", expiresAt: t0.addingTimeInterval(300)) }
        await h.model.start()

        await h.model.beginPairing()
        #expect(h.model.pairingCode != nil)
        h.model.handle(.denied(DeniedEvent(path: "/v1/pair/request", reason: "too_many_attempts", nodeName: "rd-phone-9")))
        #expect(h.model.pairingState == .idle)
        #expect(h.model.pairingLink == nil)

        await h.model.beginPairing()
        for _ in 0..<2 { h.model.handle(.denied(DeniedEvent(path: "/v1/pair/request", reason: "pair_code_invalid"))) }
        h.model.handle(.denied(DeniedEvent(path: "/v1/pair/request", reason: "pair_code_invalid", suppressed: 1)))
        #expect(h.model.pairingCode != nil)  // 4번 틀림
        h.model.handle(.denied(DeniedEvent(path: "/v1/pair/request", reason: "pair_code_invalid")))
        #expect(h.model.pairingState == .idle)  // 5번째에 코어가 폐기한다

        await h.model.beginPairing()
        #expect(h.model.pairingCode != nil)
        clock.withLock { $0 = $0.addingTimeInterval(301) }
        #expect(h.model.pairingCode == nil)
        h.model.pruneExpiredPairRequests()
        #expect(h.model.pairingState == .idle)
    }

    @Test func pairDecidedActivityShowsDeviceName() async throws {
        let h = try makeHarness("decided-name")
        await h.model.start()
        await h.model.beginPairing()
        h.core.emit(.pairRequest(pairRequest("pr_7c1e55d0", deviceName: "디자인팀 iPhone")))
        #expect(await eventually { !h.model.pendingPairRequests.isEmpty })
        await h.model.approve("pr_7c1e55d0")
        h.core.emit(.deviceAdded(sampleDevice(1)))
        h.core.emit(.pairDecided(PairDecidedEvent(requestId: "pr_7c1e55d0", state: .approved)))
        #expect(await eventually { h.model.activity.contains { $0.text == "디자인팀 iPhone 페어링을 허용했습니다." } })
        #expect(!h.model.activity.contains { $0.text.contains("pr_7c1e55d0") })
    }

    @Test func secondDecisionForSameRequestIsNoop() async throws {
        let h = try makeHarness("double-approve")
        await h.model.start()
        receive(h, pairRequest("pr_1"))
        let a = Task { await h.model.approve("pr_1") }
        let b = Task { await h.model.approve("pr_1") }
        await a.value
        await b.value
        await h.model.deny("pr_1")
        #expect(h.core.decideCalls == ["pr_1"])
        #expect(h.model.lastError == nil)
        #expect(h.model.devices == [sampleDevice(1)])
    }

    @Test func unknownRequestIsNotSentToCore() async throws {
        let h = try makeHarness("unknown-request")
        await h.model.start()
        await h.model.approve("pr_never_seen")
        #expect(h.core.decideCalls.isEmpty)
        #expect(h.model.devices.isEmpty)
        #expect(h.model.lastError != nil)
    }

    // MARK: 로그인·루프백·안내문

    @Test func loginPageOpensHTTPSOnly() async throws {
        #expect(HostModel.loginURL("https://login.tailscale.com/a/abc", controlURL: "") != nil)
        #expect(HostModel.loginURL("http://login.example.com/a", controlURL: "") == nil)
        #expect(HostModel.loginURL("https:foo", controlURL: "") == nil)
        #expect(HostModel.loginURL("javascript:alert(1)", controlURL: "") == nil)
        #expect(HostModel.loginURL("http://127.0.0.1:9911/a/1", controlURL: "http://127.0.0.1:9911") != nil)
        #expect(HostModel.loginURL("http://127.0.0.1:9911/a/1", controlURL: "") == nil)
        #expect(HostModel.loginURL("http://evil.example/a", controlURL: "http://127.0.0.1:9911") == nil)

        let h = try makeHarness("login-http")
        await h.model.start()
        h.model.handle(.state(CoreStatus(backendState: .needsLogin, authURL: "http://login.example.com/a/1")))
        h.model.openLoginPage()
        #expect(h.opened.urls.withLock { $0 }.isEmpty)
        #expect(h.model.lastError != nil)
    }

    @Test func loopbackMatchesCore() {
        #expect(HostModel.isLoopbackHost(of: "http://LOCALHOST:8080"))
        #expect(HostModel.isLoopbackHost(of: "http://127.0.0.1:9911"))
        #expect(HostModel.isLoopbackHost(of: "http://127.255.255.254"))
        #expect(HostModel.isLoopbackHost(of: "http://[::1]:80"))
        #expect(HostModel.isLoopbackHost(of: "http://[0:0:0:0:0:0:0:1]"))
        #expect(HostModel.isLoopbackHost(of: "http://[::ffff:127.0.0.1]:9911"))
        #expect(!HostModel.isLoopbackHost(of: "http://127.000.000.001:9911"))  // Go ParseIP는 앞자리 0을 거부한다
        #expect(!HostModel.isLoopbackHost(of: "http://[::ffff:127.000.0.1]"))
        #expect(!HostModel.isLoopbackHost(of: "http://127.1"))
        #expect(!HostModel.isLoopbackHost(of: "http://[::2]"))
        #expect(!HostModel.isLoopbackHost(of: "http://[::ffff:10.0.0.1]"))
        #expect(!HostModel.isLoopbackHost(of: "http://128.0.0.1"))
        #expect(!HostModel.isLoopbackHost(of: "http://localhost.example.com"))
    }

    @Test func listenerErrorsMapToSettingsHint() {
        let https = StatusGuidance.make(for: CoreStatus(
            backendState: .error, fqdn: "x.ts.net", certDomains: [],
            errorMessage: "host listener: HTTPS 인증서가 꺼져 있습니다(관리 콘솔에서 HTTPS를 켜야 합니다)"))
        #expect(https.kind == .certificatesDisabled)
        #expect(https.action == nil)
        #expect(https.message.contains("login.tailscale.com/admin/dns"))
        #expect(https.message.contains("HTTPS Certificates"))

        let dns = StatusGuidance.make(for: CoreStatus(
            backendState: .error, errorMessage: "host listener: MagicDNS가 꺼져 있습니다(관리 콘솔 DNS 페이지에서 켜야 합니다)"))
        #expect(dns.kind == .magicDNSDisabled)
        #expect(dns.message.contains("MagicDNS"))
        #expect(dns.message.contains("login.tailscale.com/admin/dns"))

        let port = StatusGuidance.make(for: CoreStatus(
            backendState: .error, certDomains: ["x.ts.net"], errorMessage: "host listener: listen tcp :443: address already in use"))
        #expect(port.kind == .error)
        #expect(port.action == .restart)
        #expect(port.message.contains("address already in use"))
    }

    @Test func copyCarriesFactsNotCodes() {
        let starting = StatusGuidance.startingGuidance
        #expect(!starting.message.isEmpty)
        #expect(!starting.message.contains(starting.title))
        #expect(StatusGuidance.make(for: nil).title.contains("공유"))
        #expect(StatusGuidance.make(for: CoreStatus(backendState: .running, fqdn: "x.ts.net", certDomains: ["x.ts.net"], tlsReady: true)).title == "공유 중")
        for code in ["not_paired", "pair_code_invalid", "token_invalid", "too_many_attempts", "session_expired", "build_not_found", "build_changed"] {
            let text = ActivityText.denied(DeniedEvent(path: "/v1/info", reason: code, nodeName: "rd-phone-1"))
            #expect(!text.contains(code), "코드가 그대로 보임: \(text)")
            #expect(text.hasSuffix("."))
        }
        #expect(ActivityText.denied(DeniedEvent(path: "/v1/pair/request", reason: "too_many_attempts")).contains("새 코드"))
        #expect(HostErrorText.message(for: CancellationError()) == "작업을 취소했습니다.")
        #expect(!HostErrorText.message(for: FakeError()).contains("FakeError()"))
    }

    // MARK: 감시 폴더

    @Test func unpublishedWatchedBuildIsNotReimportedAfterRestart() async throws {
        let h = try makeHarness("watch-restart")
        let folder = h.tmp.path("Builds")
        let app = try makeImportableApp(in: folder.appendingPathComponent("Debug-iphoneos"), name: "Watched")
        await h.model.start()
        await h.model.chooseFolder(folder)
        let id = try #require(h.model.builds.first?.id)
        await h.model.unpublish(id)
        #expect(h.model.builds.isEmpty)
        await h.model.shutdown()

        let core = FakeHostCore()
        let inspector = FakeInspector()
        let model = HostModel(core: core, paths: h.paths, inspector: inspector, packager: FakePackager(), bookmarks: h.bookmarks,
                              watcherOptions: .init(useFileEvents: false), id8: "ab12cd34", hostDisplayName: "Mac", appVersion: "0.1.0",
                              openURL: { _ in })
        await model.start()
        await model.waitForFolderResume()
        #expect(model.watchedFolder == folder)
        #expect(model.builds.isEmpty)
        #expect(inspector.count == 0)
        #expect(core.published.isEmpty)

        // 다시 빌드하면(지문이 바뀌면) 가져온다.
        try Data("rebuilt-binary-with-new-size".utf8).write(to: app.appendingPathComponent("App"))
        await model.rescan()
        #expect(model.builds.count == 1)
        #expect(core.published.count == 1)
        await model.shutdown()
    }
}
