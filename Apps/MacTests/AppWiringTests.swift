import AppKit
import MacHostKit
import MacHostUI
import SwiftUI
import Testing
@testable import RemoteDebug

/// 메모리에만 저장하는 UserDefaults. `UserDefaults(suiteName:)`는 앱 컨테이너의 Preferences에 파일을 남긴다.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}

/// 테스트가 열 때까지 메인 액터 작업을 멈춰 둔다.
@MainActor
final class ShutdownGate {
    private(set) var arrivals = 0
    private(set) var finished = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func stop(_ model: HostModel) async {
        arrivals += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        await model.shutdown()
        finished += 1
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// 앱 껍데기의 연결. 화면 자체의 테스트는 Packages/MacHost의 MacHostUITests에 있다.
@MainActor
@Suite("앱 연결", .serialized)
struct AppWiringTests {
    /// 테스트 호스트가 아닌 실행을 임시 저장 폴더·UserDefaults로 흉내 낸다.
    struct Instance {
        let root: URL
        let defaults = InMemoryDefaults()
        let options: LaunchOptions

        init(stateRootName: String = "RemoteDebug-wiring") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDebugWiring-\(UUID().uuidString)", isDirectory: true)
            defaults.set(stateRootName, forKey: LaunchOptions.stateRootNameKey)
            options = LaunchOptions(defaults: defaults, environment: [:], arguments: [:])
        }

        @MainActor func makeDelegate(stopModel: @escaping @MainActor (HostModel) async -> Void = { await $0.shutdown() }) -> AppDelegate {
            AppDelegate(options: options, defaults: defaults, storage: { _ in HostPaths(root: root) }, stopModel: stopModel)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// 단위 테스트 호스트로 뜬 앱은 개발자의 실제 저장 폴더를 쓰지 않고, 불러오기·공유 시작도 하지 않는다(T7).
    @Test func testHostDoesNotTouchRealState() throws {
        let delegate = try #require(AppDelegate.shared)
        #expect(delegate.options.isTesting)
        let paths = try #require(delegate.paths)
        let real = try HostPaths.applicationSupport()
        #expect(paths.root != real.root, "테스트 호스트가 실제 저장 폴더를 쓴다: \(paths.root.path)")
        #expect(paths.root.lastPathComponent.hasPrefix("RemoteDebugTestHost-"))
        let model = try #require(delegate.model)
        #expect(!model.isRunning)
        #expect(!model.isStarting)
        #expect(model.watchedFolder == nil)
        #expect(model.builds.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.buildsFile.path), "테스트 호스트가 라이브러리를 불러왔다")
    }

    @Test func rootViewRendersWithTheAppModel() throws {
        let delegate = try #require(AppDelegate.shared)
        let model = try #require(delegate.model)
        let host = NSHostingView(rootView: RootView(selection: .builds).environment(model))
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        host.layoutSubtreeIfNeeded()
    }

    /// 앱 대리자는 잠금을 붙잡고 있다가 종료할 때 놓는다. 두 번째 실행은 같은 폴더를 쓰지 못한다(TQ-1).
    @Test func delegateHoldsTheStateLockUntilReleased() throws {
        let instance = try Instance()
        defer { instance.cleanUp() }
        let delegate = instance.makeDelegate()
        guard case .ready = delegate.launch else { Issue.record("시작하지 못했다"); return }
        #expect(throws: StateDirLock.Failure.held) { _ = try StateDirLock.acquire(root: instance.root) }

        let second = instance.makeDelegate()
        guard case .failed(.alreadyRunning) = second.launch else {
            Issue.record("두 번째 실행이 같은 저장 폴더를 열었다")
            return
        }

        delegate.releaseState()
        let again = try StateDirLock.acquire(root: instance.root)
        again.release()
    }

    /// 정리 중에 온 종료 요청에는 기다리라고 답하고, 정리가 끝날 때까지 잠금을 놓지 않는다(LC-R1).
    @Test(.timeLimit(.minutes(1)))
    func terminateRequestsDuringShutdownKeepWaiting() async throws {
        let instance = try Instance()
        defer { instance.cleanUp() }
        let gate = ShutdownGate()
        let delegate = instance.makeDelegate(stopModel: gate.stop)
        var replies = 0
        #expect(delegate.handleTerminationRequest { replies += 1 } == .terminateLater)
        #expect(delegate.handleTerminationRequest { replies += 1 } == .terminateLater)

        // 정리가 시작돼 모델을 멈추는 중에 잠금을 본다.
        for _ in 0..<500 where gate.arrivals == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.arrivals == 1)
        #expect(throws: StateDirLock.Failure.held) { _ = try StateDirLock.acquire(root: instance.root) }
        #expect(replies == 0)
        #expect(delegate.handleTerminationRequest { replies += 1 } == .terminateLater)

        gate.open()
        for _ in 0..<500 where replies == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(replies == 1)
        #expect(gate.finished == 1, "모델을 멈추기 전에 답했다")
        let again = try StateDirLock.acquire(root: instance.root)
        again.release()
        #expect(delegate.handleTerminationRequest { replies += 1 } == .terminateNow)
    }

    /// 저장 폴더를 바꾼 실행은 기본 폴더의 감시 폴더 북마크를 보지 않는다.
    @Test(.timeLimit(.minutes(1)))
    func otherStateRootDoesNotResumeTheSavedFolder() async throws {
        let instance = try Instance()
        defer { instance.cleanUp() }
        instance.defaults.set(Data("developer bookmark".utf8), forKey: UserDefaultsFolderBookmarks.defaultKey)
        let delegate = instance.makeDelegate()
        defer { delegate.releaseState() }
        let model = try #require(delegate.model)
        await model.load()
        await model.waitForFolderResume()
        #expect(model.watchProblem == nil, "기본 폴더의 북마크를 읽었다")
        #expect(model.watchedFolder == nil)
    }

    /// 대조군: 기본 폴더 실행은 저장된 북마크를 본다(위 테스트가 헛돌지 않는지 확인).
    @Test(.timeLimit(.minutes(1)))
    func defaultStateRootReadsTheSavedFolder() async throws {
        let instance = try Instance(stateRootName: LaunchOptions.defaultStateRootName)
        defer { instance.cleanUp() }
        instance.defaults.set(Data("developer bookmark".utf8), forKey: UserDefaultsFolderBookmarks.defaultKey)
        let delegate = instance.makeDelegate()
        defer { delegate.releaseState() }
        let model = try #require(delegate.model)
        await model.load()
        await model.waitForFolderResume()
        #expect(model.watchProblem != nil)
    }
}
