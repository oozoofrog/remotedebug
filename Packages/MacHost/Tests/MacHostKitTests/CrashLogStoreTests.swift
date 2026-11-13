import Foundation
import RDModels
import Testing
@testable import MacHostKit

@MainActor
@Suite struct CrashLogStoreTests {
    private let ips = """
    {"app_name":"Sample","timestamp":"2026-11-13 14:05:01.00 +0900","app_version":"1.2","build_version":"7","bundleID":"com.example.sample","bug_type":"309"}
    {"exception":{"type":"EXC_BAD_ACCESS"}}
    """

    private func event(_ text: String, name: String = "Sample.ips") -> DeviceCrashEvent {
        DeviceCrashEvent(deviceId: "d_1", deviceName: "폰", nodeName: "rd-phone-1",
                         report: .ips(name: name, text: text, fallbackDate: Date(timeIntervalSince1970: 0)))
    }

    @Test func readsAppAndTimeFromIpsHeader() {
        let report = CrashReport.ips(name: "Sample.ips", text: ips, fallbackDate: Date(timeIntervalSince1970: 0))
        #expect(report.bundleId == "com.example.sample")
        #expect(report.appVersion == "1.2 (7)")
        #expect(report.crashedAt == Date(timeIntervalSince1970: 1_794_546_301))
        let plain = CrashReport.ips(name: "x.ips", text: "not json", fallbackDate: Date(timeIntervalSince1970: 5))
        #expect(plain.bundleId.isEmpty && plain.crashedAt == Date(timeIntervalSince1970: 5))
    }

    @Test func storesOncePerReportAndReloads() throws {
        let dir = try TempDir("crashes")
        let store = CrashLogStore(directory: dir.url)
        store.receive(event(ips))
        store.receive(event(ips))
        store.receive(event("다른 기록", name: "Other.ips"))
        #expect(store.items.count == 2)
        let first = try #require(store.items.first)
        #expect(first.title == "sample" && store.text(first) == ips)

        let reloaded = CrashLogStore(directory: dir.url)
        #expect(reloaded.items.map(\.id) == store.items.map(\.id))
        reloaded.remove(first.id)
        #expect(CrashLogStore(directory: dir.url).items.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent(first.file).path))
    }

    @Test func hostModelStoresCrashEventsAndMCPReadsThem() async throws {
        let dir = try TempDir("crashes-model")
        let model = HostModel(core: FakeHostCore(), paths: HostPaths(root: dir.url), bookmarks: FakeBookmarks(),
                              watcherOptions: .init(useFileEvents: false), id8: "abcd1234", hostDisplayName: "Mac", appVersion: "0.1.0")
        let decoded = try RDJSON.decoder().decode(CoreEvent.self, from: RDJSON.encoder().encode(CoreEvent.deviceCrash(event(ips))))
        model.handle(decoded)
        let item = try #require(model.crashLogs.items.first)

        let server = AgentMCPServer(crashLogsDir: dir.url.appendingPathComponent("CrashLogs")) { _, _, _, _ in Data() }
        let list = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"remotedebug_crash_logs","arguments":{}}}"#.utf8)))
        #expect(String(decoding: list, as: UTF8.self).contains(item.id))
        let one = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"remotedebug_crash_logs","arguments":{"id":"\#(item.id)"}}}"#.utf8)))
        #expect(String(decoding: one, as: UTF8.self).contains("EXC_BAD_ACCESS"))
    }
}
