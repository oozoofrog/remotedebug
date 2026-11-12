import AppKit
import MacHostCore
import MacHostKit
import MacHostUI
import ServiceManagement
import SwiftUI
import UserNotifications

// 앱 대상에는 진입점·수명 주기·실제 코어 연결만 둔다. 화면과 미리보기는 MacHostUI(Go 런타임을 링크하지 않는다)에 있다.

/// 진입점. `--mcp` 인자로 띄우면 창 없이 MCP 서버로 돌며, 명령은 실행 중인 앱에 넘긴다.
@main
enum RemoteDebugEntry {
    static func main() {
        guard CommandLine.arguments.contains(AgentMCPServer.argument) else {
            RemoteDebugMacApp.main()
            return
        }
        guard let paths = try? HostPaths.applicationSupport() else { exit(1) }
        let channel = AgentChannel(agentDir: paths.root.appendingPathComponent("agent", isDirectory: true),
                                   bundleID: Bundle.main.bundleIdentifier ?? "com.oozoofrog.app.RemoteDebugMac")
        Task.detached {
            await AgentMCPServer(channel: channel).run()
            exit(0)
        }
        dispatchMain()
    }
}

struct RemoteDebugMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("RemoteDebug", id: "main") {
            Group {
                switch appDelegate.launch {
                case .ready(let model):
                    RootView()
                        .environment(model)
                        .environment(appDelegate.projects)
                        .environment(appDelegate.updatePage)
                        .environment(appDelegate.phoneInstaller)
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

        // 창을 닫아도 앱은 메뉴 막대에 남아 공유와 Xcode 감시를 계속한다.
        MenuBarExtra("RemoteDebug", systemImage: "iphone.and.arrow.forward") {
            MenuBarContent(model: appDelegate.model, projects: appDelegate.projects)
        }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: HostModel?
    let projects: ProjectsModel?
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        if let model {
            Text(model.isRunning ? "공유 중 · 빌드 \(model.builds.count)개" : "공유 꺼짐")
        }
        if let count = projects?.suggestions.count, count > 0 {
            Text("등록을 기다리는 프로젝트 \(count)개")
        }
        Button("RemoteDebug 창 열기") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Toggle("로그인할 때 열기", isOn: Binding(get: { opensAtLogin }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                model?.lastError = "로그인 항목을 바꾸지 못했습니다: \(HostErrorText.message(for: error))"
            }
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }))
        Button("RemoteDebug 종료") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
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
    /// 연결한 프로젝트와 Xcode 감시. 테스트 호스트와 실행 실패 때는 없다.
    private(set) var projects: ProjectsModel?
    /// iPhone 앱 자신의 업데이트를 공식 Tailscale로 내주는 페이지. 테스트 호스트와 실행 실패 때는 없다.
    private(set) var updatePage: UpdatePageModel?
    /// 연결한 iPhone에 RemoteDebug iPhone 앱을 빌드해 설치한다. 테스트 호스트와 실행 실패 때는 없다.
    private(set) var phoneInstaller: PhoneAppInstaller?
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
                let bookmarks = UserDefaultsFolderBookmarks(defaults: defaults, key: options.folderBookmarkKey, securityScoped: false)
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
        if !options.isTesting, case .ready(let model) = launch, let paths {
            let updatePage = UpdatePageModel(root: paths.root, server: RDCoreUpdatePage())
            self.updatePage = updatePage
            let source = (Bundle.main.object(forInfoDictionaryKey: "RDSourceRoot") as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            phoneInstaller = PhoneAppInstaller(root: paths.root, sourceRoot: source)
            projects = ProjectsModel(
                root: paths.root,
                hostStatus: { [weak model, weak updatePage] in
                    ProjectsModel.HostStatus(sharing: model?.isRunning ?? false, installPage: model?.installPageURL?.absoluteString,
                                             updatePage: updatePage?.pageURL?.absoluteString)
                },
                openPairing: { [weak model] in
                    guard let model else { return .failure(.init("RemoteDebug가 준비되지 않았습니다.")) }
                    return await model.openPairingForAgent()
                },
                pairingRequests: .init(
                    list: { [weak model] in model?.pairRequestsForAgent ?? [] },
                    decide: { [weak model] id, allow in
                        guard let model else { return "RemoteDebug가 준비되지 않았습니다." }
                        return await model.decideForAgent(id, allow: allow)
                    }),
                fileSharing: .init(
                    list: { [weak model] in model?.sharedFiles ?? [] },
                    share: { [weak model] url in
                        guard let model else { return .failure(ShareFileFailure("RemoteDebug가 준비되지 않았습니다.")) }
                        return await model.shareFile(url)
                    },
                    remove: { [weak model] id in await model?.unshareFile(id) },
                    shareLink: { [weak model] url, title in
                        guard let model else { return .failure(ShareFileFailure("RemoteDebug가 준비되지 않았습니다.")) }
                        return await model.shareLink(url, title: title)
                    }),
                importer: { [weak model] url in await model?.importBuild(url) })
        }
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
        // 실행 중인 앱의 Dock 아이콘이 기본 아이콘으로 나오는 경우가 있어 번들 아이콘을 직접 지정한다.
        if let icon = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
        guard let model, !options.isTesting else { return }
        installTerminationSignalHandler()
        let projects = self.projects
        if let updatePage {
            model.onBuildsChanged = { [weak model, weak updatePage] builds in
                guard let model, let updatePage else { return }
                await updatePage.sync(builds: builds) { model.publishedIPA(forBuildID: $0) }
            }
            Task {
                await updatePage.start()
                updatePage.startMonitoring()
                await updatePage.sync(builds: model.builds) { model.publishedIPA(forBuildID: $0) }
            }
        }
        launchTask = Task {
            await model.load()
            // 앱을 열면 항상 공유를 시작한다. 처음이면 로그인을 기다리는 상태가 된다.
            if !Task.isCancelled { await model.start() }
            guard !Task.isCancelled else { return }
            projects?.startMonitoring()
        }
        installSuggestionNotifications()
    }

    /// 끌어 놓거나 `open -a RemoteDebug <폴더>`로 넘긴 프로젝트를 연결하고 빌드한다. `.app`·`.ipa`는 빌드로 가져온다.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model, let projects else { return }
        Task {
            await model.load()
            for url in urls {
                if ["app", "ipa"].contains(url.pathExtension.lowercased()) {
                    await model.importBuild(url)
                } else {
                    await projects.connectAndBuild(url)
                }
            }
        }
    }

    // MARK: 등록 제안 알림

    private static let suggestionCategory = "rd.project.suggestion"
    private static let registerAction = "rd.project.register"
    private static let dismissAction = "rd.project.dismiss"

    /// Xcode에서 연결하지 않은 프로젝트의 기기용 Debug 빌드가 보이면 시스템 알림으로 등록을 묻는다.
    private func installSuggestionNotifications() {
        guard let projects else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.suggestionCategory,
            actions: [
                UNNotificationAction(identifier: Self.registerAction, title: "등록"),
                UNNotificationAction(identifier: Self.dismissAction, title: "등록하지 않음"),
            ],
            intentIdentifiers: [])])
        projects.onSuggestion = { suggestion in
            Task {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
                let content = UNMutableNotificationContent()
                content.title = "\(suggestion.name)을(를) RemoteDebug에 등록할까요?"
                content.body = "Xcode에서 기기용 Debug 빌드를 시작했습니다. 등록하면 빌드할 때마다 iPhone에 게시합니다."
                content.categoryIdentifier = Self.suggestionCategory
                content.userInfo = ["container": suggestion.container]
                try? await center.add(UNNotificationRequest(identifier: suggestion.container, content: content, trigger: nil))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

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

    /// 창을 닫아도 메뉴 막대에 남는다. 종료는 메뉴 막대나 ⌘Q로 한다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
            projects?.stopMonitoring()
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let container = response.notification.request.content.userInfo["container"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let container, let projects = self.projects,
                  let suggestion = projects.suggestions.first(where: { $0.container == container })
            else { return }
            switch action {
            case Self.registerAction: Task { await projects.register(suggestion) }
            case Self.dismissAction: projects.dismiss(suggestion)
            default: NSApp.activate()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
