import AppKit
import Foundation
@testable import MacHostKit
import RDModels
import SwiftUI
import Testing
@testable import MacHostUI

/// SwiftUI는 보조 기술이 붙어 있어야 접근성 트리를 만든다. 이 프로세스에 붙은 것처럼 알린 뒤 트리로 화면을 읽고 누른다.
@MainActor
enum AXTree {
    static func enable() {
        let app = NSApplication.shared
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
    }

    private static func read(_ object: NSObject, _ key: String, selector: String? = nil) -> Any? {
        object.responds(to: Selector(selector ?? key)) ? object.value(forKey: key) : nil
    }

    static func children(of object: NSObject) -> [NSObject] {
        if let list = read(object, "accessibilityChildren") as? [NSObject], !list.isEmpty { return list }
        return object.accessibilityAttributeValue(.children) as? [NSObject] ?? []
    }

    static func all(in root: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 24 else { return [] }
        return [root] + children(of: root).flatMap { all(in: $0, depth: depth + 1) }
    }

    static func isButton(_ object: NSObject) -> Bool { read(object, "accessibilityRole") as? String == "AXButton" }

    static func label(_ object: NSObject) -> String { read(object, "accessibilityLabel") as? String ?? "" }

    static func isEnabled(_ object: NSObject) -> Bool {
        read(object, "accessibilityEnabled", selector: "isAccessibilityEnabled") as? Bool ?? false
    }

    static func buttons(_ label: String, in root: NSObject) -> [NSObject] {
        all(in: root).filter { isButton($0) && self.label($0) == label }
    }

    /// 화면에 보이는 문장(값·이름).
    static func texts(in root: NSObject) -> [String] {
        all(in: root).flatMap { [read($0, "accessibilityValue") as? String, read($0, "accessibilityLabel") as? String].compactMap(\.self) }
    }

    static func press(_ object: NSObject) { _ = object.perform(Selector(("accessibilityPerformPress"))) }
}

extension ScreenTests {
    func host<V: View>(_ view: V) -> NSWindow {
        AXTree.enable()
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        return window
    }

    /// 화면이 그려지기를 기다린다(최대 약 5초).
    func until(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func root(_ window: NSWindow) throws -> NSObject { try #require(window.contentView) }

    /// 공유 시작 버튼은 입력한 키로 시작한다(TQ-2).
    @Test(.timeLimit(.minutes(1)))
    func startButtonUsesTheTypedKey() async throws {
        let tmp = try UITempDir("startbutton")
        let core = RecordingCore()
        let model = makeRecordingModel(core, tmp)
        let draft = AuthKeyDraft()
        draft.value = "tskey-auth-TYPED"
        let window = host(SharingButton().environment(model).environment(draft))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons("공유 시작", in: view).isEmpty })

        AXTree.press(try #require(AXTree.buttons("공유 시작", in: view).first))
        try #require(try await until { model.isRunning })
        #expect(core.startKeys == ["tskey-auth-TYPED"])
        #expect(draft.value.isEmpty)
        await model.shutdown()
    }

    /// 다시 시작 버튼은 입력한 키로 다시 시작한다(TQ-2).
    @Test(.timeLimit(.minutes(1)))
    func restartButtonUsesTheTypedKey() async throws {
        let tmp = try UITempDir("restartbutton")
        let core = RecordingCore()
        let model = makeRecordingModel(core, tmp)
        await model.start()
        let draft = AuthKeyDraft()
        draft.value = "tskey-auth-TYPED"
        let window = host(RestartSharingButton().environment(model).environment(draft))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons("공유 다시 시작", in: view).isEmpty })

        AXTree.press(try #require(AXTree.buttons("공유 다시 시작", in: view).first))
        try #require(try await until { core.startKeys.count == 2 })
        #expect(core.startKeys == ["", "tskey-auth-TYPED"])
        await model.shutdown()
    }

    /// 다시 시작하는 동안 공유 시작 버튼을 끈다(UI2-1).
    @Test(.timeLimit(.minutes(1)))
    func startButtonIsDisabledDuringARestart() async throws {
        let tmp = try UITempDir("startdisabled")
        let draft = AuthKeyDraft()
        draft.isRestarting = true
        let window = host(VStack { SharingButton(); RestartSharingButton() }.environment(makeRecordingModel(RecordingCore(), tmp)).environment(draft))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons("공유 시작", in: view).isEmpty && !AXTree.buttons("공유 다시 시작", in: view).isEmpty })
        #expect(AXTree.buttons("공유 시작", in: view).allSatisfy { !AXTree.isEnabled($0) })
        #expect(AXTree.buttons("공유 다시 시작", in: view).allSatisfy { !AXTree.isEnabled($0) })
    }

    /// 입력란이 보이면 시작·다시 시작 버튼은 입력란 옆에 하나만 있다(UI-R4).
    @Test(.timeLimit(.minutes(1)))
    func networkScreenOffersOneStartActionBesideTheKeyField() async throws {
        let tmp = try UITempDir("onestart")
        let stopped = await model(.empty, tmp)
        let stoppedWindow = host(RootView(selection: .network).environment(stopped))
        defer { stoppedWindow.close() }
        let stoppedView = try root(stoppedWindow)
        try #require(try await until { !AXTree.buttons("공유 시작", in: stoppedView).isEmpty })
        #expect(AXTree.buttons("공유 시작", in: stoppedView).count == 2, "사이드바 아래와 입력란 옆에만 있어야 한다")

        let failed = await model(.error, tmp)
        #expect(failed.guidance.action == .restart)
        let failedWindow = host(RootView(selection: .network).environment(failed))
        defer { failedWindow.close() }
        let failedView = try root(failedWindow)
        try #require(try await until { !AXTree.buttons("공유 다시 시작", in: failedView).isEmpty })
        #expect(AXTree.buttons("공유 다시 시작", in: failedView).count == 1)
        await failed.shutdown()
    }

    /// 입력란이 없는 곳에서는 안내 카드가 시작·다시 시작 버튼을 보여 준다(UI-R4).
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func guidanceCardShowsStartActionsOnlyWhenAsked(shows: Bool) async throws {
        let tmp = try UITempDir("card")
        let guidance = StatusGuidance.make(for: CoreStatus(backendState: .error, certDomains: ["x.ts.net"], errorMessage: "listen tcp :443: address already in use"))
        #expect(guidance.action == .restart)
        let window = host(GuidanceCard(guidance: guidance, showsStartActions: shows)
            .environment(makeRecordingModel(RecordingCore(), tmp)).environment(AuthKeyDraft()))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { AXTree.texts(in: view).contains { $0.contains("address already in use") } })
        #expect(AXTree.buttons("공유 다시 시작", in: view).count == (shows ? 1 : 0))
    }

    /// iPhone이 이 Mac에 닿을 수 없으면 기기 화면의 페어링 버튼을 끈다(UI-R4).
    @Test(.timeLimit(.minutes(1)), arguments: [PreviewScenario.empty, .sharing])
    func pairingToolbarFollowsAvailability(scenario: PreviewScenario) async throws {
        let tmp = try UITempDir("toolbar")
        let model = await model(scenario, tmp)
        let window = host(RootView(selection: .devices).environment(model))
        defer { window.close() }
        func pairingButton() -> NSObject? {
            guard let item = window.toolbar?.items.first(where: { $0.label == "iPhone 페어링…" }), let view = item.view else { return nil }
            return AXTree.buttons("iPhone 페어링…", in: view).first
        }
        try #require(try await until { pairingButton() != nil })
        #expect(AXTree.isEnabled(try #require(pairingButton())) == (scenario == .sharing))
        await model.shutdown()
    }

    /// 감시 폴더를 찾을 수 없으면 빌드 화면이 그 사실과 다시 고르기를 보여 준다(UI-R4).
    @Test(.timeLimit(.minutes(1)))
    func watchedFolderRowShowsTheProblem() async throws {
        let tmp = try UITempDir("watchrow")
        let model = await model(.watchProblem, tmp)
        let problem = try #require(model.watchProblem)
        let window = host(RootView(selection: .builds).environment(model))
        defer { window.close() }
        let view = try root(window)
        try #require(try await until { !AXTree.buttons("폴더 다시 고르기", in: view).isEmpty })
        #expect(AXTree.texts(in: view).contains { $0.contains(problem.message) })
    }

    /// 코드를 만들지 못한 이유가 시트 안에 보인다(UI2-2).
    @Test(.timeLimit(.minutes(1)))
    func pairingSheetShowsTheFailure() async throws {
        let tmp = try UITempDir("sheetview")
        let core = RecordingCore()
        let model = makeRecordingModel(core, tmp)
        await model.start()
        model.handle(.state(CoreStatus(backendState: .running, hostname: "h", fqdn: "h.example.ts.net",
                                       certDomains: ["h.example.ts.net"], tlsReady: true, listening: true)))
        core.failPairing.withLock { $0 = true }
        let window = host(PairingSheet().environment(model).environment(AuthKeyDraft()))
        defer { window.close() }
        let view = try root(window)
        let shown = try await until { AXTree.texts(in: view).contains { $0.contains("페어링 코드를 만들지 못했습니다") } }
        #expect(shown, "\(AXTree.texts(in: view))")
        await model.shutdown()
    }

    /// 대화상자는 줄의 첫 항목에 답하고 나머지는 그대로 둔다(TQ-2).
    @Test(.timeLimit(.minutes(1)))
    func confirmationDialogConfirmsTheShownItemOnly() async throws {
        let tmp = try UITempDir("dialog")
        let model = makeRecordingModel(RecordingCore(), tmp)
        let queue = ImportQueue(scoping: NoScope())
        let missing = tmp.url.appendingPathComponent("Missing.ipa")
        let second = tmp.url.appendingPathComponent("Second.ipa")
        let identity = BuildIdentity(content: .ipa(FileDigest(size: 1, sha256: "a")), bundleId: "com.example.shown", version: "1.4", buildNumber: "128")
        await queue.importURLs([missing, second]) { _, _ in .needsConfirmation(identity) }

        let window = host(RootView(selection: .builds, importQueue: queue).environment(model))
        defer { window.close() }
        try #require(try await until { window.attachedSheet != nil })
        let sheet = try #require(window.attachedSheet?.contentView)
        func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
        let confirm = try #require(allViews(sheet).compactMap { $0 as? NSButton }.first { $0.title == "Debug 빌드로 가져오기" })
        confirm.performClick(nil)

        // 없는 파일이라 검사에서 거부된다. 거부 목록에 오르면 답이 이 항목의 가져오기에 닿은 것이다.
        try #require(try await until { model.rejected.map(\.sourcePath) == [missing.path] })
        #expect(queue.pending.map(\.url) == [second], "다른 항목을 건드렸다")
        await model.shutdown()
    }
}
