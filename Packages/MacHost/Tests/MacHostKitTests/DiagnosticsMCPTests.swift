import Foundation
import Synchronization
import Testing
@testable import MacHostKit

@MainActor
@Suite struct DiagnosticsMCPTests {
    private let tool = "remotedebug_import_diagnostics"

    private func call(_ server: AgentMCPServer, _ arguments: [String: Any], name: String? = nil) async throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name ?? tool, "arguments": arguments],
        ])
        let reply = try #require(await server.handle(request))
        return try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    @Test func rejectsInvalidPathsBeforeSendingToTheApp() async throws {
        let sent = Mutex(0)
        let server = AgentMCPServer { _, _, _, _ in
            sent.withLock { $0 += 1 }
            return Data()
        }
        let arguments: [[String: Any]] = [
            [:], ["file_path": false], ["file_path": ""], ["file_path": "file.afdiag"],
            ["file_path": "file:///tmp/file.afdiag"], ["file_path": "/tmp/file.json"],
            ["file_path": "/tmp/first\r\nsecond.afdiag"], ["file_path": "/tmp/file\0.afdiag"],
        ]

        for input in arguments {
            let error = try await call(server, input)["error"] as? [String: Any]
            #expect(error?["code"] as? Int == -32602)
        }
        #expect(sent.withLock { $0 } == 0)
        let schema = AgentMCPServer.tools.first { $0["name"] as? String == tool }?["inputSchema"] as? [String: Any]
        #expect(schema?["required"] as? [String] == ["file_path"])
    }

    @Test func forwardsTheFilePathAndReturnsOnlyTheRecordIDOrFailure() async throws {
        let folder = try TempDir("diagnostics-mcp")
        let existing = folder.path("메일 첨부.AFDIAG").path
        let missing = folder.path("missing.afdiag").path
        let sent = Mutex<[String]>([])
        let logDirectory = folder.path("CrashLogs")
        let store = CrashLogStore(directory: logDirectory)
        let model = ProjectsModel(root: folder.url, importDiagnostics: { url in
            guard url.path == existing else { return .failure(DiagnosticsFailure("파일을 읽지 못했습니다.")) }
            guard let id = store.receive(.init(deviceId: "", deviceName: "메일 첨부", nodeName: "",
                                          report: .init(kind: .feedback, name: "report.json", bundleId: "app.example",
                                                        appVersion: "1.0", crashedAt: Date(), text: "sample log"))) else {
                return .failure(DiagnosticsFailure("시험 기록을 저장하지 못했습니다."))
            }
            return .success(id)
        }) { _, _ in nil }
        let server = AgentMCPServer(crashLogsDir: logDirectory) { command, path, scheme, project in
            sent.withLock { $0.append([command, path, scheme, project].joined(separator: "|")) }
            let response = await model.handleAgentRequest("\(command)\n\(path)\n\(scheme)\n\(project)\n")
            return (try? JSONEncoder().encode(response)) ?? Data()
        }

        let invalid = await model.handleAgentRequest("import-diagnostics\nrelative.afdiag\n\n")
        #expect(!invalid.ok)

        let success = try #require(try await call(server, ["file_path": existing])["result"] as? [String: Any])
        let content = try #require((success["content"] as? [[String: String]])?.first?["text"])
        let record = try #require(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let id = try #require(record["id"] as? String)
        #expect(record.keys.sorted() == ["id", "ok"])
        #expect(success["isError"] as? Bool == false)

        let read = try #require(try await call(server, ["id": id], name: "remotedebug_crash_logs")["result"] as? [String: Any])
        #expect((read["content"] as? [[String: String]])?.first?["text"] == "sample log")

        let failure = try #require(try await call(server, ["file_path": missing])["result"] as? [String: Any])
        #expect(failure["isError"] as? Bool == true)
        let message = try #require((failure["content"] as? [[String: String]])?.first?["text"])
        #expect(message.contains("파일을 읽지 못했습니다."))
        #expect(!message.contains(missing))
        #expect(sent.withLock { $0 } == ["import-diagnostics|\(existing)||", "import-diagnostics|\(missing)||"])
    }
}
