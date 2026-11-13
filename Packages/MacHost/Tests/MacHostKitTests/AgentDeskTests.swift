import Foundation
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

/// 정해 둔 출력을 내는 가짜 에이전트.
final class FakeAgentRunner: AgentRunning {
    struct State {
        var tools: [AgentTool] = [.claude, .codex]
        var launches: [AgentLaunch] = []
        /// 실행마다 하나씩 꺼내 쓰는 출력. 비면 스트림을 열어 둔다(실행 중).
        var scripts: [[AgentRunOutput]] = []
        var open: [AsyncStream<AgentRunOutput>.Continuation] = []
        var terminated = 0
    }

    let state = Mutex(State())
    var launches: [AgentLaunch] { state.withLock { $0.launches } }

    func run(_ launch: AgentLaunch) -> AsyncStream<AgentRunOutput> {
        AsyncStream { continuation in
            let script = state.withLock { s -> [AgentRunOutput]? in
                s.launches.append(launch)
                if s.scripts.isEmpty {
                    s.open.append(continuation)
                    return nil
                }
                return s.scripts.removeFirst()
            }
            continuation.onTermination = { [self] reason in
                if case .cancelled = reason { state.withLock { $0.terminated += 1 } }
            }
            guard let script else { return }
            for item in script { continuation.yield(item) }
            continuation.finish()
        }
    }

    func installedTools() async -> [AgentTool] { state.withLock { $0.tools } }
}

@MainActor
@Suite struct AgentDeskTests {
    static let claudeOK: [AgentRunOutput] = [
        .line("zsh 안내 줄"),
        .line(#"{"type":"system","subtype":"init","session_id":"s-1"}"#),
        .line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"살펴보겠습니다."},{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#),
        .line(#"{"type":"result","subtype":"success","is_error":false,"result":"테스트 3개를 고쳤습니다.","session_id":"s-1"}"#),
        .exit(code: 0, errorTail: ""),
    ]

    /// 코어에 넘어간 `GET /v1/agent` 본문.
    final class Boards: Sendable {
        let list = Mutex<[AgentBoard]>([])
        var last: AgentBoard? { list.withLock { $0.last } }
    }

    struct World {
        let dir: TempDir
        let runner = FakeAgentRunner()
        let boards = Boards()
        let desk: AgentDesk
        let project = AgentDesk.Project(name: "MyApp", folder: URL(fileURLWithPath: "/tmp/My App"))

        @MainActor init() async throws {
            dir = try TempDir("agent")
            let project = self.project
            desk = AgentDesk(root: dir.url, runner: runner, projects: { [project] }, publish: { [boards] data in
                if let board = try? RDJSON.decoder().decode(AgentBoard.self, from: data) { boards.list.withLock { $0.append(board) } }
            })
            await desk.load()
        }

        @MainActor func wait(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    @Test func runsRequestAndKeepsAnswerAndSession() async throws {
        let w = try await World()
        w.runner.state.withLock { $0.scripts = [Self.claudeOK] }
        let job = try w.desk.submit(text: "  실패하는 테스트를 고쳐줘 ", project: w.project.id).get()
        await w.wait { w.desk.jobs.first?.state == .done }

        let done = try #require(w.desk.jobs.first)
        #expect(done.id == job.id)
        #expect(done.text == "실패하는 테스트를 고쳐줘")
        #expect(done.output == "테스트 3개를 고쳤습니다.")
        #expect(done.activity == "살펴보겠습니다.\n▸ Bash: swift test")
        #expect(done.session == "s-1")
        #expect(done.origin == "Mac")
        #expect(w.runner.launches.first?.command
            == "cd '/tmp/My App' && exec claude -p --output-format stream-json --verbose --permission-mode acceptEdits -- '실패하는 테스트를 고쳐줘'")

        // 다시 열어도 목록이 남는다.
        let reopened = AgentDesk(root: w.dir.url, runner: w.runner, projects: { [w.project] })
        await reopened.load()
        #expect(reopened.jobs.map(\.output) == ["테스트 3개를 고쳤습니다."])
    }

    @Test func followUpResumesSessionOfTheSameAgent() async throws {
        let w = try await World()
        w.runner.state.withLock { $0.scripts = [Self.claudeOK, Self.claudeOK] }
        let first = try w.desk.submit(text: "고쳐줘", project: w.project.id).get()
        await w.wait { w.desk.jobs.first?.state == .done }
        _ = try w.desk.submit(text: "커밋도 해줘", project: "", agent: .codex, continues: first.id).get()
        await w.wait { w.runner.launches.count == 2 }
        let second = try #require(w.runner.launches.last)
        #expect(second.tool == .claude)
        #expect(second.session == "s-1")
        #expect(second.command.contains("--resume 's-1' -- '커밋도 해줘'"))
    }

    @Test func codexFailureIsReported() async throws {
        let w = try await World()
        w.runner.state.withLock { $0.scripts = [[
            .line(#"{"type":"thread.started","thread_id":"t-9"}"#),
            .line(#"{"type":"turn.failed","error":{"message":"사용 한도를 넘었습니다."}}"#),
            .exit(code: 1, errorTail: ""),
        ]] }
        w.desk.access = .readOnly
        _ = try w.desk.submit(text: "it's broken", project: w.project.id, agent: .codex).get()
        await w.wait { w.desk.jobs.first?.state.isFinished == true }
        #expect(w.desk.jobs.first?.state == .failed)
        #expect(w.desk.jobs.first?.output == "사용 한도를 넘었습니다.")
        #expect(w.runner.launches.first?.command
            == #"cd '/tmp/My App' && exec codex exec --json --skip-git-repo-check --sandbox read-only -- 'it'\''s broken'"#)
    }

    @Test func oneRequestPerProjectAtATimeAndCancelStopsTheProcess() async throws {
        let w = try await World()
        let first = try w.desk.submit(text: "하나", project: w.project.id).get()
        let second = try w.desk.submit(text: "둘", project: w.project.id).get()
        await w.wait { w.runner.launches.count == 1 }
        #expect(w.desk.jobs.map(\.state) == [.queued, .running])

        w.desk.cancel(first.id)
        await w.wait { w.runner.launches.count == 2 && w.runner.state.withLock { $0.terminated } == 1 }
        #expect(w.runner.state.withLock { $0.terminated } == 1)
        #expect(w.desk.jobs.first { $0.id == first.id }?.state == .cancelled)
        #expect(w.desk.jobs.first { $0.id == second.id }?.state == .running)
    }

    @Test func remoteRequestsNeedTheSwitchAndFailuresStayVisible() async throws {
        let w = try await World()
        w.desk.receive(AgentRequestEvent(requestId: "a_1", deviceId: "d_1", deviceName: "내 iPhone", text: "안녕", project: w.project.id))
        #expect(w.desk.jobs.isEmpty)

        w.desk.acceptsRemote = true
        w.desk.receive(AgentRequestEvent(requestId: "a_2", deviceId: "d_1", deviceName: "내 iPhone", text: "안녕", project: "없는 프로젝트"))
        #expect(w.desk.jobs.first?.state == .failed)
        #expect(w.desk.jobs.first?.origin == "내 iPhone")

        w.desk.receive(AgentRequestEvent(requestId: "a_3", deviceId: "d_1", deviceName: "내 iPhone", text: "안녕", project: w.project.id))
        await w.wait { w.runner.launches.count == 1 && w.boards.last?.requests.count == 2 }
        let board = try #require(w.boards.last)
        #expect(board.enabled)
        #expect(board.projects == [AgentProjectRef(id: w.project.id, name: "MyApp")])
        #expect(board.agents == [.claude, .codex])
        #expect(board.requests.map(\.id) == ["a_3", "a_2"])
        // 폴더 경로는 iPhone에 보내지 않는다.
        #expect(!w.project.id.contains("/"))
    }

    @Test func rejectsEmptyTextMissingProjectAndMissingTool() async throws {
        let w = try await World()
        #expect(throws: AgentDesk.Failure.self) { try w.desk.submit(text: "  ", project: w.project.id).get() }
        #expect(throws: AgentDesk.Failure.self) { try w.desk.submit(text: "hi", project: "x").get() }
        w.runner.state.withLock { $0.tools = [.claude] }
        await w.desk.refreshTools()
        #expect(throws: AgentDesk.Failure.self) { try w.desk.submit(text: "hi", project: w.project.id, agent: .codex).get() }
        #expect(w.desk.jobs.isEmpty)
    }

    @Test func interruptedRequestsAreMarkedFailedOnLoad() async throws {
        let w = try await World()
        _ = try w.desk.submit(text: "오래 걸리는 일", project: w.project.id).get()
        await w.wait { w.runner.launches.count == 1 }
        let reopened = AgentDesk(root: w.dir.url, runner: w.runner, projects: { [w.project] })
        await reopened.load()
        #expect(reopened.jobs.first?.state == .failed)
    }
}

@Suite struct AgentOutputParserTests {
    @Test func ignoresNoiseAndUnknownEvents() {
        #expect(AgentOutputParser.events(line: "compinit: insecure directories", tool: .claude).isEmpty)
        #expect(AgentOutputParser.events(line: #"{"type":"rate_limit_event"}"#, tool: .claude).isEmpty)
        #expect(AgentOutputParser.events(line: #"{"type":"system","subtype":"hook_started","session_id":"x"}"#, tool: .claude).isEmpty)
    }

    @Test func readsCodexMessagesAndCommands() {
        #expect(AgentOutputParser.events(line: #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"끝났습니다"}}"#, tool: .codex)
            == [.text("끝났습니다")])
        #expect(AgentOutputParser.events(line: #"{"type":"item.started","item":{"type":"command_execution","command":"ls\n-la"}}"#, tool: .codex)
            == [.tool("명령: ls")])
        #expect(AgentOutputParser.events(line: #"{"type":"item.completed","item":{"type":"error","message":"경고"}}"#, tool: .codex).isEmpty)
    }

    @Test func claudeErrorResultIsAFailure() {
        #expect(AgentOutputParser.events(line: #"{"type":"result","is_error":true,"result":"한도 초과","session_id":"s"}"#, tool: .claude)
            == [.session("s"), .result("한도 초과", failed: true)])
    }
}

@Suite struct ShellAgentRunnerTests {
    @Test func streamsLinesThenExitCodeAndErrorTail() async {
        var items: [AgentRunOutput] = []
        for await item in ShellAgentRunner().run(command: "cd /tmp && exec /bin/sh -c 'echo one; echo two; echo oops >&2; exit 3'") {
            items.append(item)
        }
        // 로그인 셸 설정이 앞에 다른 줄을 낼 수 있다.
        #expect(items.suffix(3).prefix(2) == [.line("one"), .line("two")])
        guard case .exit(let code, let tail) = items.last else {
            Issue.record("종료 결과가 없다: \(items)")
            return
        }
        #expect(code == 3)
        #expect(tail.hasSuffix("oops"))
    }

    @Test func droppingTheStreamTerminatesTheProcess() async {
        let started = Date()
        let task = Task {
            for await _ in ShellAgentRunner().run(command: "exec /bin/sleep 30") {}
        }
        try? await Task.sleep(for: .seconds(2))
        task.cancel()
        await task.value
        #expect(Date().timeIntervalSince(started) < 15)
    }
}
