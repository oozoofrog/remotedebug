import AppKit
import MacHostCore
import MacHostKit
import MacHostUI
import SwiftUI

// 앱 대상에는 진입점·수명 주기·실제 코어 연결만 둔다. 화면과 미리보기는 MacHostUI(Go 런타임을 링크하지 않는다)에 있다.

@main
struct RemoteDebugMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("RemoteDebug", id: "main") {
            Group {
                switch appDelegate.launch {
                case .ready(let model):
                    RootView()
                        .environment(model)
                case .failed(let failure):
                    LaunchFailureView(
                        failure: failure,
                        switchToRunningApp: failure == .alreadyRunning ? AppDelegate.otherInstance().map { app in { _ = app.activate(options: []) } } : nil,
                        quit: { NSApp.terminate(nil) })
                }
            }
            .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                ImportCommand()
            }
        }
    }
}

/// 앱 수명 주기. 종료할 때 공유와 폴더 감시를 멈춘다(앱이 꺼지면 서빙도 멈춘다).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 이 프로세스의 앱 대리자(SwiftUI가 `NSApp.delegate`를 자기 객체로 감싸므로 따로 둔다. 앱 테스트가 쓴다).
    private(set) static weak var shared: AppDelegate?

    enum Launch {
        case ready(HostModel)
        case failed(LaunchFailure)
    }

    let launch: Launch
    let options: LaunchOptions
    /// 저장 폴더. 테스트 호스트면 지울 임시 폴더.
    let paths: HostPaths?
    /// 저장 폴더를 이 프로세스만 쓰게 하는 잠금. 종료할 때 공유를 멈춘 뒤 놓는다.
    private var stateLock: StateDirLock?
    /// 종료 순서. 정리가 끝나기 전의 종료 요청은 모두 기다리게 한다.
    private let termination = TerminationSequence()
    /// 종료할 때 모델을 멈춘다. 앱 테스트가 멈추는 순서를 지켜보려고 바꿔 끼운다.
    private let stopModel: @MainActor (HostModel) async -> Void
    private var launchTask: Task<Void, Never>?
    private var receivedTerminationSignal = false
    private var termSource: (any DispatchSourceSignal)?

    override convenience init() {
        self.init(options: LaunchOptions(defaults: .standard))
        Self.shared = self
    }

    /// 앱 테스트는 저장 폴더와 UserDefaults를 바꿔 끼운다.
    init(
        options: LaunchOptions,
        defaults: UserDefaults = .standard,
        storage: (LaunchOptions) throws -> HostPaths = { try HostPaths.applicationSupport(name: $0.stateRootName) },
        stopModel: @escaping @MainActor (HostModel) async -> Void = { await $0.shutdown() }
    ) {
        self.options = options
        self.stopModel = stopModel
        var lock: StateDirLock?
        var paths: HostPaths?
        let launch: Launch
        if options.isTesting {
            // 단위 테스트 호스트: 개발자의 실제 저장 폴더·감시 폴더·공유를 건드리지 않는다.
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RemoteDebugTestHost-\(UUID().uuidString)", isDirectory: true)
            let testPaths = HostPaths(root: root)
            paths = testPaths
            launch = .ready(HostModel(core: RDCoreHost(), paths: testPaths, bookmarks: NoFolderBookmarks(), id8: "00000000"))
        } else {
            do {
                let appPaths = try storage(options)
                paths = appPaths
                lock = try StateDirLock.acquire(root: appPaths.root)
                let bookmarks = UserDefaultsFolderBookmarks(defaults: defaults, key: options.folderBookmarkKey)
                let model = HostModel(core: RDCoreHost(), paths: appPaths, bookmarks: bookmarks, id8: options.nodeID8)
                model.controlURL = options.controlURL
                launch = .ready(model)
            } catch StateDirLock.Failure.held {
                launch = .failed(.alreadyRunning)
            } catch {
                launch = .failed(.storageUnavailable(HostErrorText.message(for: error)))
            }
        }
        self.paths = paths
        self.stateLock = lock
        self.launch = launch
        super.init()
    }

    var model: HostModel? {
        if case .ready(let model) = launch { return model }
        return nil
    }

    /// 같은 번들 id로 이미 실행 중인 다른 RemoteDebug.
    static func otherInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.processIdentifier != me }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model, !options.isTesting else { return }
        installTerminationSignalHandler()
        let startSharing = options.startSharing
        launchTask = Task {
            await model.load()
            if startSharing, !Task.isCancelled { await model.start() }
        }
    }

    /// SIGTERM(`kill`, 로그아웃 스크립트 등)도 메뉴의 종료처럼 공유를 멈춘 뒤 끝낸다.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.receivedTerminationSignal else { return }
                self.receivedTerminationSignal = true
                // 종료 처리가 막히면(메인 스레드가 멈춤) 10초 뒤 강제로 끝낸다. 커널이 저장 폴더 잠금을 풀고, 코어도 프로세스와 함께 끝난다.
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(1) }
                // 이미 정리 중이면(메뉴의 종료) terminate를 다시 부르지 않는다. 그 정리의 답이 유일한 종료 경로다.
                guard self.termination.phase == .idle else { return }
                // 메인 큐 처리 안에서 terminate를 부르면 .terminateLater의 중첩 런 루프가 메인 큐를 돌리지 못해
                // @MainActor 종료 작업이 멈춘다. 큐 밖의 런 루프 블록에서 부른다.
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            }
        }
        source.resume()
        termSource = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 공유 중지가 끝난 뒤 종료한다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        handleTerminationRequest { sender.reply(toApplicationShouldTerminate: true) }
    }

    /// 잠금은 공유를 멈춘 뒤에만 놓는다. 정리 중에 온 요청에는 `.terminateLater`로 답한다.
    func handleTerminationRequest(reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        guard model != nil else {
            releaseState()
            return .terminateNow
        }
        return beginShutdown(finish: reply) == .now ? .terminateNow : .terminateLater
    }

    private func beginShutdown(finish: @escaping @MainActor () -> Void) -> TerminationSequence.Answer {
        termination.request(shutdown: { [self] in
            launchTask?.cancel()
            if let model { await stopModel(model) }
            releaseState()
        }, finish: finish)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // applicationShouldTerminate를 거치지 않는 종료(시스템 종료 등)에서도 코어를 멈춘다.
        guard model != nil else {
            releaseState()
            return
        }
        _ = beginShutdown(finish: {})
        // 메인 액터 작업이 돌 수 있게 런 루프를 돌리며 최대 3초 기다린다.
        let deadline = Date().addingTimeInterval(3)
        while termination.phase != .finished, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        releaseState()
    }

    /// 잠금을 놓고, 테스트 호스트면 임시 저장 폴더를 지운다.
    func releaseState() {
        stateLock?.release()
        stateLock = nil
        if options.isTesting, let root = paths?.root {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
