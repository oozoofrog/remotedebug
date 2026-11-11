import AppKit
import Foundation
@testable import MacHostKit
import RDModels
import Synchronization
import SwiftUI
import Testing
@testable import MacHostUI

/// 임시 폴더는 /Volumes/eyedisk/build 아래에 둔다(내장 디스크를 쓰지 않는다).
final class UITempDir: @unchecked Sendable {
    let url: URL

    init(_ label: String) throws {
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: env["RD_TEST_TMPDIR"] ?? "/Volumes/eyedisk/build/remotedebug/mac-host-tmp", isDirectory: true)
        url = base.appendingPathComponent("ui-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

struct NoScope: SecurityScoping {
    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

/// 테스트가 열 때까지 기다리게 하는 문.
actor UIGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// 코어 설정에 넘어온 인증 키를 기록한다.
final class RecordingCore: HostCore {
    private let keys = Mutex<[String]>([])
    /// `stop`을 이 문이 열릴 때까지 멈춘다.
    let stopGate = Mutex<UIGate?>(nil)
    /// 페어링 코드 만들기·요청 응답이 실패한다.
    let failPairing = Mutex(false)
    var startKeys: [String] { keys.withLock { $0 } }

    func start(_ config: CoreConfig) async throws { keys.withLock { $0.append(config.authKey) } }
    func stop() async { await stopGate.withLock { $0 }?.wait() }
    func status() async throws -> CoreStatus { CoreStatus(backendState: .needsLogin) }
    func publish(_ request: PublishRequest) async throws {}
    func unpublish(buildID: String) async throws {}
    func setDevices(_ devices: [DeviceEntry]) async throws {}
    func openPairing(ttlSeconds: Int) async throws -> PairingCode {
        if failPairing.withLock({ $0 }) { throw APIErrorBody(code: "internal", message: "코어 오류") }
        return PairingCode(code: "K7M29QXD", expiresAt: Date().addingTimeInterval(300))
    }

    func decidePairing(requestID: String, allow: Bool) async throws -> DeviceEntry? {
        if failPairing.withLock({ $0 }) { throw APIErrorBody(code: "internal", message: "코어 오류") }
        return nil
    }

    func events() -> AsyncStream<CoreEvent> { AsyncStream { $0.finish() } }
}

/// 화면과 HostModel의 연결(미리보기용 가짜 코어). 실제 코어·네트워크는 쓰지 않는다.
@MainActor
@Suite("화면", .serialized)
struct ScreenTests {
    func model(_ scenario: PreviewScenario, _ tmp: UITempDir) async -> HostModel {
        await PreviewFactory.makeModel(scenario, root: tmp.url.appendingPathComponent("host", isDirectory: true))
    }

    /// 화면을 그려 크래시 없이 뜨는지만 본다. 화면의 판단은 아래 테스트가 내용으로 확인한다.
    func render(_ model: HostModel, _ item: SidebarItem) {
        let host = NSHostingView(rootView: RootView(selection: item).environment(model))
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        host.layoutSubtreeIfNeeded()
    }

    @Test func sharingScenarioFeedsTheScreens() async throws {
        let tmp = try UITempDir("sharing")
        let model = await model(.sharing, tmp)
        #expect(model.isRunning)
        #expect(model.guidance.kind == .ready)
        #expect(model.pairingAvailability == .ready)
        #expect(model.builds.count == 2)
        #expect(model.devices.count == 1)
        let pending = try await waitForPending(model)
        #expect(pending.deviceName == "테스트 iPhone")
        #expect(PairRequestRow.sentence(pending) == "‘테스트 iPhone’(rd-phone-77aa01ef)이 페어링을 요청했습니다")

        for item in SidebarItem.allCases { render(model, item) }

        await model.approve(pending.requestId)
        #expect(model.pendingPairRequests.isEmpty)
        #expect(model.devices.count == 2)

        await model.shutdown()
        #expect(!model.isRunning)
        #expect(model.guidance.kind == .stopped)
    }

    @Test func everyScenarioRenders() async throws {
        let tmp = try UITempDir("all")
        for scenario in PreviewScenario.allCases {
            let model = await model(scenario, tmp)
            for item in SidebarItem.allCases { render(model, item) }
            await model.shutdown()
            let pairing = await PreviewFactory.makePairingModel(scenario, root: tmp.url.appendingPathComponent("pairing", isDirectory: true))
            let sheet = NSHostingView(rootView: PairingSheet().environment(pairing).environment(AuthKeyDraft()))
            sheet.frame = NSRect(x: 0, y: 0, width: 520, height: 720)
            sheet.layoutSubtreeIfNeeded()
            await pairing.shutdown()
        }
        let failure = NSHostingView(rootView: LaunchFailureView(failure: .alreadyRunning, switchToRunningApp: {}, quit: {}))
        failure.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        failure.layoutSubtreeIfNeeded()
        #expect(LaunchFailure.alreadyRunning.message.contains("이미 실행 중인 RemoteDebug가 같은 폴더를 쓰고 있습니다"))
        #expect(LaunchFailure.storageUnavailable("x").message.contains("다시 실행하세요"))
    }

    @Test func rejectedScenarioShowsKoreanReasons() async throws {
        let tmp = try UITempDir("rejected")
        let model = await model(.rejected, tmp)
        #expect(model.builds.isEmpty)
        #expect(model.rejected.count == 2)
        let messages = model.rejected.flatMap(\.messages)
        #expect(messages.contains(RejectionText.sentence(for: .init(code: .configurationNotDebug, detail: ""))))
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    @Test func guidanceScenarios() async throws {
        let tmp = try UITempDir("guidance")
        #expect(await model(.empty, tmp).guidance.kind == .stopped)
        let login = await model(.needsLogin, tmp)
        #expect(login.guidance.kind == .needsLogin)
        #expect(login.guidance.action == .openLoginPage)
        #expect(login.pairingAvailability != .ready)
        let certs = await model(.certificatesOff, tmp)
        #expect(certs.guidance.kind == .certificatesDisabled)
        #expect(certs.pairingAvailability != .ready)
        let failed = await model(.error, tmp)
        #expect(failed.guidance.kind == .error)
        #expect(failed.lastError != nil)
        let stale = await model(.watchProblem, tmp)
        #expect(stale.watchProblem != nil)
    }

    // MARK: 화면의 판단

    @Test func pairingNoticeShowsOutsideTheDevicesScreenAndSheet() async throws {
        let tmp = try UITempDir("notice")
        let model = await model(.sharing, tmp)
        let pending = try await waitForPending(model)
        #expect(RootView.noticeRequest(model: model, selection: .builds, showingPairing: false) == pending)
        #expect(RootView.noticeRequest(model: model, selection: .network, showingPairing: false) == pending)
        #expect(RootView.noticeRequest(model: model, selection: .devices, showingPairing: false) == nil, "기기 화면에는 목록이 있다")
        #expect(RootView.noticeRequest(model: model, selection: .builds, showingPairing: true) == nil, "시트가 열려 있으면 띄우지 않는다")
        await model.deny(pending.requestId)
        #expect(RootView.noticeRequest(model: model, selection: .builds, showingPairing: false) == nil)
        await model.shutdown()
    }

    @Test func announcementsCoverArrivalAndExpiryOnly() {
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        let live = PairRequestEvent(requestId: "pr_1", deviceName: "내 iPhone", nodeName: "rd-phone-1", loginName: "", expiresAt: t.addingTimeInterval(60))
        let gone = PairRequestEvent(requestId: "pr_2", deviceName: "", nodeName: "", loginName: "", expiresAt: t.addingTimeInterval(-1))
        let arrived = PairRequestAnnouncements.make(previous: [], current: [live], now: t)
        #expect(arrived == ["‘내 iPhone’(rd-phone-1)이 페어링을 요청했습니다. 만료되기 전에 기기 화면에서 허용하거나 거부하세요."])
        #expect(PairRequestAnnouncements.make(previous: [live], current: [live], now: t).isEmpty, "같은 요청을 다시 읽지 않는다")
        #expect(PairRequestAnnouncements.make(previous: [live], current: [], now: t).isEmpty, "만료 전에 처리한 요청은 만료로 읽지 않는다")
        #expect(PairRequestAnnouncements.make(previous: [gone], current: [], now: t)
                == ["이름 없는 기기의 페어링 요청이 만료됐습니다. iPhone에서 다시 요청하세요."])
    }

    @Test func keyFieldAndStartButtonFollowTheSharingState() async throws {
        let tmp = try UITempDir("keyfield")
        let expectations: [(PreviewScenario, Bool)] = [
            (.empty, true), (.needsLogin, true), (.error, true), (.sharing, false), (.certificatesOff, false),
        ]
        for (scenario, shows) in expectations {
            let model = await model(scenario, tmp)
            #expect(NetworkView.showsKeyField(model) == shows, "\(scenario)")
            await model.shutdown()
        }
        let stopped = await model(.empty, tmp)
        #expect(NetworkView.keyFieldActionTitle(stopped, draft: "tskey") == "공유 시작")
        let login = await model(.needsLogin, tmp)
        #expect(NetworkView.keyFieldActionTitle(login, draft: "") == "공유 다시 시작")
        #expect(NetworkView.keyFieldActionTitle(login, draft: "tskey") == "인증 키로 다시 시작")
        await login.shutdown()
    }

    /// 버튼을 누른 순간 입력한 키를 코어 설정으로 넘기고 입력란을 비운다.
    @Test(arguments: [false, true])
    func startActionsUseTheTypedKeyOnceAndClearIt(restart: Bool) async throws {
        let tmp = try UITempDir("startkey")
        let core = RecordingCore()
        let model = HostModel(core: core, paths: HostPaths(root: tmp.url.appendingPathComponent("host", isDirectory: true)),
                              bookmarks: NoFolderBookmarks(), watcherOptions: .init(useFileEvents: false), id8: "ab12cd34",
                              hostDisplayName: "Mac", appVersion: "0.1.0", openURL: { _ in })
        let draft = AuthKeyDraft()
        draft.value = "  tskey-auth-SECRET  "
        let task = restart ? SharingActions.restart(model, authKey: draft) : SharingActions.start(model, authKey: draft)
        #expect(draft.value.isEmpty, "버튼을 누른 즉시 입력란을 비운다")
        await task?.value
        #expect(core.startKeys == ["tskey-auth-SECRET"])
        await model.shutdown()
    }

    func makeRecordingModel(_ core: RecordingCore, _ tmp: UITempDir) -> HostModel {
        HostModel(core: core, paths: HostPaths(root: tmp.url.appendingPathComponent("host", isDirectory: true)),
                  bookmarks: NoFolderBookmarks(), watcherOptions: .init(useFileEvents: false), id8: "ab12cd34",
                  hostDisplayName: "Mac", appVersion: "0.1.0", openURL: { _ in })
    }

    /// 다시 시작이 코어를 멈추는 동안 온 클릭이 입력한 키를 버리면 안 된다(UI2-1).
    @Test(.timeLimit(.minutes(1)))
    func clicksDuringARestartDoNotDropTheTypedKey() async throws {
        let tmp = try UITempDir("restartkey")
        let core = RecordingCore()
        let model = makeRecordingModel(core, tmp)
        await model.start()
        let gate = UIGate()
        core.stopGate.withLock { $0 = gate }
        let draft = AuthKeyDraft()
        draft.value = "tskey-auth-NEW"

        let task = try #require(SharingActions.restart(model, authKey: draft))
        for _ in 0..<2000 where await gate.arrivals == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await gate.arrivals == 1)
        #expect(!model.isRunning && !model.isStarting, "공유 시작 버튼이 보이는 상태다")
        #expect(SharingActions.start(model, authKey: draft) == nil, "다시 시작하는 동안 시작을 받았다")
        #expect(SharingActions.restart(model, authKey: draft) == nil, "다시 시작하는 동안 또 다시 시작을 받았다")

        await gate.open()
        await task.value
        #expect(core.startKeys == ["", "tskey-auth-NEW"])
        #expect(!draft.isRestarting)
        core.stopGate.withLock { $0 = nil }
        await SharingActions.restart(model, authKey: draft)?.value
        #expect(core.startKeys == ["", "tskey-auth-NEW", ""], "끝난 뒤에는 다시 시작할 수 있다")
        await model.shutdown()
    }

    /// 코드 만들기·허용·거부 실패는 시트 안에 보인다. 관계없는 오류는 시트에 보이지 않는다(UI2-2).
    @Test func pairingFailuresReachTheSheet() async throws {
        let tmp = try UITempDir("sheetfail")
        let core = RecordingCore()
        let model = makeRecordingModel(core, tmp)
        await model.start()
        model.handle(.state(CoreStatus(backendState: .running, hostname: "h", fqdn: "h.example.ts.net",
                                       certDomains: ["h.example.ts.net"], tlsReady: true, listening: true)))
        #expect(model.pairingAvailability == .ready)
        model.lastError = "관계없는 오류"
        #expect(PairingSheet.failureText(model) == nil)

        core.failPairing.withLock { $0 = true }
        await model.beginPairing()
        #expect(PairingSheet.failureText(model)?.contains("페어링 코드를 만들지 못했습니다") == true)
        core.failPairing.withLock { $0 = false }
        await model.beginPairing()
        #expect(PairingSheet.failureText(model) == nil, "다시 시도해 성공하면 내린다")

        model.handle(.pairRequest(PairRequestEvent(requestId: "pr_1", deviceName: "내 iPhone", nodeName: "rd-phone-1", loginName: "",
                                                   expiresAt: Date().addingTimeInterval(120))))
        core.failPairing.withLock { $0 = true }
        await model.approve("pr_1")
        #expect(PairingSheet.failureText(model)?.contains("페어링 요청을 처리하지 못했습니다") == true)
        #expect(model.pairRequests.count == 1, "실패한 요청은 다시 답할 수 있다")
        await model.deny("pr_1")
        #expect(PairingSheet.failureText(model)?.contains("페어링 요청을 처리하지 못했습니다") == true)
        core.failPairing.withLock { $0 = false }
        await model.deny("pr_1")
        #expect(PairingSheet.failureText(model) == nil)
        await model.shutdown()
    }

    @Test func confirmationDialogNamesTheBuildAndItsFullPath() async throws {
        let queue = ImportQueue(scoping: NoScope())
        let url = URL(fileURLWithPath: "/Users/me/Export/MyApp.ipa")
        let identity = BuildIdentity(content: .ipa(FileDigest(size: 1, sha256: "a")), bundleId: "com.example.shown", version: "1.4", buildNumber: "128")
        await queue.importURLs([url]) { _, _ in .needsConfirmation(identity) }
        let item = try #require(queue.current)
        let message = ImportConfirmation.message(item)
        #expect(message.contains("com.example.shown 1.4 (128)"))
        #expect(message.contains("/Users/me/Export/MyApp.ipa"))
        #expect(message.contains("Debug 구성으로 빌드한 것이 맞을 때만"))

        // 대화상자가 닫힐 때 불리는 setter는 줄을 건드리지 않는다.
        let binding = ImportConfirmation.isPresented(queue)
        #expect(binding.wrappedValue)
        binding.wrappedValue = false
        #expect(queue.pending.map(\.id) == [item.id])
    }

    @Test func rejectedListShowsTheFilesAndReasons() async throws {
        let tmp = try UITempDir("rejectedlist")
        let model = await model(.rejected, tmp)
        #expect(!BuildsView.showsEmptyState(model: model, pendingCount: 0))
        let texts = model.rejected.map(RejectedBuildRow.accessibilityText)
        #expect(texts.contains { $0.hasPrefix("거부됨: Sample.app.") && $0.contains("Debug 구성 빌드가 아닙니다") })
        #expect(texts.contains { $0.hasPrefix("거부됨: AdHocSample.app.") && $0.contains("개발용 프로필이 아닙니다") })
    }

    @Test func emptyBuildsScreenOnlyWithNothingToShow() async throws {
        let tmp = try UITempDir("emptybuilds")
        let empty = await model(.empty, tmp)
        #expect(BuildsView.showsEmptyState(model: empty, pendingCount: 0))
        #expect(!BuildsView.showsEmptyState(model: empty, pendingCount: 1), "대기 항목이 있으면 목록을 보여 준다")
        let stale = await model(.watchProblem, tmp)
        #expect(!BuildsView.showsEmptyState(model: stale, pendingCount: 0))
    }

    @Test func devicesScreenOffersTheMatchingRecovery() async throws {
        let tmp = try UITempDir("recovery")
        let expectations: [(PreviewScenario, PairingRecovery)] = [
            (.empty, .startSharing), (.needsLogin, .openLoginPage), (.certificatesOff, .openDNSSettings), (.error, .openNetworkScreen),
        ]
        for (scenario, recovery) in expectations {
            let model = await model(scenario, tmp)
            #expect(!DevicesView.pairingEntryEnabled(model), "\(scenario)")
            #expect(PairingRecovery.make(for: model) == recovery, "\(scenario)")
            await model.shutdown()
        }
        let ready = await model(.sharing, tmp)
        #expect(DevicesView.pairingEntryEnabled(ready))
        await ready.shutdown()
    }

    @Test func pairingResultFollowsTheDecisionNotTheDeviceList() {
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        let request = PairRequestEvent(requestId: "pr_1", deviceName: "내 iPhone", nodeName: "rd-phone-1", loginName: "", expiresAt: t.addingTimeInterval(60))
        let denied = PairingResult.make(outcome: .denied, request: request, alreadyAllowed: true, now: t)
        #expect(denied.text.hasPrefix("내 iPhone의 페어링 요청을 거부했습니다."))
        #expect(denied.text.contains("기존 접근은 그대로입니다"))
        #expect(!denied.succeeded, "이미 허용한 기기를 거부해도 거부로 보여 준다")
        let allowed = PairingResult.make(outcome: .allowed, request: request, alreadyAllowed: false, now: t)
        #expect(allowed.text == "내 iPhone을 허용 목록에 추가했습니다.")
        #expect(allowed.succeeded)
        #expect(PairingResult.make(outcome: .notAdded, request: request, alreadyAllowed: false, now: t).text.contains("제어 서버가 바뀌어"))
        #expect(PairingResult.make(outcome: nil, request: request, alreadyAllowed: true, now: t.addingTimeInterval(61)).text.contains("만료"))
        var unnamed = request
        unnamed.deviceName = ""
        #expect(PairingResult.make(outcome: .denied, request: unnamed, alreadyAllowed: false, now: t).text == "이름 없는 기기의 페어링 요청을 거부했습니다.")
    }

    /// 창에 올린 화면의 주기 작업이 만료된 요청을 내린다.
    @Test(.timeLimit(.minutes(1)))
    func hostedRootViewPrunesExpiredRequests() async throws {
        let tmp = try UITempDir("prune")
        let core = RecordingCore()
        let model = HostModel(core: core, paths: HostPaths(root: tmp.url.appendingPathComponent("host", isDirectory: true)),
                              bookmarks: NoFolderBookmarks(), watcherOptions: .init(useFileEvents: false), id8: "ab12cd34",
                              hostDisplayName: "Mac", appVersion: "0.1.0", openURL: { _ in })
        model.handle(.pairRequest(PairRequestEvent(requestId: "pr_1", deviceName: "내 iPhone", nodeName: "rd-phone-1", loginName: "",
                                                   expiresAt: Date().addingTimeInterval(0.5))))
        #expect(model.pairRequests.count == 1)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView(selection: .builds).environment(model))
        window.orderBack(nil)
        defer { window.close() }
        for _ in 0..<100 where !model.pairRequests.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.pairRequests.isEmpty, "만료된 요청이 내려가지 않았다")
    }

    @Test func authKeyIsTakenOnceAndCleared() {
        let draft = AuthKeyDraft()
        draft.value = "  tskey-auth-SECRET  "
        #expect(draft.take() == "tskey-auth-SECRET")
        #expect(draft.value.isEmpty)
        #expect(draft.take().isEmpty)
    }

    @Test func koreanParticles() {
        #expect(Korean.subjectParticle(after: "내 iPhone") == "이")
        #expect(Korean.subjectParticle(after: "회사 아이폰") == "이")
        #expect(Korean.subjectParticle(after: "테스트 기기") == "가")
        #expect(Korean.subjectParticle(after: "iPhone 15") == "가")
        #expect(Korean.objectParticle(after: "아이패드") == "를")
    }

    @Test func buildEvidenceText() {
        let builds = PreviewFactory.sampleBuilds()
        #expect(PublishedBuildRow.evidence(builds[0].descriptor) == "Debug · Debug-iphoneos 폴더")
        #expect(PublishedBuildRow.evidence(builds[1].descriptor) == "Debug · debug.dylib 있음")
    }

    @Test func qrCodeRenders() {
        let image = QRCodeView.makeImage("remotedebug://pair?host=rd-mac-ab12cd34.example.ts.net&code=K7M29QXD")
        #expect(image != nil)
        #expect((image?.width ?? 0) > 100)
    }

    private func waitForPending(_ model: HostModel) async throws -> PairRequestEvent {
        for _ in 0..<200 {
            if let first = model.pendingPairRequests.first { return first }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(model.pendingPairRequests.first)
    }
}
