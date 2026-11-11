import CoreServices
import Foundation

/// 사용자가 고른 폴더를 감시해 새로 끝난 빌드(`.app`)를 넘긴다.
///
/// - FSEvents 변경 알림 뒤 `debounce`(기본 2초) 동안 조용하면 전체를 다시 훑는다.
/// - `start()`가 처음 한 번 전체를 훑고, `rescan()`은 바로 훑는다.
/// - Info.plist·실행 파일이 없는 번들은 빌드 중으로 건너뛴다(다음 검사에서 다시 본다).
/// - 실행 파일 지문(수정 시각+크기)이 전과 같으면 넘기지 않는다. `stateFile`을 주면 처리한 지문을 저장해
///   다시 시작해도(게시를 취소했거나 거부된 빌드 포함) 지문이 바뀌기 전에는 다시 넘기지 않는다.
/// - `stop()` 뒤에는 진행 중인 검사도 남은 빌드를 넘기지 않는다(넘기지 못한 빌드는 다음 시작 때 다시 본다).
public actor FolderWatcher {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    /// 넘긴 빌드를 처리했으면 true. false면 지문을 기억하지 않아 다음 검사에서 다시 넘긴다.
    public typealias BuildHandler = @Sendable (URL) async -> Bool
    /// 검사할 때마다 감시 폴더 자체를 읽을 수 있는지 알린다.
    public typealias RootStatusHandler = @Sendable (RootStatus) async -> Void

    public enum RootStatus: Sendable, Hashable {
        case readable
        /// 폴더가 없다(지워졌거나 옮겨졌다).
        case missing
        /// 폴더는 있지만 목록을 읽을 수 없다(권한).
        case unreadable
    }

    public struct Options: Sendable {
        public var debounce: Duration
        public var sleep: Sleep
        /// false면 FSEvents를 켜지 않는다(테스트는 `fileSystemChanged()`를 직접 부른다).
        public var useFileEvents: Bool
        public var scanner: FolderScanner

        public init(
            debounce: Duration = .seconds(2),
            sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
            useFileEvents: Bool = true,
            scanner: FolderScanner = FolderScanner()
        ) {
            self.debounce = debounce
            self.sleep = sleep
            self.useFileEvents = useFileEvents
            self.scanner = scanner
        }
    }

    struct StoredState: Codable, Sendable {
        var fingerprints: [String: BuildFingerprint]
    }

    public let root: URL
    private let options: Options
    private let onBuild: BuildHandler
    private let onRootStatus: RootStatusHandler?
    private let stateFile: JSONFile<StoredState>?

    private var known: [String: BuildFingerprint] = [:]
    /// 넘기는 중이거나 넘길 차례를 기다리는 번들(저장하지 않는다).
    private var pending: Set<String> = []
    private var stateLoaded = false
    private var debounceGeneration = 0
    /// `start`·`stop`마다 늘어난다. 검사 중에 바뀌면 남은 빌드를 넘기지 않는다.
    private var runID = 0
    private var monitor: FileEventsMonitor?
    public private(set) var isRunning = false
    /// 마지막 검사에서 빌드 중이라 건너뛴 번들.
    public private(set) var buildingApps: [URL] = []
    /// 전체 검사를 한 횟수.
    public private(set) var scanCount = 0
    /// 마지막 검사 때 감시 폴더의 상태.
    public private(set) var rootStatus: RootStatus = .readable

    public init(root: URL, options: Options = Options(), stateFile: URL? = nil,
                onRootStatus: RootStatusHandler? = nil, onBuild: @escaping BuildHandler) {
        self.root = root
        self.options = options
        self.onBuild = onBuild
        self.onRootStatus = onRootStatus
        self.stateFile = stateFile.map { JSONFile(url: $0) }
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        runID += 1
        if !stateLoaded {
            stateLoaded = true
            if let stored = try? stateFile?.load() {
                known.merge(stored.fingerprints) { current, _ in current }
            }
        }
        if options.useFileEvents {
            monitor = FileEventsMonitor(path: root.path) { [weak self] in
                guard let self else { return }
                Task { await self.fileSystemChanged() }
            }
        }
        await rescan()
    }

    public func stop() {
        isRunning = false
        runID += 1
        debounceGeneration += 1
        monitor?.stop()
        monitor = nil
    }

    /// 파일 변경 알림. 마지막 알림 뒤 `debounce`가 지나면 한 번 훑는다.
    public func fileSystemChanged() {
        guard isRunning else { return }
        debounceGeneration += 1
        let expected = debounceGeneration
        let sleep = options.sleep
        let delay = options.debounce
        Task {
            try? await sleep(delay)
            await self.debounceElapsed(expected)
        }
    }

    private func debounceElapsed(_ expected: Int) async {
        guard isRunning, expected == debounceGeneration else { return }
        await rescan()
    }

    /// 지금 전체를 훑어 새로 바뀐 빌드를 넘기고, 넘긴 빌드를 돌려준다. 멈춰 있으면 아무것도 하지 않는다.
    @discardableResult
    public func rescan() async -> [URL] {
        guard isRunning else { return [] }
        let run = runID
        scanCount += 1
        let status = Self.status(of: root)
        rootStatus = status
        await onRootStatus?(status)
        guard status == .readable, isRunning, runID == run else { return [] }
        let apps = options.scanner.findApps(in: root)
        var building: [URL] = []
        var changed: [URL] = []
        for app in apps {
            switch FolderScanner.state(of: app) {
            case .building:
                building.append(app)
            case .ready(let fingerprint):
                if known[app.path] == fingerprint { continue }
                known[app.path] = fingerprint  // 넘기기 전에 기록해 겹친 검사가 같은 빌드를 두 번 넘기지 않게 한다
                pending.insert(app.path)
                changed.append(app)
            }
        }
        buildingApps = building
        var delivered: [URL] = []
        for (i, app) in changed.enumerated() {
            guard isRunning, runID == run else {
                for rest in changed[i...] {
                    known[rest.path] = nil
                    pending.remove(rest.path)
                }
                break
            }
            let handled = await onBuild(app)
            pending.remove(app.path)
            if handled {
                delivered.append(app)
            } else {
                known[app.path] = nil
            }
            persist()
        }
        return delivered
    }

    nonisolated static func status(of root: URL) -> RootStatus {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .missing }
        return (try? fm.contentsOfDirectory(atPath: root.path)) == nil ? .unreadable : .readable
    }

    private func persist() {
        guard let stateFile else { return }
        try? stateFile.save(StoredState(fingerprints: known.filter { !pending.contains($0.key) }))
    }
}

/// FSEvents 스트림 한 개. 콜백은 전용 직렬 큐에서 돈다.
final class FileEventsMonitor: @unchecked Sendable {
    private final class Box {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    private let queue = DispatchQueue(label: "remotedebug.folder-events")
    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?

    init?(path: String, latency: CFTimeInterval = 0.3, handler: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(Box(handler))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().handler()
        }
        // WatchRoot: 감시 폴더 자체가 지워지거나 옮겨져도 알림을 받아 실패 상태를 바로 보여 준다.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            box.release()
            return nil
        }
        self.stream = stream
        self.box = box
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            box?.release()
            box = nil
        }
    }

    deinit { stop() }
}
