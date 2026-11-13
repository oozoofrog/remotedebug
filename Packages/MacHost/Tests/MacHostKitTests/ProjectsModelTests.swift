import Foundation
import Synchronization
import Testing
@testable import MacHostKit

/// 스킴과 빌드 결과를 정해 둔 가짜 빌더. 빌드하면 DerivedData에 앱을 만든다.
private final class FakeBuilder: ProjectBuilding {
    struct State {
        var schemes: [String] = []
        var failure: ProjectBuildFailure?
        var built: [String] = []
        var onBuild: (@Sendable () throws -> Void)?
        var products: [URL] = []
    }

    let state = Mutex(State())

    func schemes(container: URL) async throws -> [String] { state.withLock { $0.schemes } }

    func build(container: URL, scheme: String, log: URL) async throws {
        let (failure, onBuild) = state.withLock { s -> (ProjectBuildFailure?, (@Sendable () throws -> Void)?) in
            s.built.append(scheme)
            return (s.failure, s.onBuild)
        }
        if let failure { throw failure }
        try onBuild?()
    }

    func products(container: URL, scheme: String) async throws -> [URL] { state.withLock { $0.products } }
}

private final class Names: Sendable {
    private let values = Mutex<[String]>([])
    func withLock<R>(_ body: (inout [String]) -> R) -> R { values.withLock { v in body(&v) } }
}

@MainActor
private struct World {
    let tmp: TempDir
    let derived: URL
    let builder = FakeBuilder()
    let imported = Names()
    let model: ProjectsModel

    init() throws {
        tmp = try TempDir("projects")
        derived = tmp.path("DerivedData")
        let imported = self.imported
        model = ProjectsModel(root: tmp.path("state"), builder: builder, scanner: DerivedDataScanner(root: derived),
                              hostStatus: { .init(sharing: true, installPage: "https://mac.example/") }) { url in
            imported.withLock { $0.append(url.lastPathComponent) }
            return .accepted(LibraryBuild(descriptor: sampleDescriptor(bundleId: "com.example.\(url.deletingPathExtension().lastPathComponent)"), sourcePath: url.path))
        }
    }

    func makeProject(_ name: String, workspace: Bool = false) throws -> URL {
        let container = tmp.path("src/\(name)/\(name).\(workspace ? "xcworkspace" : "xcodeproj")")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container.standardizedFileURL
    }

    /// DerivedData에 프로젝트 폴더를 만든다.
    @discardableResult
    func makeDerived(for container: URL, deviceDebug: Bool = true) throws -> URL {
        let dir = derived.appendingPathComponent("\(container.deletingPathExtension().lastPathComponent)-abc")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Build/Intermediates.noindex/XCBuildData"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": container.path], format: .xml, options: 0)
        try plist.write(to: dir.appendingPathComponent("info.plist"))
        if deviceDebug {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("Build/Products/Debug-iphoneos"), withIntermediateDirectories: true)
        }
        return dir
    }

    func touchBuild(_ dir: URL, at date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent("Build/Products/Debug-iphoneos").path)
    }
}

@MainActor
@Suite("ProjectsModel")
struct ProjectsModelTests {
    @Test func locatorFindsContainerInFolderAndPrefersWorkspace() throws {
        let w = try World()
        let project = try w.makeProject("App")
        #expect(ProjectLocator.container(for: project)?.path == project.path)
        #expect(ProjectLocator.container(for: project.deletingLastPathComponent())?.path == project.path)
        // 한 단계 위 폴더에서도 찾는다.
        #expect(ProjectLocator.container(for: w.tmp.path("src"))?.path == project.path)
        let workspace = try w.makeProject("App", workspace: true)
        #expect(ProjectLocator.container(for: project.deletingLastPathComponent())?.path == workspace.path)
        #expect(ProjectLocator.container(for: w.tmp.path("missing")) == nil)
    }

    @Test func parsesSchemesAndBuildArguments() throws {
        let json = Data(#"{"project":{"name":"App","schemes":["App","AppTests"],"targets":["App"]}}"#.utf8)
        #expect(try XcodeBuildTool.parseSchemes(json) == ["App", "AppTests"])
        let workspace = Data(#"{"workspace":{"name":"W","schemes":["One"]}}"#.utf8)
        #expect(try XcodeBuildTool.parseSchemes(workspace) == ["One"])
        let args = XcodeBuildTool.buildArguments(container: URL(fileURLWithPath: "/p/App.xcworkspace"), scheme: "App")
        #expect(args == ["-workspace", "/p/App.xcworkspace", "-scheme", "App", "-configuration", "Debug", "-destination", "generic/platform=iOS", "build"])
        let settings = Data(#"[{"target":"App","buildSettings":{"PLATFORM_NAME":"iphoneos","WRAPPER_EXTENSION":"app","TARGET_BUILD_DIR":"/p/Build/Products/Debug-iphoneos","FULL_PRODUCT_NAME":"App.app"}},{"target":"Watch","buildSettings":{"PLATFORM_NAME":"watchos","WRAPPER_EXTENSION":"app","TARGET_BUILD_DIR":"/p/w","FULL_PRODUCT_NAME":"W.app"}}]"#.utf8)
        #expect(XcodeBuildTool.parseProducts(settings).map(\.path) == ["/p/Build/Products/Debug-iphoneos/App.app"])
        #expect(XcodeBuildTool.failureTail("a\nx.swift:1: error: boom\nb\nx.swift:1: error: boom") == "x.swift:1: error: boom")
    }

    @Test func connectPersistsAndDroppedFolderBuildsTheOnlyScheme() async throws {
        let w = try World()
        let project = try w.makeProject("App")
        let dir = try w.makeDerived(for: project)
        w.builder.state.withLock {
            $0.schemes = ["App"]
            $0.onBuild = { try makeFakeApp(at: dir.appendingPathComponent("Build/Products/Debug-iphoneos/App.app")) }
            $0.products = [dir.appendingPathComponent("Build/Products/Debug-iphoneos/App.app")]
        }
        await w.model.connectAndBuild(project.deletingLastPathComponent())

        #expect(w.model.projects.map(\.container) == [project.path])
        #expect(w.builder.state.withLock { $0.built } == ["App"])
        #expect(w.imported.withLock { $0 } == ["App.app"])
        let report = try #require(w.model.reports[project.path])
        #expect(report.ok && report.published.count == 1)

        // 같은 결과를 다시 빌드하면 다시 게시하지 않는다.
        w.builder.state.withLock { $0.onBuild = nil }
        let again = await w.model.build(w.model.projects[0], scheme: "App")
        #expect(again.ok && again.published.isEmpty)
        #expect(w.imported.withLock { $0.count } == 1)

        // 다시 열어도 목록과 마지막 스킴이 남는다.
        let reopened = ProjectsModel(root: w.tmp.path("state"), builder: w.builder, scanner: DerivedDataScanner(root: w.derived)) { _ in nil }
        reopened.load()
        #expect(reopened.projects.map(\.scheme) == ["App"])
    }

    @Test func severalSchemesWaitForChoiceAndFailureKeepsLogTail() async throws {
        let w = try World()
        let project = try w.makeProject("App")
        w.builder.state.withLock { $0.schemes = ["Widget", "Tests"] }
        await w.model.connectAndBuild(project)
        #expect(w.builder.state.withLock { $0.built }.isEmpty)

        w.builder.state.withLock { $0.failure = ProjectBuildFailure(message: "빌드에 실패했습니다.", logTail: "error: boom") }
        let report = await w.model.build(w.model.projects[0], scheme: "Widget")
        #expect(!report.ok && report.logTail == "error: boom")
        #expect(w.model.phases.isEmpty)
    }

    @Test func xcodeActivitySuggestsOnceAndRegisteredProjectImportsSettledBuild() async throws {
        let w = try World()
        let project = try w.makeProject("App")
        let dir = try w.makeDerived(for: project)
        try w.touchBuild(dir, at: Date().addingTimeInterval(1000))
        var notified: [String] = []
        w.model.onSuggestion = { notified.append($0.name) }

        await w.model.scanXcode()
        #expect(w.model.suggestions.isEmpty) // 처음 본 상태는 기준일 뿐이다.
        try w.touchBuild(dir, at: Date().addingTimeInterval(2000))
        await w.model.scanXcode()
        await w.model.scanXcode()
        #expect(w.model.suggestions.map(\.container) == [project.path])
        #expect(notified == ["App"])

        await w.model.register(w.model.suggestions[0])
        #expect(w.model.suggestions.isEmpty && w.model.projects.count == 1)

        // 서명 파일이 없는 앱은 지문이 네 번 그대로일 때 가져온다.
        try makeFakeApp(at: dir.appendingPathComponent("Build/Products/Debug-iphoneos/App.app"))
        for _ in 0..<3 { await w.model.scanXcode() }
        #expect(w.imported.withLock { $0 }.isEmpty)
        await w.model.scanXcode()
        #expect(w.imported.withLock { $0 } == ["App.app"])
        await w.model.scanXcode()
        #expect(w.imported.withLock { $0.count } == 1)
    }

    @Test func dismissedProjectIsNotSuggestedAgain() async throws {
        let w = try World()
        let project = try w.makeProject("App")
        let dir = try w.makeDerived(for: project)
        try w.touchBuild(dir, at: Date().addingTimeInterval(1000))
        await w.model.scanXcode()
        try w.touchBuild(dir, at: Date().addingTimeInterval(2000))
        await w.model.scanXcode()
        w.model.dismiss(try #require(w.model.suggestions.first))
        try w.touchBuild(dir, at: Date().addingTimeInterval(3000))
        await w.model.scanXcode()
        #expect(w.model.suggestions.isEmpty)
    }

    @Test func agentScriptRoundTripAndProjectFiles() async throws {
        let w = try World()
        let project = try w.makeProject("App")
        let dir = try w.makeDerived(for: project)
        w.builder.state.withLock {
            $0.schemes = ["App"]
            $0.onBuild = { try makeFakeApp(at: dir.appendingPathComponent("Build/Products/Debug-iphoneos/App.app")) }
            $0.products = [dir.appendingPathComponent("Build/Products/Debug-iphoneos/App.app")]
        }
        w.model.installAgentScript(bundleID: "com.example.none")

        // 실제 스크립트를 실행하고, 앱 쪽 처리를 돌린다.
        let process = Process()
        process.executableURL = w.model.agentScript
        process.arguments = ["build", project.deletingLastPathComponent().path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        // 스크립트는 1초 간격으로 응답을 확인한다. 최대 30초 기다리고, 그래도 안 끝나면 끝낸다.
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            w.model.processAgentRequests()
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains(#""ok":true"#) && output.contains(#""installPage":"https://mac.example/""#) && output.contains("com.example.App"))

        let unknown = await w.model.handleAgentRequest("nope\n\n\n")
        #expect(!unknown.ok)
        let missing = await w.model.handleAgentRequest("build\n\(w.tmp.path("nowhere").path)\n\n")
        #expect(!missing.ok && w.model.lastError == nil)
        #expect(await !w.model.handleAgentRequest("pair\n\n\n").ok)

        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let pairing = ProjectsModel(root: w.tmp.path("state-pair"), builder: w.builder, scanner: DerivedDataScanner(root: w.derived),
                                    openPairing: { .success(.init(code: "K7M2-9QXD", link: "remotedebug://pair?host=h&code=K7M29QXD", installPage: nil, expiresAt: expires)) }) { _ in nil }
        let paired = await pairing.handleAgentRequest("pair\n\n\n")
        #expect(paired.ok && paired.pairing?.link == "remotedebug://pair?host=h&code=K7M29QXD" && paired.pairing?.code == "K7M2-9QXD")

        let decided = Names()
        let waiting = ProjectsModel.PairRequestInfo(requestId: "pr_1", deviceName: "iPhone", nodeName: "rd-phone-1", loginName: "me@", expiresAt: expires)
        let answering = ProjectsModel(root: w.tmp.path("state-answer"), builder: w.builder, scanner: DerivedDataScanner(root: w.derived),
                                      pairingRequests: .init(list: { decided.withLock { $0.isEmpty } ? [waiting] : [] },
                                                             decide: { id, allow in decided.withLock { $0.append("\(id):\(allow)") }; return nil })) { _ in nil }
        #expect(await answering.handleAgentRequest("requests\n\n\n").requests == [waiting])
        #expect(await !answering.handleAgentRequest("approve\npr_other\n\n").ok)
        #expect(await answering.handleAgentRequest("approve\npr_1\n\n").ok)
        #expect(decided.withLock { $0 } == ["pr_1:true"])

        // 프로젝트 폴더에 스킬과 AGENTS.md 단락을 쓴다. 두 번 써도 단락은 하나다.
        let folder = project.deletingLastPathComponent()
        try Data("# 기존 안내\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        #expect(w.model.connectAgents(for: w.model.projects[0]).count == 2)
        #expect(w.model.connectAgents(for: w.model.projects[0]).count == 1)
        let agents = try String(contentsOf: folder.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(agents.hasPrefix("# 기존 안내\n") && agents.components(separatedBy: AgentScript.blockStart).count == 2)
        let skill = try String(contentsOf: folder.appendingPathComponent(".claude/skills/remotedebug/SKILL.md"), encoding: .utf8)
        #expect(skill.contains(w.model.agentScript.path) && skill.contains(project.path))
    }
}

@Suite("AgentIntegration")
struct AgentIntegrationTests {
    private func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(value)
    }

    @Test func mcpServerAnswersInitializeListAndCall() async throws {
        let calls = Mutex<[String]>([])
        let server = AgentMCPServer { command, path, scheme in
            calls.withLock { $0.append("\(command)|\(path)|\(scheme)") }
            return Data((command == "build" ? #"{"ok":true,"report":{"ok":true}}"# : #"{"ok":false,"error":"x"}"#).utf8)
        }
        let initialized = try object(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#.utf8)))
        let result = try #require(initialized["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect(await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)

        let listed = try object(await server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)))
        let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["remotedebug_status", "remotedebug_pairing_code", "remotedebug_pair_requests", "remotedebug_pair_decide", "remotedebug_push_file", "remotedebug_push_link", "remotedebug_files", "remotedebug_schemes", "remotedebug_build", "remotedebug_device_logs", "remotedebug_crash_logs"])

        let built = try object(await server.handle(Data(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"remotedebug_build","arguments":{"project_path":"/p","scheme":"App"}}}"#.utf8)))
        #expect((built["result"] as? [String: Any])?["isError"] as? Bool == false)
        #expect(built["id"] as? String == "a")
        let failed = try object(await server.handle(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"remotedebug_status"}}"#.utf8)))
        #expect((failed["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(calls.withLock { $0 } == ["build|/p|App", "status||"])

        let unknown = try object(await server.handle(Data(#"{"jsonrpc":"2.0","id":4,"method":"nope"}"#.utf8)))
        #expect(unknown["error"] != nil)
    }

    @Test func installerWritesSkillAndRegistersServer() async throws {
        let tmp = try TempDir("agent-install")
        let commands = Mutex<[String]>([])
        let installer = AgentInstaller(home: tmp.path("home"), serverPath: "/Applications/Remote Debug.app/Contents/MacOS/RemoteDebug", scriptPath: "/s/rd") { command in
            commands.withLock { $0.append(command) }
            return (command == "command -v codex" ? 1 : 0, "")
        }
        #expect(!installer.isInstalled(.claude))
        #expect(await installer.install(.claude).ok)
        #expect(installer.isInstalled(.claude))
        let skill = try String(contentsOf: installer.skillFile(.claude), encoding: .utf8)
        #expect(skill.contains("remotedebug_build") && skill.contains("'/s/rd' build"))
        #expect(commands.withLock { $0.last }?.hasSuffix("claude mcp add --scope user remotedebug -- '/Applications/Remote Debug.app/Contents/MacOS/RemoteDebug' --mcp") == true)

        // CLI가 없으면 스킬만 설치하고 그렇게 알린다.
        let codex = await installer.install(.codex)
        #expect(!codex.ok && installer.isInstalled(.codex))
        #expect(await installer.uninstall(.codex).ok && !installer.isInstalled(.codex))
    }
}
