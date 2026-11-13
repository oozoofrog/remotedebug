import CryptoKit
import Foundation
import RDBuildInspection
import RDModels
import Synchronization
@testable import MacHostKit

// MARK: 임시 폴더 (내장 디스크를 쓰지 않는다)

final class TempDir: @unchecked Sendable {
    let url: URL

    init(_ label: String = "t") throws {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let p = env["RD_TEST_TMPDIR"] {
            base = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: "/Volumes/eyedisk/build/remotedebug/mac-host-tmp", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("mh-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

enum Fixtures {
    /// Packages/RemoteDebugKit/Fixtures/apps (읽기 전용).
    static var apps: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }  // Tests/MacHostKitTests/Support.swift → Packages
        return u.appendingPathComponent("RemoteDebugKit/Fixtures/apps", isDirectory: true)
    }

    static func app(_ relative: String) -> URL { apps.appendingPathComponent(relative, isDirectory: true) }
}

/// 가짜 `.app`: Info.plist(CFBundleExecutable) + 실행 파일 + 고유 내용.
@discardableResult
func makeFakeApp(at url: URL, executable: String = "App", payload: String = UUID().uuidString, withInfoPlist: Bool = true) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    if withInfoPlist {
        let plist: [String: Any] = ["CFBundleExecutable": executable, "CFBundleIdentifier": "com.example.fake"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"))
    }
    try Data(payload.utf8).write(to: url.appendingPathComponent(executable))
    return url
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sampleDescriptor(bundleId: String, name: String = "Sample", now: Date = Date()) -> BuildDescriptor {
    BuildDescriptor(
        id: "",
        bundleId: bundleId,
        displayName: name,
        version: "1.0",
        buildNumber: "1",
        minOS: "26.0",
        debug: true,
        configuration: "Debug",
        configurationEvidence: .path,
        signing: .init(teamId: "TEAM000000", profileName: "Dev", profileExpires: now.addingTimeInterval(86_400 * 300),
                       provisionedDeviceCount: 1, getTaskAllow: true),
        ipa: .init(size: 0, sha256: ""),
        publishedAt: now
    )
}

func sampleDevice(_ n: Int) -> DeviceEntry {
    DeviceEntry(id: "d_\(n)", name: "iPhone \(n)", nodeStableId: "nStable\(n)", nodeName: "rd-phone-\(n)",
                loginName: "user@example.com", pairedAt: Date(timeIntervalSince1970: 1_800_000_000))
}

/// 조건이 참이 될 때까지 짧게 양보한다(최대 약 2초).
func eventually(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

struct FakeError: Error, Equatable {}

/// 메모리에만 저장하는 UserDefaults. `UserDefaults(suiteName:)`는 ~/Library/Preferences에 파일을 남긴다.
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

/// 테스트가 열 때까지 기다리게 하는 문.
actor Gate {
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
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }
}

// MARK: 가짜 코어

final class FakeHostCore: HostCore {
    enum Call: Equatable, Sendable {
        case start(CoreConfig)
        case stop
        case status
        case publish(PublishRequest)
        case unpublish(String)
        case setDevices([DeviceEntry])
        case setDirect(Bool)
        case openPairing(Int)
        case decide(String, Bool)
    }

    struct State {
        var calls: [Call] = []
        var status = CoreStatus(backendState: .running, hostname: "rd-mac-test", fqdn: "rd-mac-test.example.ts.net",
                                certDomains: ["rd-mac-test.example.ts.net"], tlsReady: true, listening: true)
        var failStart = false
        var failPublish = false
        /// 게시 취소가 `build_not_found` 밖의 오류로 실패한다.
        var failUnpublish = false
        var failSetDevices = false
        var failSetDirect = false
        /// `start` 호출마다 하나씩 꺼내 그 문이 열릴 때까지 멈춘다.
        var startGates: [Gate] = []
        /// `decidePairing` 호출마다 하나씩 꺼내 그 문이 열릴 때까지 멈춘다.
        var decideGates: [Gate] = []
        /// `setDevices` 호출마다 하나씩 꺼내 그만큼 기다린 뒤 적용한다.
        var setDevicesDelays: [Duration] = []
        /// 실제로 적용된(호출이 끝난) 순서.
        var appliedDevices: [[DeviceEntry]] = []
        /// 코어가 들고 있는 게시본 id.
        var publishedIDs: Set<String> = []
        /// 코어가 들고 있는 공유 파일.
        var resources: [String: ResourcePublishRequest] = [:]
        /// 코어가 아는 페어링 요청(pending).
        var pendingRequests: Set<String> = []
        /// `stop` 때 스트림을 끝내기 전에 보낼 이벤트(rd_stop의 세션 failed 등).
        var stopEvents: [CoreEvent] = []
        var pairing = PairingCode(code: "K7M29QXD", expiresAt: Date().addingTimeInterval(300))
        var approvedDevice: DeviceEntry? = sampleDevice(1)
        var continuation: AsyncStream<CoreEvent>.Continuation?
    }

    let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }
    var published: [PublishRequest] { calls.compactMap { if case .publish(let r) = $0 { r } else { nil } } }
    var unpublished: [String] { calls.compactMap { if case .unpublish(let id) = $0 { id } else { nil } } }
    var setDevicesCalls: [[DeviceEntry]] { calls.compactMap { if case .setDevices(let d) = $0 { d } else { nil } } }
    var startConfigs: [CoreConfig] { calls.compactMap { if case .start(let c) = $0 { c } else { nil } } }
    var stopCount: Int { calls.filter { $0 == .stop }.count }
    var decideCalls: [String] { calls.compactMap { if case .decide(let id, _) = $0 { id } else { nil } } }

    private func record(_ call: Call) { state.withLock { $0.calls.append(call) } }

    func emit(_ event: CoreEvent) {
        if case .pairRequest(let e) = event { registerRequest(e.requestId) }
        _ = state.withLock { $0.continuation }?.yield(event)
    }

    func registerRequest(_ id: String) {
        state.withLock { _ = $0.pendingRequests.insert(id) }
    }

    func start(_ config: CoreConfig) async throws {
        record(.start(config))
        let gate = state.withLock { $0.startGates.isEmpty ? nil : $0.startGates.removeFirst() }
        if let gate { await gate.wait() }
        if state.withLock({ $0.failStart }) { throw FakeError() }
    }

    func stop() async {
        record(.stop)
        let (continuation, events) = state.withLock { s in
            defer {
                s.publishedIDs = []
                s.resources = [:]
            }
            return (s.continuation, s.stopEvents)
        }
        for e in events { continuation?.yield(e) }
        continuation?.finish()
    }

    func status() async throws -> CoreStatus {
        record(.status)
        return state.withLock { $0.status }
    }

    func publish(_ request: PublishRequest) async throws {
        record(.publish(request))
        if state.withLock({ $0.failPublish }) { throw APIErrorBody(code: "internal", message: "사본을 만들지 못했습니다") }
        state.withLock { _ = $0.publishedIDs.insert(request.build.id) }
    }

    func unpublish(buildID: String) async throws {
        record(.unpublish(buildID))
        if state.withLock({ $0.failUnpublish }) { throw APIErrorBody(code: "internal", message: "사본을 지우지 못했습니다") }
        let held = state.withLock { $0.publishedIDs.remove(buildID) != nil }
        if !held { throw APIErrorBody(code: "build_not_found", message: "빌드가 없습니다.") }
    }

    func publishResource(_ request: ResourcePublishRequest) async throws {
        state.withLock { $0.resources[request.resource.id] = request }
    }

    func unpublishResource(id: String) async throws {
        let held = state.withLock { $0.resources.removeValue(forKey: id) != nil }
        if !held { throw APIErrorBody(code: "resource_not_found", message: "파일이 없습니다.") }
    }

    var coreResources: [String: ResourcePublishRequest] { state.withLock { $0.resources } }

    func setDevices(_ devices: [DeviceEntry]) async throws {
        record(.setDevices(devices))
        let delay = state.withLock { $0.setDevicesDelays.isEmpty ? Duration.zero : $0.setDevicesDelays.removeFirst() }
        if delay > .zero { try await Task.sleep(for: delay) }
        if state.withLock({ $0.failSetDevices }) { throw APIErrorBody(code: "not_running", message: "") }
        state.withLock { $0.appliedDevices.append(devices) }
    }

    /// 실제 코어처럼 상태의 `direct`를 바꾼다.
    func setDirect(_ on: Bool) async throws {
        record(.setDirect(on))
        if state.withLock({ $0.failSetDirect }) { throw APIErrorBody(code: "internal", message: "port") }
        state.withLock { $0.status.direct = DirectStatus(listening: on, port: 49152, id: "0123456789abcdef") }
    }

    func openPairing(ttlSeconds: Int) async throws -> PairingCode {
        record(.openPairing(ttlSeconds))
        return state.withLock { $0.pairing }
    }

    /// 코어처럼: 모르는 요청이나 이미 처리한 요청은 bad_request.
    func decidePairing(requestID: String, allow: Bool) async throws -> DeviceEntry? {
        record(.decide(requestID, allow))
        let gate = state.withLock { $0.decideGates.isEmpty ? nil : $0.decideGates.removeFirst() }
        if let gate { await gate.wait() }
        let known = state.withLock { $0.pendingRequests.remove(requestID) != nil }
        guard known else { throw APIErrorBody(code: "bad_request", message: "알 수 없는 페어링 요청입니다.") }
        return allow ? state.withLock { $0.approvedDevice } : nil
    }

    func events() -> AsyncStream<CoreEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoreEvent.self)
        state.withLock { $0.continuation = continuation }
        return stream
    }
}

// MARK: 가짜 검사기·패키저

/// `FakePackager`가 만드는 "IPA": `.app` 이름과 파일 내용을 담은 JSON.
struct FakeArchive: Codable {
    var app: String
    var files: [String: Data]

    static func read(_ url: URL) -> FakeArchive? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FakeArchive.self, from: data)
    }
}

/// 이름에 `Reject`가 들어 있으면 거부, `Unreadable`이면 읽기 오류, 아니면 수락.
/// `.app`은 경로 이름과 안의 `bundle-id` 파일(없으면 `com.example.app`)을, `.ipa`는 `FakeArchive`면 그 안의 앱 이름과
/// `bundle-id`를(아니면 파일 이름과 기본 bundle id) 쓴다.
final class FakeInspector: BuildInspecting {
    struct Stats {
        var current = 0
        var maxConcurrent = 0
        var count = 0
    }

    typealias Hook = @Sendable (URL) async -> Void

    struct Hooks {
        /// 검사 직전(앞)·직후(뒤)에 부른다. 인자는 검사한 경로.
        var beforeApp: Hook?
        var afterApp: Hook?
        var beforeIPA: Hook?
        var afterIPA: Hook?
        /// 검사를 멈춰 둘 문(검사마다 한 번씩 기다린다).
        var gate: Gate?
        /// IPA 검사 결과의 bundle id를 바꾼다.
        var ipaBundleOverride: String?
        /// 거부하면서도 descriptor를 채운다(수락 여부만 보고 판단해야 함을 확인).
        var rejectWithDescriptor = false
        /// IPA 검사만 위처럼 거부한다(폴더 검사는 수락).
        var rejectIPAWithDescriptor = false
        /// 사용자 확인이 없으면 `configurationUnverified`로만 거부한다.
        var unverifiedUnlessConfirmed = false
        /// 결과의 버전을 바꾼다.
        var versionOverride: String?
        /// 결과의 빌드 번호를 바꾼다.
        var buildNumberOverride: String?
    }

    let stats = Mutex(Stats())
    let hooks = Mutex(Hooks())
    let delay: Duration

    init(delay: Duration = .zero) { self.delay = delay }

    var maxConcurrent: Int { stats.withLock { $0.maxConcurrent } }
    var count: Int { stats.withLock { $0.count } }

    func inspect(appAt url: URL, options: InspectionOptions) async throws -> InspectionResult {
        let h = hooks.withLock { $0 }
        await h.beforeApp?(url)
        let bundleId = (try? String(contentsOf: url.appendingPathComponent("bundle-id"), encoding: .utf8)) ?? "com.example.app"
        let result = try await run(name: url.lastPathComponent, bundleId: bundleId, options: options, ipaDigest: nil, hooks: h)
        await h.afterApp?(url)
        return result
    }

    func inspect(ipaAt url: URL, options: InspectionOptions, workDirectory: URL) async throws -> InspectionResult {
        let h = hooks.withLock { $0 }
        await h.beforeIPA?(url)
        let data = try Data(contentsOf: url)
        var name = url.lastPathComponent
        var bundleId = "com.example.app"
        if let archive = try? JSONDecoder().decode(FakeArchive.self, from: data) {
            name = archive.app
            if let b = archive.files["bundle-id"] { bundleId = String(decoding: b, as: UTF8.self) }
        }
        if let o = h.ipaBundleOverride { bundleId = o }
        var runHooks = h
        if h.rejectIPAWithDescriptor { runHooks.rejectWithDescriptor = true }
        let result = try await run(name: name, bundleId: bundleId, options: options,
                                   ipaDigest: FileDigest(size: Int64(data.count), sha256: sha256Hex(data)), hooks: runHooks)
        await h.afterIPA?(url)
        return result
    }

    private func run(name: String, bundleId: String, options: InspectionOptions, ipaDigest: FileDigest?, hooks h: Hooks) async throws -> InspectionResult {
        stats.withLock {
            $0.current += 1
            $0.count += 1
            $0.maxConcurrent = max($0.maxConcurrent, $0.current)
        }
        defer { stats.withLock { $0.current -= 1 } }
        if let gate = h.gate { await gate.wait() }
        if delay > .zero { try await Task.sleep(for: delay) }
        for _ in 0..<20 { await Task.yield() }

        if name.contains("Unreadable") { throw InspectionError.unreadable("테스트") }
        var d = sampleDescriptor(bundleId: bundleId, name: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, now: options.now)
        if let ipaDigest { d = d.withIPA(size: ipaDigest.size, sha256: ipaDigest.sha256) }
        if let v = h.versionOverride { d.version = v }
        if let b = h.buildNumberOverride { d.buildNumber = b }
        if h.unverifiedUnlessConfirmed, !options.confirmedDebug {
            return InspectionResult(accepted: false, reasons: [Rejection(code: .configurationUnverified, detail: "")],
                                    warnings: [], descriptor: nil, bundleId: bundleId)
        }
        if name.contains("Reject") || h.rejectWithDescriptor {
            return InspectionResult(accepted: false, reasons: [
                Rejection(code: .configurationNotDebug, detail: "빌드 폴더의 구성이 Release입니다"),
                Rejection(code: .getTaskAllowMissing, detail: ""),
            ], warnings: [], descriptor: h.rejectWithDescriptor ? d : nil, bundleId: bundleId)
        }
        return InspectionResult(accepted: true, reasons: [], warnings: [], descriptor: d, bundleId: bundleId)
    }
}

/// `.app`의 파일 이름과 내용을 `FakeArchive` JSON으로 묶어 "IPA"로 쓴다.
final class FakePackager: BuildPackaging {
    struct Hooks {
        /// 이 경로의 해시는 이 오류로 실패한다.
        var digestError: (@Sendable (URL) -> (any Error)?)?
    }

    let hooks = Mutex(Hooks())

    func package(appAt appURL: URL, to ipaURL: URL) async throws -> FileDigest {
        let fm = FileManager.default
        let root = appURL.standardizedFileURL.resolvingSymlinksInPath()
        var files: [String: Data] = [:]
        for n in try fm.contentsOfDirectory(atPath: root.path) {
            files[n] = (try? Data(contentsOf: root.appendingPathComponent(n))) ?? Data()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(FakeArchive(app: root.lastPathComponent, files: files))
        try data.write(to: ipaURL)
        return FileDigest(size: Int64(data.count), sha256: sha256Hex(data))
    }

    func digest(of fileURL: URL) async throws -> FileDigest {
        if let error = hooks.withLock({ $0.digestError })?(fileURL) { throw error }
        let data = try Data(contentsOf: fileURL)
        return FileDigest(size: Int64(data.count), sha256: sha256Hex(data))
    }
}

final class FakeBookmarks: FolderBookmarking {
    let stored = Mutex<URL?>(nil)
    /// 저장된 폴더를 읽은 횟수(불러오기가 끝날 때마다 한 번).
    let resolveCount = Mutex(0)

    func save(_ url: URL) throws { stored.withLock { $0 = url } }
    func resolve() -> URL? {
        resolveCount.withLock { $0 += 1 }
        return stored.withLock { $0 }
    }
    func clear() { stored.withLock { $0 = nil } }
}

/// 디바운스 테스트용: `sleep`이 실제로 기다리지 않고 `releaseAll()`까지 멈춰 있다.
actor ManualSleeper {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [Duration] = []

    var pendingCount: Int { waiting.count }

    func sleep(_ d: Duration) async {
        requested.append(d)
        await withCheckedContinuation { waiting.append($0) }
    }

    func releaseAll() {
        let w = waiting
        waiting = []
        w.forEach { $0.resume() }
    }
}

/// 가짜 앱 하나를 `<root>/<name>.app`에 만든다. bundle id를 적어 둔다.
@discardableResult
func makeImportableApp(in dir: URL, name: String, bundleId: String = "com.example.app") throws -> URL {
    let app = try makeFakeApp(at: dir.appendingPathComponent("\(name).app"))
    try Data(bundleId.utf8).write(to: app.appendingPathComponent("bundle-id"))
    return app
}
