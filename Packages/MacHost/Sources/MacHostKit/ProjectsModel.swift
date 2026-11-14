import Foundation
import Observation
import RDModels

/// 연결한 프로젝트 목록, 스킴 빌드, Xcode 빌드 감시, 에이전트 명령 처리.
///
/// 빌드 결과는 Xcode와 같은 DerivedData에서 찾는다. 그래서 이 앱이 시작한 빌드와 Xcode에서 한 빌드를 같은 방법으로 가져온다.
@MainActor
@Observable
public final class ProjectsModel {
    /// Xcode에서 기기용 Debug 빌드가 감지된, 아직 연결하지 않은 프로젝트.
    public struct Suggestion: Sendable, Hashable, Identifiable {
        public var container: String
        public var id: String { container }
        public var name: String { URL(fileURLWithPath: container).deletingPathExtension().lastPathComponent }
    }

    public enum Phase: Sendable, Hashable {
        case loadingSchemes
        case building(scheme: String)
        case importing
    }

    public struct Published: Codable, Sendable, Hashable {
        public var buildId: String
        public var bundleId: String
        public var name: String
        public var version: String
        public var buildNumber: String
    }

    /// 마지막 빌드·가져오기 결과.
    public struct Report: Codable, Sendable, Hashable {
        public var ok: Bool
        public var scheme: String?
        public var published: [Published] = []
        public var message: String?
        public var logTail: String?
        public var logPath: String?
    }

    public struct HostStatus: Sendable {
        public var sharing: Bool
        public var installPage: String?
        /// 공식 Tailscale로 여는 iPhone 앱 업데이트 페이지.
        public var updatePage: String?

        public init(sharing: Bool, installPage: String?, updatePage: String? = nil) {
            self.sharing = sharing
            self.installPage = installPage
            self.updatePage = updatePage
        }
    }

    /// 에이전트가 연 페어링 코드(`pair` 명령).
    public struct PairingInfo: Codable, Sendable, Hashable {
        /// 화면 표시용 `K7M2-9QXD`.
        public var code: String
        /// iPhone RemoteDebug 앱을 여는 `remotedebug://pair?host=…&code=…`.
        public var link: String?
        /// 앱 없이 Safari로 페어링하는 설치 페이지(`https://<fqdn>/#code=…`).
        public var installPage: String?
        public var expiresAt: Date

        public init(code: String, link: String?, installPage: String?, expiresAt: Date) {
            self.code = code
            self.link = link
            self.installPage = installPage
            self.expiresAt = expiresAt
        }
    }

    public struct PairingFailure: Error, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    public typealias PairingOpener = @MainActor () async -> Result<PairingInfo, PairingFailure>

    /// 허용을 기다리는 페어링 요청(에이전트 `requests` 명령).
    public struct PairRequestInfo: Codable, Sendable, Hashable {
        public var requestId: String
        /// iPhone이 보낸 이름.
        public var deviceName: String
        /// tailnet이 알려 준 노드 이름(RemoteDebug 앱이면 `rd-phone-…`).
        public var nodeName: String
        public var loginName: String
        public var expiresAt: Date

        public init(requestId: String, deviceName: String, nodeName: String, loginName: String, expiresAt: Date) {
            self.requestId = requestId
            self.deviceName = deviceName
            self.nodeName = nodeName
            self.loginName = loginName
            self.expiresAt = expiresAt
        }
    }

    /// 에이전트가 페어링 요청을 보고 답하는 통로.
    public struct PairingRequests: Sendable {
        public var list: @MainActor () -> [PairRequestInfo]
        /// 답한 뒤 실패 안내. 성공하면 nil.
        public var decide: @MainActor (_ requestId: String, _ allow: Bool) async -> String?

        public init(list: @escaping @MainActor () -> [PairRequestInfo],
                    decide: @escaping @MainActor (_ requestId: String, _ allow: Bool) async -> String?) {
            self.list = list
            self.decide = decide
        }

        public static let unavailable = PairingRequests(list: { [] }, decide: { _, _ in String(localized: "페어링 요청에 답할 수 없습니다.") })
    }

    /// 에이전트가 iPhone에 파일을 보내는 통로.
    public struct FileSharing: Sendable {
        public var list: @MainActor () -> [ResourceDescriptor]
        /// 둘째 값은 넣을 구역(nil이면 공통). 실패하면 안내 문구.
        public var share: @MainActor (URL, ResourceProject?) async -> Result<ResourceDescriptor, ShareFileFailure>
        public var remove: @MainActor (String) async -> Void
        /// 주소, 이름(선택), 구역(nil이면 공통).
        public var shareLink: @MainActor (URL, String?, ResourceProject?) async -> Result<ResourceDescriptor, ShareFileFailure>

        public init(list: @escaping @MainActor () -> [ResourceDescriptor],
                    share: @escaping @MainActor (URL, ResourceProject?) async -> Result<ResourceDescriptor, ShareFileFailure>,
                    remove: @escaping @MainActor (String) async -> Void,
                    shareLink: @escaping @MainActor (URL, String?, ResourceProject?) async -> Result<ResourceDescriptor, ShareFileFailure> = { _, _, _ in .failure(ShareFileFailure(String(localized: "링크를 보낼 수 없습니다."))) }) {
            self.list = list
            self.share = share
            self.remove = remove
            self.shareLink = shareLink
        }

        public static let unavailable = FileSharing(list: { [] }, share: { _, _ in .failure(ShareFileFailure(String(localized: "파일을 보낼 수 없습니다."))) }, remove: { _ in })
    }

    public typealias Importer = @MainActor (URL) async -> ImportOutcome?

    struct Stored: Codable, Sendable {
        var projects: [ConnectedProject] = []
        /// "등록하지 않음"을 고른 프로젝트.
        var dismissed: [String] = []
        /// 이미 가져온 빌드의 지문(`.app` 경로 → 지문).
        var imported: [String: BuildFingerprint] = [:]
    }

    public private(set) var projects: [ConnectedProject] = []
    public private(set) var suggestions: [Suggestion] = []
    public private(set) var schemes: [String: [String]] = [:]
    public private(set) var phases: [String: Phase] = [:]
    public private(set) var reports: [String: Report] = [:]
    public var lastError: String?
    /// Xcode 빌드 폴더(DerivedData) 읽기가 10초 넘게 끝나지 않고 있다.
    public private(set) var scanStalled = false
    public var derivedDataPath: String { scanner.root.path }
    @ObservationIgnored private var scanStarted: Date?
    /// 새 등록 제안이 생기면 부른다(시스템 알림용).
    @ObservationIgnored public var onSuggestion: (@MainActor (Suggestion) -> Void)?

    @ObservationIgnored private let file: JSONFile<Stored>
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let builder: any ProjectBuilding
    @ObservationIgnored private let scanner: DerivedDataScanner
    @ObservationIgnored private let importer: Importer
    @ObservationIgnored private let hostStatus: @MainActor () -> HostStatus
    @ObservationIgnored private let openPairing: PairingOpener
    @ObservationIgnored private let pairingRequests: PairingRequests
    @ObservationIgnored private let fileSharing: FileSharing
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var stored = Stored()
    @ObservationIgnored private var isLoaded = false
    /// 연결하지 않은 프로젝트의 마지막 빌드 활동 시각. 처음 본 값은 기준으로만 쓴다.
    @ObservationIgnored private var seenActivity: [String: Date] = [:]
    /// 지문이 같은 채로 이어진 검사 횟수(빌드가 끝났는지 본다).
    @ObservationIgnored private var settling: [String: (fingerprint: BuildFingerprint, count: Int)] = [:]
    @ObservationIgnored private var agentRequestsInFlight: Set<String> = []
    @ObservationIgnored private var monitor: Task<Void, Never>?

    /// `root`는 호스트 저장 폴더(`HostPaths.root`)다.
    public init(
        root: URL,
        builder: any ProjectBuilding = XcodeBuildTool(),
        scanner: DerivedDataScanner = .fromXcodeSettings(),
        hostStatus: @escaping @MainActor () -> HostStatus = { HostStatus(sharing: false, installPage: nil) },
        openPairing: @escaping PairingOpener = { .failure(PairingFailure(String(localized: "페어링을 열 수 없습니다."))) },
        pairingRequests: PairingRequests = .unavailable,
        fileSharing: FileSharing = .unavailable,
        now: @escaping @Sendable () -> Date = { Date() },
        importer: @escaping Importer
    ) {
        self.root = root
        self.file = JSONFile(url: root.appendingPathComponent("projects.json"))
        self.builder = builder
        self.scanner = scanner
        self.hostStatus = hostStatus
        self.openPairing = openPairing
        self.pairingRequests = pairingRequests
        self.fileSharing = fileSharing
        self.now = now
        self.importer = importer
    }

    public var agentDir: URL { root.appendingPathComponent("agent", isDirectory: true) }
    public var agentScript: URL { agentDir.appendingPathComponent("rd") }
    var logsDir: URL { root.appendingPathComponent("ProjectLogs", isDirectory: true) }

    public func load() {
        guard !isLoaded else { return }
        isLoaded = true
        do {
            stored = try file.load() ?? Stored()
        } catch {
            lastError = String(localized: "프로젝트 목록을 읽지 못했습니다: \(HostErrorText.message(for: error))")
        }
        projects = stored.projects
    }

    private func save() {
        stored.projects = projects
        do {
            try file.save(stored)
        } catch {
            lastError = String(localized: "프로젝트 목록을 저장하지 못했습니다: \(HostErrorText.message(for: error))")
        }
    }

    // MARK: 연결

    /// 프로젝트 파일이나 폴더를 연결한다. 이미 연결돼 있으면 그 항목을 돌려준다.
    @discardableResult
    public func connect(_ url: URL) async -> ConnectedProject? {
        load()
        guard let container = await Self.offMain({ ProjectLocator.container(for: url) }) else {
            lastError = String(localized: "\(url.lastPathComponent)에서 Xcode 프로젝트(.xcodeproj, .xcworkspace)를 찾지 못했습니다.")
            return nil
        }
        if let existing = projects.first(where: { $0.container == container.path }) { return existing }
        let project = ConnectedProject(container: container.path, addedAt: now())
        projects.append(project)
        suggestions.removeAll { $0.container == project.container }
        stored.dismissed.removeAll { $0 == project.container }
        save()
        return project
    }

    /// 연결한 뒤 스킴을 읽고, 빌드할 스킴이 정해지면 바로 빌드한다.
    public func connectAndBuild(_ url: URL) async {
        guard let project = await connect(url) else { return }
        await loadSchemes(for: project)
        if let scheme = preferredScheme(for: project) {
            await build(project, scheme: scheme)
        }
    }

    public func remove(_ project: ConnectedProject) {
        projects.removeAll { $0.id == project.id }
        schemes[project.id] = nil
        reports[project.id] = nil
        save()
    }

    /// 마지막에 쓴 스킴, 스킴이 하나면 그것, 아니면 프로젝트와 이름이 같은 스킴.
    public func preferredScheme(for project: ConnectedProject) -> String? {
        let list = schemes[project.id] ?? []
        if let saved = currentProject(project.id)?.scheme, list.contains(saved) { return saved }
        if list.count == 1 { return list[0] }
        return list.first { $0 == project.name }
    }

    private func currentProject(_ id: String) -> ConnectedProject? {
        projects.first { $0.id == id }
    }

    @discardableResult
    public func loadSchemes(for project: ConnectedProject) async -> [String] {
        guard phases[project.id] == nil else { return schemes[project.id] ?? [] }
        phases[project.id] = .loadingSchemes
        defer { phases[project.id] = nil }
        do {
            let list = try await builder.schemes(container: project.containerURL)
            schemes[project.id] = list
            return list
        } catch {
            reports[project.id] = Report(ok: false, message: HostErrorText.message(for: error))
            return []
        }
    }

    // MARK: 빌드

    /// 스킴을 Debug 기기용으로 빌드하고, 만들어진 앱을 가져와 게시한다.
    @discardableResult
    public func build(_ project: ConnectedProject, scheme: String) async -> Report {
        if phases[project.id] != nil {
            return Report(ok: false, scheme: scheme, message: String(localized: "이 프로젝트는 이미 작업 중입니다."))
        }
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].scheme = scheme
            save()
        }
        phases[project.id] = .building(scheme: scheme)
        defer { phases[project.id] = nil }
        let log = logsDir.appendingPathComponent("\(project.name).log")
        var report: Report
        do {
            try await builder.build(container: project.containerURL, scheme: scheme, log: log)
            phases[project.id] = .importing
            let built = try await builder.products(container: project.containerURL, scheme: scheme)
            report = await importProducts(of: project, finished: true, built: built)
            report.scheme = scheme
        } catch let failure as ProjectBuildFailure {
            report = Report(ok: false, scheme: scheme, message: failure.message, logTail: failure.logTail)
        } catch {
            report = Report(ok: false, scheme: scheme, message: HostErrorText.message(for: error))
        }
        report.logPath = log.path
        reports[project.id] = report
        return report
    }

    /// 프로젝트의 DerivedData에서 `Debug-iphoneos/*.app`을 가져온다.
    /// `finished`가 false면(Xcode가 빌드 중일 수 있다) 서명이 끝났거나 지문이 여러 번 그대로일 때만 가져온다.
    private func importProducts(of project: ConnectedProject, finished: Bool, built: [URL] = []) async -> Report {
        let scanner = self.scanner
        let container = project.container
        // 파일 읽기는 메인 스레드 밖에서 한다(외장 디스크나 권한 확인 창에서 멈출 수 있다).
        let candidates = await Self.offMain { () -> [Candidate] in
            // 방금 빌드했으면 xcodebuild가 알려 준 위치만 본다. 감시할 때는 Xcode 설정에서 계산한 위치를 본다.
            let apps = built.isEmpty
                ? scanner.entries().filter { $0.workspacePath == container && $0.hasDeviceDebug }.flatMap { Self.apps(in: $0.debugProducts) }
                : built
            return apps.compactMap { app in
                    guard case .ready(let fingerprint) = FolderScanner.state(of: app) else { return nil }
                    let signature = DerivedDataScanner.modified(app.appendingPathComponent("_CodeSignature/CodeResources"))
                    return Candidate(app: app, fingerprint: fingerprint, signed: signature.map { $0 >= fingerprint.executableModified } ?? false)
                }
        }
        var report = Report(ok: true)
        var sawApp = false
        var rejections: [String] = []
        for candidate in candidates {
            let app = candidate.app
            let fingerprint = candidate.fingerprint
            sawApp = true
            if stored.imported[app.path] == fingerprint { continue }
            if !finished, !isSettled(candidate) { continue }
            settling[app.path] = nil
            let outcome = await importer(app)
            // 가져오기가 실패했으면(nil) 지문을 기억하지 않아 다음에 다시 본다.
            guard let outcome else { continue }
            stored.imported[app.path] = fingerprint
            switch outcome {
            case .accepted(let build):
                let d = build.descriptor
                report.published.append(Published(buildId: d.id, bundleId: d.bundleId, name: d.displayName, version: d.version, buildNumber: d.buildNumber))
            case .rejected(let rejected):
                rejections.append("\(app.lastPathComponent): " + rejected.reasons.map(RejectionText.sentence(for:)).joined(separator: " "))
            case .needsConfirmation:
                rejections.append(String(localized: "\(app.lastPathComponent): Debug 구성인지 확인할 수 없습니다."))
            }
        }
        if !report.published.isEmpty || !rejections.isEmpty { save() }
        guard finished else {
            if !rejections.isEmpty {
                report.ok = false
                report.message = rejections.joined(separator: "\n")
            }
            return report
        }
        if !rejections.isEmpty {
            report.ok = !report.published.isEmpty
            report.message = rejections.joined(separator: "\n")
        } else if !sawApp {
            report.ok = false
            report.message = String(localized: "빌드는 끝났지만 iPhone 앱을 찾지 못했습니다. iPhone 앱을 만드는 스킴인지 확인하세요.")
        } else if report.published.isEmpty {
            report.message = String(localized: "빌드 결과가 전과 같습니다. 이미 가져온 빌드입니다.")
        }
        return report
    }

    nonisolated static func apps(in products: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "app" && !$0.deletingPathExtension().lastPathComponent.hasSuffix("-Runner") }
            .sorted { $0.path < $1.path }
    }

    /// 서명 파일이 실행 파일보다 늦게 쓰였고 지문이 한 번 그대로였거나, 지문이 네 번 그대로였으면 끝난 빌드로 본다.
    private func isSettled(_ candidate: Candidate) -> Bool {
        let fingerprint = candidate.fingerprint
        var entry = settling[candidate.app.path] ?? (fingerprint, 0)
        entry = entry.fingerprint == fingerprint ? (fingerprint, entry.count + 1) : (fingerprint, 1)
        settling[candidate.app.path] = entry
        return (candidate.signed && entry.count >= 2) || entry.count >= 4
    }

    private struct Candidate: Sendable {
        var app: URL
        var fingerprint: BuildFingerprint
        var signed: Bool
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility, operation: work).value
    }

    // MARK: Xcode 감시

    /// DerivedData를 한 번 훑는다. 연결한 프로젝트는 새 빌드를 가져오고, 연결하지 않은 프로젝트에서
    /// 기기용 Debug 빌드 활동이 새로 보이면 등록을 제안한다.
    public func scanXcode() async {
        load()
        let scanner = self.scanner
        let (entries, existing) = await Self.offMain { () -> ([DerivedDataEntry], Set<String>) in
            let entries = scanner.entries()
            return (entries, Set(entries.map(\.workspacePath).filter { FileManager.default.fileExists(atPath: $0) }))
        }
        for entry in entries where entry.hasDeviceDebug {
            if projects.contains(where: { $0.container == entry.workspacePath }) { continue }
            guard let activity = entry.activity else { continue }
            let previous = seenActivity[entry.dir.path]
            seenActivity[entry.dir.path] = activity
            guard let previous, activity > previous else { continue }
            let suggestion = Suggestion(container: entry.workspacePath)
            guard !stored.dismissed.contains(suggestion.container), !suggestions.contains(suggestion),
                  existing.contains(suggestion.container)
            else { continue }
            suggestions.append(suggestion)
            onSuggestion?(suggestion)
        }
        // 처음 훑을 때 Debug-iphoneos가 없던 프로젝트도 기준을 잡아 둔다(폴더가 생기는 것이 곧 빌드 시작이다).
        for entry in entries where !entry.hasDeviceDebug && seenActivity[entry.dir.path] == nil {
            seenActivity[entry.dir.path] = entry.activity ?? .distantPast
        }
        for project in projects where phases[project.id] == nil {
            let report = await importProducts(of: project, finished: false)
            if !report.published.isEmpty || report.message != nil { reports[project.id] = report }
        }
    }

    /// 제안을 받아들여 연결한다. 이미 만들어진 빌드가 있으면 다음 검사에서 가져온다.
    @discardableResult
    public func register(_ suggestion: Suggestion) async -> ConnectedProject? {
        await connect(URL(fileURLWithPath: suggestion.container))
    }

    /// 이 프로젝트는 다시 제안하지 않는다.
    public func dismiss(_ suggestion: Suggestion) {
        suggestions.removeAll { $0 == suggestion }
        if !stored.dismissed.contains(suggestion.container) { stored.dismissed.append(suggestion.container) }
        save()
    }

    /// 1초마다 에이전트 요청을 처리하고 3초마다 DerivedData를 훑는다.
    public func startMonitoring() {
        guard monitor == nil else { return }
        load()
        installAgentScript()
        monitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.processAgentRequests()
                // 폴더 읽기가 멈춰도(외장 디스크, 권한 확인) 에이전트 명령은 계속 받는다.
                if let started = self.scanStarted {
                    if !self.scanStalled, self.now().timeIntervalSince(started) > 10 { self.scanStalled = true }
                } else if tick % 3 == 0 {
                    self.scanStarted = self.now()
                    Task {
                        await self.scanXcode()
                        self.scanStarted = nil
                        self.scanStalled = false
                    }
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
        try? FileManager.default.removeItem(at: agentDir.appendingPathComponent("pid"))
    }

    // MARK: 에이전트

    struct AgentResponse: Codable {
        var ok: Bool
        var error: String?
        var sharing: Bool?
        var installPage: String?
        var updatePage: String?
        var projects: [AgentProject]?
        var schemes: [String]?
        var report: Report?
        var pairing: PairingInfo?
        var requests: [PairRequestInfo]?
        var file: ResourceDescriptor?
        var files: [ResourceDescriptor]?
    }

    struct AgentProject: Codable {
        var container: String
        var name: String
        var scheme: String?
    }

    var requestsDir: URL { agentDir.appendingPathComponent("requests", isDirectory: true) }
    var responsesDir: URL { agentDir.appendingPathComponent("responses", isDirectory: true) }

    /// 에이전트가 부르는 명령 스크립트(`rd`)와 요청·응답 폴더를 만든다. 요청은 이 사용자만 쓸 수 있다.
    public func installAgentScript(bundleID: String = Bundle.main.bundleIdentifier ?? "com.oozoofrog.app.RemoteDebugMac") {
        let fm = FileManager.default
        do {
            for dir in [agentDir, requestsDir, responsesDir] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            // 전에 남은 요청은 처리하지 않는다(보낸 쪽이 이미 없다).
            for dir in [requestsDir, responsesDir] {
                for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: item) }
            }
            try Data(AgentScript.text(agentDir: agentDir.path, bundleID: bundleID).utf8).write(to: agentScript, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentScript.path)
            try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: agentDir.appendingPathComponent("pid"), options: [.atomic])
        } catch {
            lastError = String(localized: "에이전트 명령을 준비하지 못했습니다: \(HostErrorText.message(for: error))")
        }
    }

    /// 요청 폴더의 새 요청을 각각 따로 처리한다(빌드가 도는 동안에도 다른 명령에 답한다).
    func processAgentRequests() {
        let items = (try? FileManager.default.contentsOfDirectory(at: requestsDir, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.pathExtension == "req" {
            let id = item.deletingPathExtension().lastPathComponent
            guard agentRequestsInFlight.insert(id).inserted else { continue }
            let text = (try? String(contentsOf: item, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: item)
            Task {
                let response = await self.handleAgentRequest(text)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(response) {
                    try? data.write(to: self.responsesDir.appendingPathComponent("\(id).json"), options: [.atomic])
                }
                self.agentRequestsInFlight.remove(id)
            }
        }
    }

    /// 에이전트가 넘긴 `project` 글자를 구역으로 바꾼다. 비었거나 "공통"이면 공통(nil)이다.
    /// 연결한 프로젝트의 이름(대소문자 무시), `.xcodeproj`·`.xcworkspace` 경로, 프로젝트 폴더 경로와 맞춘다.
    func resourceArea(named text: String) -> Result<ResourceProject?, ShareFileFailure> {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == ResourceArea.commonTitle { return .success(nil) }
        let available = projects.isEmpty
            ? "연결한 프로젝트가 없습니다. project를 비우면 공통 구역에 넣습니다."
            : "쓸 수 있는 프로젝트: \(projects.map(\.name).joined(separator: ", ")). project를 비우면 공통 구역에 넣습니다."
        if text.hasPrefix("/") {
            let path = URL(fileURLWithPath: text).standardizedFileURL.path
            if let found = projects.first(where: { $0.containerURL.standardizedFileURL.path == path })
                ?? projects.first(where: { $0.folder.standardizedFileURL.path == path }) {
                return .success(found.resourceArea)
            }
            return .failure(ShareFileFailure("연결한 프로젝트의 경로가 아닙니다: \(text). \(available)"))
        }
        let named = projects.filter { $0.name.compare(text, options: .caseInsensitive) == .orderedSame }
        switch named.count {
        case 1: return .success(named[0].resourceArea)
        case 0: return .failure(ShareFileFailure("연결한 프로젝트에 없는 이름입니다: \(text). \(available)"))
        default: return .failure(ShareFileFailure("이름이 \(text)인 프로젝트가 여러 개입니다. .xcodeproj나 .xcworkspace 경로로 정해 주세요: \(named.map(\.container).joined(separator: ", "))"))
        }
    }

    /// `files`의 구역 거르기. 연결을 끊은 프로젝트의 구역은 항목에 저장된 이름으로 찾는다.
    func resources(_ list: [ResourceDescriptor], inArea text: String) -> Result<[ResourceDescriptor], ShareFileFailure> {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .success(list) }
        switch resourceArea(named: text) {
        case .success(let area):
            return .success(list.filter { $0.project?.id == area?.id })
        case .failure(let failure):
            let stored = list.filter { $0.project?.name.compare(text, options: .caseInsensitive) == .orderedSame }
            return stored.isEmpty ? .failure(failure) : .success(stored)
        }
    }

    /// 요청은 줄 단위다: 명령, 경로, 스킴, 구역(push·link·files의 project).
    func handleAgentRequest(_ text: String) async -> AgentResponse {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let command = lines.first ?? ""
        let path = lines.count > 1 ? lines[1] : ""
        let scheme = lines.count > 2 ? lines[2] : ""
        let area = lines.count > 3 ? lines[3] : ""
        load()
        switch command {
        case "status", "projects":
            let host = hostStatus()
            return AgentResponse(ok: true, sharing: host.sharing, installPage: host.installPage, updatePage: host.updatePage,
                                 projects: projects.map { AgentProject(container: $0.container, name: $0.name, scheme: $0.scheme) })
        case "pair":
            // 코드만 연다. 허용은 지금처럼 Mac 화면에서만 한다.
            switch await openPairing() {
            case .success(let info):
                let host = hostStatus()
                return AgentResponse(ok: true, sharing: host.sharing, installPage: host.installPage, pairing: info)
            case .failure(let failure):
                return AgentResponse(ok: false, error: failure.message)
            }
        case "requests":
            return AgentResponse(ok: true, requests: pairingRequests.list())
        case "approve", "deny":
            // 요청 id는 둘째 줄로 받는다.
            guard !path.isEmpty else { return AgentResponse(ok: false, error: "요청 id가 필요합니다.") }
            guard pairingRequests.list().contains(where: { $0.requestId == path }) else {
                return AgentResponse(ok: false, error: "기다리는 요청이 아닙니다: \(path). 만료됐거나 이미 답했습니다.", requests: pairingRequests.list())
            }
            if let failure = await pairingRequests.decide(path, command == "approve") {
                return AgentResponse(ok: false, error: failure, requests: pairingRequests.list())
            }
            return AgentResponse(ok: true, requests: pairingRequests.list())
        case "push":
            // 둘째 줄이 보낼 파일 경로다.
            guard !path.isEmpty else { return AgentResponse(ok: false, error: "보낼 파일 경로가 필요합니다.") }
            let project: ResourceProject?
            switch resourceArea(named: area) {
            case .success(let found): project = found
            case .failure(let failure): return AgentResponse(ok: false, error: failure.message)
            }
            switch await fileSharing.share(URL(fileURLWithPath: path), project) {
            case .success(let file):
                let host = hostStatus()
                return AgentResponse(ok: true, sharing: host.sharing, file: file)
            case .failure(let failure):
                return AgentResponse(ok: false, error: failure.message)
            }
        case "link":
            // 둘째 줄이 주소, 셋째 줄이 이름(선택)이다.
            guard let url = URL(string: path.trimmingCharacters(in: .whitespaces)), url.scheme?.isEmpty == false else {
                return AgentResponse(ok: false, error: "스킴이 있는 주소가 필요합니다(https://…, 앱스킴://…).")
            }
            let project: ResourceProject?
            switch resourceArea(named: area) {
            case .success(let found): project = found
            case .failure(let failure): return AgentResponse(ok: false, error: failure.message)
            }
            switch await fileSharing.shareLink(url, scheme.isEmpty ? nil : scheme, project) {
            case .success(let file):
                return AgentResponse(ok: true, sharing: hostStatus().sharing, file: file)
            case .failure(let failure):
                return AgentResponse(ok: false, error: failure.message)
            }
        case "files":
            switch resources(fileSharing.list(), inArea: area) {
            case .success(let files): return AgentResponse(ok: true, sharing: hostStatus().sharing, files: files)
            case .failure(let failure): return AgentResponse(ok: false, error: failure.message)
            }
        case "unpush":
            guard !path.isEmpty else { return AgentResponse(ok: false, error: "파일 id가 필요합니다.") }
            guard fileSharing.list().contains(where: { $0.id == path }) else {
                return AgentResponse(ok: false, error: "보낸 파일 목록에 없는 id입니다: \(path)", files: fileSharing.list())
            }
            await fileSharing.remove(path)
            return AgentResponse(ok: true, files: fileSharing.list())
        case "connect", "schemes", "build":
            guard !path.isEmpty else { return AgentResponse(ok: false, error: "프로젝트 경로가 필요합니다.") }
            lastError = nil
            guard let project = await connect(URL(fileURLWithPath: path)) else {
                defer { lastError = nil }
                return AgentResponse(ok: false, error: lastError ?? "프로젝트를 연결하지 못했습니다.")
            }
            let list = await loadSchemes(for: project)
            if command != "build" {
                return AgentResponse(ok: true, projects: [AgentProject(container: project.container, name: project.name, scheme: project.scheme)], schemes: list)
            }
            guard let chosen = scheme.isEmpty ? preferredScheme(for: project) : scheme else {
                return AgentResponse(ok: false, error: "스킴을 정해 주세요.", schemes: list)
            }
            let report = await build(project, scheme: chosen)
            let host = hostStatus()
            return AgentResponse(ok: report.ok, error: report.ok ? nil : report.message, sharing: host.sharing,
                                 installPage: host.installPage, report: report)
        default:
            return AgentResponse(ok: false, error: "알 수 없는 명령입니다: \(command). status, pair, requests, approve, deny, push, link, files, unpush, connect, schemes, build 중 하나를 쓰세요.")
        }
    }

    /// 프로젝트 폴더에 에이전트용 안내를 쓴다: Claude 스킬 파일과 `AGENTS.md`의 RemoteDebug 단락. 쓴 파일 경로를 돌려준다.
    @discardableResult
    public func connectAgents(for project: ConnectedProject) -> [URL] {
        let fm = FileManager.default
        var written: [URL] = []
        do {
            let skill = project.folder.appendingPathComponent(".claude/skills/remotedebug/SKILL.md")
            try fm.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(AgentScript.skill(script: agentScript.path, container: project.container).utf8).write(to: skill, options: [.atomic])
            written.append(skill)

            let agents = project.folder.appendingPathComponent("AGENTS.md")
            let existing = (try? String(contentsOf: agents, encoding: .utf8)) ?? ""
            let block = AgentScript.agentsBlock(script: agentScript.path, container: project.container)
            let updated = AgentScript.replacingBlock(in: existing, with: block)
            if updated != existing {
                try Data(updated.utf8).write(to: agents, options: [.atomic])
                written.append(agents)
            }
        } catch {
            lastError = String(localized: "에이전트 안내를 쓰지 못했습니다: \(HostErrorText.message(for: error))")
        }
        return written
    }
}

/// 에이전트용 명령 스크립트와 안내문.
enum AgentScript {
    static let blockStart = "<!-- remotedebug:start -->"
    static let blockEnd = "<!-- remotedebug:end -->"

    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func text(agentDir: String, bundleID: String) -> String {
        """
        #!/bin/sh
        # RemoteDebug Mac 앱에 명령을 보낸다. 앱이 이 파일을 실행할 때마다 새로 쓴다.
        # 사용법: rd status | pair | requests | approve <요청 id> | deny <요청 id> | push <파일> [프로젝트] | link <주소> [이름] [프로젝트] | files [프로젝트] | unpush <파일 id> | connect <경로> | schemes <경로> | build <경로> [스킴]
        dir=\(quoted(agentDir))
        bundle=\(quoted(bundleID))
        [ $# -ge 1 ] || { echo "사용법: rd status | pair | requests | approve <요청 id> | deny <요청 id> | push <파일> [프로젝트] | link <주소> [이름] [프로젝트] | files [프로젝트] | unpush <파일 id> | connect <경로> | schemes <경로> | build <경로> [스킴]" >&2; exit 2; }
        cmd=$1
        path=${2:-}
        scheme=${3:-}
        # 구역(프로젝트 이름이나 경로): push는 셋째, link는 넷째, files는 둘째 인자다. 비우면 push·link는 공통, files는 전체다.
        project=
        case "$cmd" in
          push) project=$scheme; scheme= ;;
          link) project=${4:-} ;;
          files) project=$path; path= ;;
        esac
        # 경로를 받는 명령만 상대 경로를 절대 경로로 바꾼다(id·주소는 그대로).
        case "$cmd" in
          push|connect|schemes|build) case "$path" in ""|/*) ;; *) path="$PWD/$path" ;; esac ;;
        esac
        alive() { [ -f "$dir/pid" ] && kill -0 "$(cat "$dir/pid")" 2>/dev/null; }
        if ! alive; then
          open -gb "$bundle" 2>/dev/null
          i=0
          while ! alive && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
        fi
        alive || { echo '{"ok":false,"error":"RemoteDebug 앱이 실행 중이 아닙니다. 앱을 열고 다시 시도하세요."}'; exit 1; }
        id="$(date +%s)-$$"
        printf '%s\\n%s\\n%s\\n%s\\n' "$cmd" "$path" "$scheme" "$project" > "$dir/requests/$id.tmp" && mv "$dir/requests/$id.tmp" "$dir/requests/$id.req" || exit 1
        res="$dir/responses/$id.json"
        while [ ! -f "$res" ]; do
          alive || { echo '{"ok":false,"error":"응답을 기다리는 중에 RemoteDebug 앱이 종료됐습니다."}'; exit 1; }
          sleep 1
        done
        out=$(cat "$res")
        rm -f "$res"
        printf '%s\\n' "$out"
        case "$out" in *'"ok":true'*) exit 0 ;; *) exit 1 ;; esac

        """
    }

    static func usage(script: String, container: String) -> String {
        let rd = quoted(script)
        let project = quoted(container)
        return """
        명령은 JSON 한 줄을 출력하고, 성공하면 종료 코드 0이다.

        ```sh
        \(rd) build \(project)            # 마지막에 쓴 스킴으로 Debug 기기용 빌드 후 게시
        \(rd) build \(project) <스킴>     # 스킴을 정해서 빌드
        \(rd) schemes \(project)          # 스킴 목록
        \(rd) status                      # 공유 중인지, 설치 페이지 주소, 연결한 프로젝트
        \(rd) push <파일> \(project)     # 파일을 iPhone RemoteDebug 앱의 이 프로젝트 구역으로 보낸다(프로젝트를 빼면 공통 구역)
        \(rd) link <주소> <이름> \(project)  # 링크(https://…, 앱스킴://…)를 이 프로젝트 구역으로 보낸다(이름은 ''로 비울 수 있다)
        \(rd) files \(project)           # 이 프로젝트 구역에 보낸 파일·링크(프로젝트를 빼면 전체)
        ```

        - `build`는 빌드가 끝날 때까지 기다린다(몇 분 걸릴 수 있다). 실패하면 `error`와 `report.logTail`에 컴파일 오류가, `report.logPath`에 전체 로그 경로가 있다.
        - `report.published`가 게시된 빌드다. 비어 있고 `ok`가 true면 결과가 전과 같아 다시 게시하지 않은 것이다.
        - Mac은 게시까지만 한다. 설치는 페어링한 iPhone의 RemoteDebug 앱이나 설치 페이지(`installPage`)에서 사용자가 누른다.
        - `sharing`이 false면 iPhone이 빌드를 받을 수 없다. 사용자에게 RemoteDebug 앱에서 공유를 시작하라고 알린다.
        - 보낸 파일·링크는 프로젝트 구역으로 나뉜다. 프로젝트는 연결한 프로젝트의 이름이나 `.xcodeproj`·`.xcworkspace` 경로로 정한다. 연결한 프로젝트가 아니면 `error`에 쓸 수 있는 이름이 나온다. `files`의 항목에 `project`가 없으면 공통 구역이다.
        - `push`는 같은 이름의 이전 파일을 바꾼다(구역이 달라도 이름은 하나다). 사용자는 iPhone RemoteDebug 앱의 "Mac에서 받은 파일"에서 받아 파일 앱이나 공유 시트로 다른 앱에 넘긴다.
        - 서명 오류(프로비저닝 프로필, 기기 미등록)는 이 명령으로 고칠 수 없다. Xcode에서 한 번 기기용으로 빌드하라고 사용자에게 알린다.
        """
    }

    static func skill(script: String, container: String) -> String {
        """
        ---
        name: remotedebug
        description: 이 프로젝트의 Debug 빌드를 실제 iPhone에 설치할 수 있게 RemoteDebug Mac 앱으로 빌드·게시한다. "아이폰에 설치", "기기에서 확인", "실기기 빌드", "RemoteDebug로 올려줘" 같은 요청에 사용한다.
        ---

        # RemoteDebug

        RemoteDebug Mac 앱이 이 프로젝트를 Debug 기기용으로 빌드해 tailnet 너머의 iPhone에 게시한다.

        \(usage(script: script, container: container))

        """
    }

    static func agentsBlock(script: String, container: String) -> String {
        """
        \(blockStart)
        ## RemoteDebug

        이 프로젝트의 Debug 빌드를 실제 iPhone에 설치할 수 있게 하려면 RemoteDebug Mac 앱으로 빌드·게시한다.

        \(usage(script: script, container: container))
        \(blockEnd)
        """
    }

    /// 표시 사이의 단락을 바꾼다. 없으면 끝에 붙인다.
    static func replacingBlock(in text: String, with block: String) -> String {
        if let start = text.range(of: blockStart), let end = text.range(of: blockEnd, range: start.upperBound..<text.endIndex) {
            return text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
        }
        if text.isEmpty { return block + "\n" }
        return text + (text.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
    }
}
