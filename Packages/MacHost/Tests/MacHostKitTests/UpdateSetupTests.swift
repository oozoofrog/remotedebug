import Foundation
import Testing
@testable import MacHostKit

@Suite struct UpdateSetupTests {
    @Test func detectsPackageInProjectFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rd-update-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xcodeproj = dir.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        let pbx = xcodeproj.appendingPathComponent("project.pbxproj")
        try Data("// empty\n".utf8).write(to: pbx)
        let project = ConnectedProject(container: xcodeproj.path, scheme: "App", addedAt: Date())
        #expect(!UpdateSetup.isAdded(to: project))
        try Data("productName = RemoteDebugUpdate;\n".utf8).write(to: pbx)
        #expect(UpdateSetup.isAdded(to: project))
    }

    @Test func snippetWrapsMacHostInDebugAndIncludesViews() {
        let filled = UpdateSetup.snippet(host: "rd-mac-1a2b3c4d.tail0001.ts.net")
        #expect(filled.contains("import RemoteDebugUpdate"))
        #expect(filled.contains("#if DEBUG"))
        #expect(filled.contains(#"RemoteDebugUpdate.start(macHost: "rd-mac-1a2b3c4d.tail0001.ts.net")"#))
        #expect(filled.contains(".remoteDebugUpdateBanner()"))
        #expect(filled.contains("RemoteDebugUpdateSection()"))

        let empty = UpdateSetup.snippet(host: "")
        #expect(empty.contains("<이 Mac의 주소>"))
    }

    @Test func mcpListsAndRoutesUpdateSetupTool() async throws {
        let server = AgentMCPServer { command, path, _, _ in
            #expect(command == "update-setup")
            #expect(path == "/tmp/MyApp")
            return Data(#"{"ok":true,"update":{"product":"RemoteDebugUpdate"}}"#.utf8)
        }
        let listReq = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let listResp = try #require(await server.handle(listReq))
        #expect(String(decoding: listResp, as: UTF8.self).contains("remotedebug_update_setup"))

        let callReq = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"remotedebug_update_setup","arguments":{"project_path":"/tmp/MyApp"}}}"#.utf8)
        let callResp = try #require(await server.handle(callReq))
        let text = String(decoding: callResp, as: UTF8.self)
        #expect(text.contains("RemoteDebugUpdate"))
        #expect(text.contains(#""isError":false"#))
    }
}
