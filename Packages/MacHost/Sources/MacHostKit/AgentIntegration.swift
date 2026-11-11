import Foundation

/// 실행 중인 RemoteDebug 앱에 명령을 보내는 쪽(요청·응답 파일). `agent/rd` 스크립트와 같은 규칙이다.
public struct AgentChannel: Sendable {
    public var agentDir: URL
    public var bundleID: String

    public init(agentDir: URL, bundleID: String) {
        self.agentDir = agentDir
        self.bundleID = bundleID
    }

    static func failure(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": message])) ?? Data()
    }

    var isAppAlive: Bool {
        guard let text = try? String(contentsOf: agentDir.appendingPathComponent("pid"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return kill(pid, 0) == 0
    }

    /// 앱이 꺼져 있으면 열고, 요청을 쓴 뒤 응답 JSON을 기다린다.
    public func send(command: String, path: String, scheme: String) async -> Data {
        if !isAppAlive {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-gb", bundleID]
            try? open.run()
            for _ in 0..<60 where !isAppAlive { try? await Task.sleep(for: .milliseconds(500)) }
        }
        guard isAppAlive else { return Self.failure("RemoteDebug 앱이 실행 중이 아닙니다. 앱을 열고 다시 시도하세요.") }
        let id = "\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
        let requests = agentDir.appendingPathComponent("requests", isDirectory: true)
        let temp = requests.appendingPathComponent("\(id).tmp")
        let response = agentDir.appendingPathComponent("responses/\(id).json")
        do {
            try Data("\(command)\n\(path)\n\(scheme)\n".utf8).write(to: temp)
            try FileManager.default.moveItem(at: temp, to: requests.appendingPathComponent("\(id).req"))
        } catch {
            return Self.failure("요청을 보내지 못했습니다: \(HostErrorText.message(for: error))")
        }
        while true {
            if let data = try? Data(contentsOf: response) {
                try? FileManager.default.removeItem(at: response)
                return data
            }
            if !isAppAlive { return Self.failure("응답을 기다리는 중에 RemoteDebug 앱이 종료됐습니다.") }
            if Task.isCancelled { return Self.failure("요청을 취소했습니다.") }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}

/// 표준 입출력으로 동작하는 MCP 서버. 한 줄에 JSON-RPC 메시지 하나를 받는다.
/// 앱 실행 파일을 `--mcp` 인자로 띄우면 이 서버가 돌고, 명령은 실행 중인 앱에 넘긴다.
public struct AgentMCPServer: Sendable {
    public typealias Send = @Sendable (_ command: String, _ path: String, _ scheme: String) async -> Data
    public static let argument = "--mcp"
    public static let serverName = "remotedebug"

    let send: Send

    public init(send: @escaping Send) {
        self.send = send
    }

    public init(channel: AgentChannel) {
        self.init { await channel.send(command: $0, path: $1, scheme: $2) }
    }

    static var tools: [[String: Any]] { [
        tool("remotedebug_status", "RemoteDebug Mac 앱의 상태: 공유 중인지, iPhone용 설치 페이지 주소, 연결한 프로젝트 목록.", path: false, scheme: false),
        tool("remotedebug_schemes", "Xcode 프로젝트를 RemoteDebug에 연결하고 스킴 목록을 돌려준다.", path: true, scheme: false),
        tool("remotedebug_build", "Xcode 프로젝트를 Debug 기기용으로 빌드해 iPhone이 설치할 수 있게 게시한다. 빌드가 끝날 때까지 기다린다(몇 분 걸릴 수 있다). 설치는 사용자가 iPhone에서 누른다.", path: true, scheme: true),
    ] }

    static func tool(_ name: String, _ description: String, path: Bool, scheme: Bool) -> [String: Any] {
        var properties: [String: Any] = [:]
        if path {
            properties["project_path"] = ["type": "string", "description": "프로젝트 폴더나 .xcodeproj, .xcworkspace의 절대 경로"]
        }
        if scheme {
            properties["scheme"] = ["type": "string", "description": "빌드할 스킴. 비우면 마지막에 쓴 스킴이나 하나뿐인 스킴을 쓴다"]
        }
        return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": path ? ["project_path"] : []] as [String: Any]]
    }

    /// 메시지 하나를 처리한다. 알림이면 nil.
    public func handle(_ line: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> Data? { Self.encode(["jsonrpc": "2.0", "id": id, "result": value]) }
        switch method {
        case "initialize":
            return result([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": "1"],
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let commands = ["remotedebug_status": "status", "remotedebug_schemes": "schemes", "remotedebug_build": "build"]
            guard let command = commands[name] else {
                return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool: \(name)"]])
            }
            let data = await send(command, arguments["project_path"] as? String ?? "", arguments["scheme"] as? String ?? "")
            let ok = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["ok"] as? Bool ?? false
            return result(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": !ok])
        default:
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    /// 표준 입력이 닫힐 때까지 돈다.
    public func run() async {
        let output = FileHandle.standardOutput
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.isEmpty, let response = await handle(Data(line.utf8)) else { continue }
                output.write(response + Data("\n".utf8))
            }
        } catch {}
    }
}

/// Claude Code와 Codex에 RemoteDebug MCP 서버와 스킬을 설치한다(사용자 전체 범위).
public struct AgentInstaller: Sendable {
    public enum Target: String, CaseIterable, Sendable, Identifiable {
        case claude, codex

        public var id: String { rawValue }
        public var title: String { self == .claude ? "Claude Code" : "Codex" }
        var cli: String { rawValue }
        var skillsFolder: String { self == .claude ? ".claude/skills" : ".codex/skills" }
    }

    public struct Outcome: Sendable, Hashable {
        public var ok: Bool
        public var message: String
    }

    public typealias Shell = @Sendable (String) async -> (code: Int32, output: String)

    public var home: URL
    /// MCP 서버로 띄울 앱 실행 파일.
    public var serverPath: String
    /// 명령줄 도구 `agent/rd`.
    public var scriptPath: String
    var shell: Shell

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, serverPath: String, scriptPath: String,
                shell: @escaping Shell = AgentInstaller.loginShell) {
        self.home = home
        self.serverPath = serverPath
        self.scriptPath = scriptPath
        self.shell = shell
    }

    public func skillFile(_ target: Target) -> URL {
        home.appendingPathComponent("\(target.skillsFolder)/remotedebug/SKILL.md")
    }

    public func isInstalled(_ target: Target) -> Bool {
        FileManager.default.fileExists(atPath: skillFile(target).path)
    }

    func registerCommand(_ target: Target) -> String {
        let server = AgentScript.quoted(serverPath)
        let name = AgentMCPServer.serverName
        switch target {
        case .claude:
            return "claude mcp remove --scope user \(name) >/dev/null 2>&1; claude mcp add --scope user \(name) -- \(server) \(AgentMCPServer.argument)"
        case .codex:
            return "codex mcp remove \(name) >/dev/null 2>&1; codex mcp add \(name) -- \(server) \(AgentMCPServer.argument)"
        }
    }

    func unregisterCommand(_ target: Target) -> String {
        target == .claude ? "claude mcp remove --scope user \(AgentMCPServer.serverName)" : "codex mcp remove \(AgentMCPServer.serverName)"
    }

    /// 스킬 파일을 쓰고 MCP 서버를 등록한다.
    public func install(_ target: Target) async -> Outcome {
        let file = skillFile(target)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(AgentScript.globalSkill(script: scriptPath).utf8).write(to: file, options: [.atomic])
        } catch {
            return Outcome(ok: false, message: "스킬 파일을 쓰지 못했습니다: \(HostErrorText.message(for: error))")
        }
        guard await shell("command -v \(target.cli)").code == 0 else {
            return Outcome(ok: false, message: "스킬은 설치했습니다(\(file.path)). \(target.cli) 명령을 찾지 못해 MCP 서버는 등록하지 못했습니다.")
        }
        let result = await shell(registerCommand(target))
        guard result.code == 0 else {
            return Outcome(ok: false, message: "스킬은 설치했습니다. MCP 서버 등록에 실패했습니다: \(result.output.suffix(300))")
        }
        return Outcome(ok: true, message: "스킬과 MCP 서버를 설치했습니다. 새로 여는 \(target.title) 세션부터 쓸 수 있습니다.")
    }

    public func uninstall(_ target: Target) async -> Outcome {
        try? FileManager.default.removeItem(at: skillFile(target).deletingLastPathComponent())
        _ = await shell(unregisterCommand(target))
        return Outcome(ok: true, message: "\(target.title)에서 스킬과 MCP 서버를 제거했습니다.")
    }

    /// 사용자의 로그인 셸 설정(PATH)을 읽어 실행한다. 앱은 터미널의 PATH를 물려받지 않는다.
    public static let loginShell: Shell = { command in
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lic", command]
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    continuation.resume(returning: (127, HostErrorText.message(for: error)))
                }
            }
        }
    }
}

extension AgentScript {
    /// 모든 프로젝트에서 쓰는 전역 스킬.
    static func globalSkill(script: String) -> String {
        let rd = quoted(script)
        return """
        ---
        name: remotedebug
        description: 지금 작업 중인 Xcode 프로젝트의 Debug 빌드를 실제 iPhone에 설치할 수 있게 RemoteDebug Mac 앱으로 빌드·게시한다. "아이폰에 설치", "기기에서 확인", "실기기 빌드", "RemoteDebug로 올려줘" 같은 요청에 사용한다.
        ---

        # RemoteDebug

        RemoteDebug Mac 앱이 Xcode 프로젝트를 Debug 기기용으로 빌드해 tailnet 너머의 iPhone에 게시한다.

        ## 쓰는 법

        MCP 서버 `remotedebug`가 연결돼 있으면 그 도구를 쓴다.

        - `remotedebug_build`: `project_path`(프로젝트 폴더의 절대 경로), `scheme`(선택)
        - `remotedebug_schemes`: `project_path`
        - `remotedebug_status`

        도구가 보이지 않으면 같은 일을 하는 명령을 쓴다. JSON 한 줄을 출력하고 성공하면 종료 코드 0이다.

        ```sh
        \(rd) build <프로젝트 폴더> [스킴]
        \(rd) schemes <프로젝트 폴더>
        \(rd) status
        ```

        ## 결과 읽기

        - `build`는 빌드가 끝날 때까지 기다린다(몇 분 걸릴 수 있다). 스킴을 정하지 못하면 `schemes`가 함께 오니 하나를 골라 다시 부른다.
        - 실패하면 `error`와 `report.logTail`에 컴파일 오류가, `report.logPath`에 전체 로그 경로가 있다.
        - `report.published`가 게시된 빌드다. 비어 있고 `ok`가 true면 결과가 전과 같아 다시 게시하지 않은 것이다.
        - Mac은 게시까지만 한다. 설치는 페어링한 iPhone의 RemoteDebug 앱이나 설치 페이지(`installPage`)에서 사용자가 누른다.
        - `sharing`이 false면 iPhone이 빌드를 받을 수 없다. 사용자에게 RemoteDebug 앱에서 공유를 시작하라고 알린다.
        - 서명 오류(프로비저닝 프로필, 기기 미등록)는 여기서 고칠 수 없다. Xcode에서 한 번 기기용으로 빌드하라고 사용자에게 알린다.

        """
    }
}
