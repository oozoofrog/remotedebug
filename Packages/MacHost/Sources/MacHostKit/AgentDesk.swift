import CryptoKit
import Foundation
import Observation
import RDModels

/// 요청으로 띄운 에이전트가 Mac에서 할 수 있는 일의 범위. Mac에서만 바꾼다.
public enum AgentAccess: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case readOnly, edit, full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readOnly: String(localized: "읽기만")
        case .edit: String(localized: "프로젝트 파일 수정")
        case .full: String(localized: "모든 권한")
        }
    }

    public var detail: String {
        switch self {
        case .readOnly: String(localized: "코드를 읽고 답하거나 계획을 세운다. 파일을 바꾸지 않는다.")
        case .edit: String(localized: "프로젝트 폴더의 파일을 고친다. 그 밖의 명령은 에이전트 설정에서 허용한 것만 실행한다.")
        case .full: String(localized: "확인 없이 모든 명령을 실행한다. 페어링한 iPhone을 가진 사람이 이 Mac에서 무엇이든 할 수 있다.")
        }
    }

    func flags(for tool: AgentTool) -> String {
        switch (tool, self) {
        case (.claude, .readOnly): "--permission-mode plan"
        case (.claude, .edit): "--permission-mode acceptEdits"
        case (.claude, .full): "--permission-mode bypassPermissions"
        case (.codex, .readOnly): "--sandbox read-only"
        case (.codex, .edit): "--sandbox workspace-write"
        case (.codex, .full): "--dangerously-bypass-approvals-and-sandbox"
        }
    }
}

/// 에이전트 한 번 실행에 필요한 값.
public struct AgentLaunch: Sendable, Hashable {
    public var tool: AgentTool
    public var prompt: String
    public var directory: URL
    public var access: AgentAccess
    /// 이어 갈 세션. 새 대화면 빈 문자열.
    public var session: String

    public init(tool: AgentTool, prompt: String, directory: URL, access: AgentAccess, session: String = "") {
        self.tool = tool
        self.prompt = prompt
        self.directory = directory
        self.access = access
        self.session = session
    }

    /// 로그인 셸에 넘길 명령. 한 줄에 JSON 하나씩 출력하는 형식으로 띄운다.
    public var command: String {
        let q = AgentScript.quoted
        let run: String
        switch tool {
        case .claude:
            let resume = session.isEmpty ? "" : " --resume \(q(session))"
            run = "claude -p --output-format stream-json --verbose \(access.flags(for: tool))\(resume) -- \(q(prompt))"
        case .codex:
            let resume = session.isEmpty ? "" : " resume \(q(session))"
            run = "codex exec\(resume) --json --skip-git-repo-check \(access.flags(for: tool)) -- \(q(prompt))"
        }
        return "cd \(q(directory.path)) && exec \(run)"
    }
}

/// 에이전트 출력 한 줄에서 읽어 낸 것.
public enum AgentOutputEvent: Sendable, Hashable {
    case session(String)
    /// 에이전트가 쓴 글.
    case text(String)
    /// 에이전트가 쓴 도구(이름과 요약).
    case tool(String)
    /// 마지막 답. `failed`면 에이전트가 실패를 알렸다.
    case result(String, failed: Bool)
}

public enum AgentOutputParser {
    /// JSON이 아니거나 모르는 줄은 빈 배열.
    public static func events(line: String, tool: AgentTool) -> [AgentOutputEvent] {
        guard line.first == "{", let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }
        return tool == .claude ? claude(type, object) : codex(type, object)
    }

    private static func claude(_ type: String, _ object: [String: Any]) -> [AgentOutputEvent] {
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let id = object["session_id"] as? String else { return [] }
            return [.session(id)]
        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.isEmpty else { return nil }
                    return .text(text)
                case "tool_use":
                    return .tool(toolSummary(name: block["name"] as? String ?? String(localized: "도구"), input: block["input"] as? [String: Any] ?? [:]))
                default:
                    return nil
                }
            }
        case "result":
            var events: [AgentOutputEvent] = []
            if let id = object["session_id"] as? String { events.append(.session(id)) }
            let failed = object["is_error"] as? Bool ?? false
            events.append(.result(object["result"] as? String ?? "", failed: failed))
            return events
        default:
            return []
        }
    }

    private static func codex(_ type: String, _ object: [String: Any]) -> [AgentOutputEvent] {
        switch type {
        case "thread.started":
            guard let id = object["thread_id"] as? String else { return [] }
            return [.session(id)]
        case "item.started", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "agent_message":
                guard type == "item.completed", let text = item["text"] as? String, !text.isEmpty else { return [] }
                return [.text(text)]
            case "command_execution":
                guard type == "item.started", let command = item["command"] as? String else { return [] }
                return [.tool(clip(String(localized: "명령: \(command)")))]
            case "file_change":
                guard type == "item.completed" else { return [] }
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                return [.tool(clip(String(localized: "파일 수정: \(paths.joined(separator: ", "))")))]
            default:
                return []
            }
        case "turn.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? String(localized: "에이전트가 실패했습니다.")
            return [.result(message, failed: true)]
        default:
            return []
        }
    }

    static func toolSummary(name: String, input: [String: Any]) -> String {
        let detail = ["command", "file_path", "pattern", "url", "description", "prompt"].lazy.compactMap { input[$0] as? String }.first
        return clip(detail.map { "\(name): \($0)" } ?? name)
    }

    static func clip(_ text: String, limit: Int = 140) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > limit ? line.prefix(limit) + "…" : line
    }
}

/// 실행 중인 에이전트가 내는 것: 표준 출력 한 줄씩, 마지막에 종료 결과 한 번.
public enum AgentRunOutput: Sendable, Hashable {
    case line(String)
    case exit(code: Int32, errorTail: String)
}

public protocol AgentRunning: Sendable {
    /// 스트림을 끝까지 읽지 않고 버리면(작업 취소) 프로세스를 끝낸다.
    func run(_ launch: AgentLaunch) -> AsyncStream<AgentRunOutput>
    /// 이 Mac에 설치된 에이전트 명령.
    func installedTools() async -> [AgentTool]
}

/// 사용자의 로그인 셸(PATH)로 `claude`·`codex`를 띄운다.
public struct ShellAgentRunner: AgentRunning {
    public init() {}

    private final class Box: @unchecked Sendable {
        let process = Process()
        let lock = NSLock()
        var cancelled = false
        var errorData = Data()

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process.isRunning
            lock.unlock()
            if running { process.terminate() }
        }
    }

    public func run(_ launch: AgentLaunch) -> AsyncStream<AgentRunOutput> {
        run(command: launch.command)
    }

    func run(command: String) -> AsyncStream<AgentRunOutput> {
        AsyncStream { continuation in
            let box = Box()
            continuation.onTermination = { reason in
                if case .cancelled = reason { box.cancel() }
            }
            DispatchQueue.global().async {
                let process = box.process
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lic", command]
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                box.lock.lock()
                let cancelled = box.cancelled
                do {
                    if !cancelled { try process.run() }
                } catch {
                    box.lock.unlock()
                    continuation.yield(.exit(code: 127, errorTail: HostErrorText.message(for: error)))
                    continuation.finish()
                    return
                }
                box.lock.unlock()
                guard !cancelled else { return continuation.finish() }

                let errorDone = DispatchGroup()
                errorDone.enter()
                DispatchQueue.global().async {
                    box.errorData = err.fileHandleForReading.readDataToEndOfFile()
                    errorDone.leave()
                }
                var buffer = Data()
                let handle = out.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        continuation.yield(.line(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
                if !buffer.isEmpty { continuation.yield(.line(String(decoding: buffer, as: UTF8.self))) }
                process.waitUntilExit()
                errorDone.wait()
                let tail = String(decoding: box.errorData.suffix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.yield(.exit(code: process.terminationStatus, errorTail: tail))
                continuation.finish()
            }
        }
    }

    public func installedTools() async -> [AgentTool] {
        var found: [AgentTool] = []
        for tool in AgentTool.allCases where await AgentInstaller.loginShell("command -v \(tool.rawValue)").code == 0 {
            found.append(tool)
        }
        return found
    }
}

/// Mac과 iPhone에서 온 요청을 사용자의 에이전트(`claude`, `codex`)에 넘기고 진행과 결과를 모은다.
@MainActor
@Observable
public final class AgentDesk {
    public struct Project: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var folder: URL

        public init(name: String, folder: URL) {
            // 경로를 iPhone에 보내지 않도록 짧은 해시를 id로 쓴다.
            self.id = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            self.name = name
            self.folder = folder
        }
    }

    public struct Failure: Error, Sendable, Hashable {
        public var message: String
    }

    struct Stored: Codable, Sendable {
        var jobs: [AgentJob] = []
        var acceptsRemote = false
        var access = AgentAccess.edit
    }

    public static let originMac = "Mac"
    static let keptJobs = 20
    static let activityLimit = 3000
    static let outputLimit = 8000

    /// 최근 요청(새 것부터).
    public private(set) var jobs: [AgentJob] = []
    /// 페어링한 iPhone의 요청을 받는다.
    public var acceptsRemote = false {
        didSet { if acceptsRemote != oldValue { settingsChanged() } }
    }
    public var access = AgentAccess.edit {
        didSet { if access != oldValue { settingsChanged() } }
    }
    /// 이 Mac에 설치된 에이전트. `refreshTools`가 채운다.
    public private(set) var tools: [AgentTool] = []
    public private(set) var toolsChecked = false

    @ObservationIgnored private let file: JSONFile<Stored>
    @ObservationIgnored private let runner: any AgentRunning
    @ObservationIgnored private let projectList: @MainActor () -> [Project]
    @ObservationIgnored private let publish: @MainActor (Data) async -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var isShutDown = false

    /// `root`는 호스트 저장 폴더(`HostPaths.root`)다. `publish`는 `GET /v1/agent`의 본문을 코어에 넘긴다.
    public init(root: URL, runner: any AgentRunning = ShellAgentRunner(),
                projects: @escaping @MainActor () -> [Project],
                publish: @escaping @MainActor (Data) async -> Void = { _ in },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = JSONFile(url: root.appendingPathComponent("agent-requests.json"))
        self.runner = runner
        self.projectList = projects
        self.publish = publish
        self.now = now
    }

    public var projects: [Project] { projectList() }

    public var board: AgentBoard {
        AgentBoard(enabled: acceptsRemote, projects: projects.map { AgentProjectRef(id: $0.id, name: $0.name) }, agents: tools, requests: jobs)
    }

    // MARK: 불러오기·저장

    public func load() async {
        guard !isLoaded else { return }
        isLoaded = true
        if let stored = try? file.load() {
            jobs = stored.jobs.map { job in
                guard !job.state.isFinished else { return job }
                var job = job
                job.state = .failed
                job.output = String(localized: "RemoteDebug 앱이 종료되어 중단됐습니다.")
                job.finishedAt = now()
                return job
            }
            acceptsRemote = stored.acceptsRemote
            access = stored.access
        }
        await refreshTools()
    }

    public func refreshTools() async {
        tools = await runner.installedTools()
        toolsChecked = true
        schedulePublish()
    }

    /// 프로젝트 목록이 바뀌었다.
    public func projectsChanged() { schedulePublish() }

    /// 실행 중인 요청을 멈춘다(앱 종료).
    public func shutdown() {
        isShutDown = true
        for id in Array(running.keys) { cancel(id) }
        publishTask?.cancel()
    }

    private func settingsChanged() {
        guard isLoaded else { return }
        save()
        schedulePublish()
    }

    private func save() {
        try? file.save(Stored(jobs: jobs, acceptsRemote: acceptsRemote, access: access))
    }

    private func schedulePublish() {
        guard publishTask == nil, !isShutDown else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            guard let data = try? RDJSON.encoder().encode(self.board) else { return }
            await self.publish(data)
        }
    }

    // MARK: 요청

    /// Mac 화면에서 보낸 요청.
    @discardableResult
    public func submit(text: String, project: String, agent: AgentTool? = nil, continues: String = "") -> Result<AgentJob, Failure> {
        accept(id: "a_" + HostIdentity.random(), text: text, project: project, agent: agent?.rawValue ?? "", continues: continues, origin: Self.originMac)
    }

    /// iPhone에서 온 요청(코어 이벤트). 받을 수 없는 요청도 이유와 함께 목록에 남겨 iPhone이 볼 수 있게 한다.
    public func receive(_ event: AgentRequestEvent) {
        guard acceptsRemote else { return }
        let origin = event.deviceName.isEmpty ? "iPhone" : event.deviceName
        if case .failure(let failure) = accept(id: event.requestId, text: event.text, project: event.project, agent: event.agent,
                                               continues: event.continues, origin: origin),
           !jobs.contains(where: { $0.id == event.requestId }) {
            let name = projects.first { $0.id == event.project }?.name ?? ""
            insert(AgentJob(id: event.requestId, text: event.text, project: event.project, projectName: name,
                            agent: AgentTool(rawValue: event.agent) ?? tools.first ?? .claude, origin: origin, state: .failed,
                            createdAt: now(), finishedAt: now(), output: failure.message))
        }
    }

    private func accept(id: String, text: String, project: String, agent: String, continues: String, origin: String) -> Result<AgentJob, Failure> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(Failure(message: String(localized: "요청 내용이 비어 있습니다."))) }
        guard text.utf8.count <= AgentSubmission.maxTextBytes else { return .failure(Failure(message: String(localized: "요청이 너무 깁니다(최대 16KB)."))) }
        guard !jobs.contains(where: { $0.id == id }) else { return .failure(Failure(message: String(localized: "이미 받은 요청입니다."))) }
        var projectID = project
        var tool = AgentTool(rawValue: agent) ?? tools.first
        var session = ""
        if !continues.isEmpty {
            guard let previous = jobs.first(where: { $0.id == continues }), previous.canContinue else {
                return .failure(Failure(message: String(localized: "이어 갈 대화를 찾지 못했습니다. 새 요청으로 보내세요.")))
            }
            projectID = previous.project
            tool = previous.agent
            session = previous.session
        }
        guard let target = projects.first(where: { $0.id == projectID }) else {
            return .failure(Failure(message: String(localized: "프로젝트를 찾지 못했습니다. Mac 앱의 프로젝트 화면에서 연결했는지 확인하세요.")))
        }
        guard let tool else { return .failure(Failure(message: String(localized: "이 Mac에서 claude나 codex 명령을 찾지 못했습니다."))) }
        guard tools.contains(tool) else { return .failure(Failure(message: String(localized: "이 Mac에서 \(tool.rawValue) 명령을 찾지 못했습니다."))) }
        let job = AgentJob(id: id, text: text, project: target.id, projectName: target.name, agent: tool, origin: origin,
                           createdAt: now(), session: session, continues: continues)
        insert(job)
        pump()
        return .success(job)
    }

    private func insert(_ job: AgentJob) {
        jobs.insert(job, at: 0)
        // 끝난 요청부터 오래된 순으로 덜어 낸다.
        while jobs.count > Self.keptJobs, let index = jobs.lastIndex(where: { $0.state.isFinished }) {
            jobs.remove(at: index)
        }
        save()
        schedulePublish()
    }

    public func cancel(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].state.isFinished else { return }
        running.removeValue(forKey: id)?.cancel()
        jobs[index].state = .cancelled
        jobs[index].finishedAt = now()
        jobs[index].output = String(localized: "요청을 멈췄습니다.")
        save()
        schedulePublish()
        pump()
    }

    public func remove(_ id: String) {
        cancel(id)
        jobs.removeAll { $0.id == id }
        save()
        schedulePublish()
    }

    public func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
        save()
        schedulePublish()
    }

    // MARK: 실행

    /// 프로젝트마다 한 번에 하나씩, 먼저 온 요청부터 실행한다.
    private func pump() {
        guard !isShutDown else { return }
        var busy = Set(jobs.filter { $0.state == .running }.map(\.project))
        for job in jobs.reversed() where job.state == .queued && !busy.contains(job.project) {
            guard let target = projects.first(where: { $0.id == job.project }) else {
                finish(job.id, state: .failed, output: String(localized: "프로젝트 연결이 해제됐습니다."))
                continue
            }
            busy.insert(job.project)
            start(job, in: target.folder)
        }
    }

    private func start(_ job: AgentJob, in folder: URL) {
        update(job.id) { $0.state = .running }
        save()
        let launch = AgentLaunch(tool: job.agent, prompt: job.text, directory: folder, access: access, session: job.session)
        let stream = runner.run(launch)
        let id = job.id
        running[id] = Task { [weak self] in
            var answer: (text: String, failed: Bool)?
            var lastText = ""
            var noise: [String] = []
            for await item in stream {
                guard let self, !Task.isCancelled else { return }
                switch item {
                case .line(let line):
                    let events = AgentOutputParser.events(line: line, tool: launch.tool)
                    if events.isEmpty, line.first != "{", !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        noise = Array((noise + [line]).suffix(8))
                    }
                    for event in events {
                        switch event {
                        case .session(let session): self.update(id) { $0.session = session }
                        case .text(let text):
                            lastText = text
                            self.appendActivity(id, text)
                        case .tool(let summary): self.appendActivity(id, "▸ \(summary)")
                        case .result(let text, let failed): answer = (text, failed)
                        }
                    }
                case .exit(let code, let errorTail):
                    self.running[id] = nil
                    if let answer, !answer.failed, code == 0 {
                        self.finish(id, state: .done, output: answer.text.isEmpty ? lastText : answer.text)
                    } else if answer == nil, code == 0, !lastText.isEmpty {
                        self.finish(id, state: .done, output: lastText)
                    } else {
                        let reason = [answer?.text ?? "", errorTail, noise.joined(separator: "\n")].first { !$0.isEmpty }
                        self.finish(id, state: .failed, output: reason ?? String(localized: "에이전트가 답 없이 끝났습니다(종료 코드 \(String(code)))."))
                    }
                    self.pump()
                }
            }
        }
    }

    private func update(_ id: String, _ change: (inout AgentJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        schedulePublish()
    }

    private func appendActivity(_ id: String, _ text: String) {
        update(id) { job in
            let joined = job.activity.isEmpty ? text : job.activity + "\n" + text
            job.activity = joined.count > Self.activityLimit ? "…" + joined.suffix(Self.activityLimit) : joined
        }
    }

    private func finish(_ id: String, state: AgentJob.State, output: String) {
        update(id) { job in
            guard !job.state.isFinished else { return }
            job.state = state
            job.finishedAt = now()
            job.output = output.count > Self.outputLimit ? String(localized: "\(String(output.prefix(Self.outputLimit)))\n…(뒷부분 생략)") : output
        }
        save()
    }
}
