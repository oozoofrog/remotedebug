import Foundation
import RDModels
import Testing
@testable import MacHostKit

@MainActor
@Suite struct DeviceLogStoreTests {
    private func event(_ device: String, _ messages: [String], start: TimeInterval = 0) -> DeviceLogEvent {
        DeviceLogEvent(deviceId: device, deviceName: "폰 \(device)", nodeName: "rd-phone-\(device)", entries: messages.enumerated().map {
            DeviceLogEntry(at: Date(timeIntervalSince1970: 1_800_000_000 + start + Double($0.offset)), level: .info, source: "app", message: $0.element)
        })
    }

    @Test func keepsLogsPerDeviceAndReloadsFromFiles() throws {
        let dir = try TempDir("devlogs")
        let store = DeviceLogStore(directory: dir.url)
        store.receive(event("d_1", ["앱 시작", "VPN 연결됨"]))
        store.receive(event("d_2", ["다른 기기"]))
        store.receive(event("d_1", ["설치 요청"], start: 10))

        #expect(store.devices.map(\.id) == ["d_1", "d_2"])
        #expect(store.device(id: "d_1")?.entries.map(\.message) == ["앱 시작", "VPN 연결됨", "설치 요청"])

        let reloaded = DeviceLogStore(directory: dir.url)
        #expect(Set(reloaded.devices.map(\.id)) == ["d_1", "d_2"])
        #expect(reloaded.device(id: "d_1")?.entries.map(\.message) == ["앱 시작", "VPN 연결됨", "설치 요청"])
        #expect(reloaded.device(id: "d_1")?.name == "폰 d_1")

        reloaded.clear(deviceID: "d_1")
        #expect(DeviceLogStore(directory: dir.url).devices.map(\.id) == ["d_2"])
    }

    @Test func hostModelStoresDeviceLogEvents() async throws {
        let dir = try TempDir("devlogs-model")
        let model = HostModel(core: FakeHostCore(), paths: HostPaths(root: dir.url), bookmarks: FakeBookmarks(),
                              watcherOptions: .init(useFileEvents: false), id8: "abcd1234", hostDisplayName: "Mac", appVersion: "0.1.0")
        model.handle(.deviceLog(event("d_9", ["업데이트 설치 시작"])))
        #expect(model.deviceLogs.device(id: "d_9")?.entries.first?.message == "업데이트 설치 시작")
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("DeviceLogs/d_9.jsonl").path))
    }

    @Test func mcpToolReadsLogsFromDisk() async throws {
        let dir = try TempDir("devlogs-mcp")
        let store = DeviceLogStore(directory: dir.url)
        store.receive(event("d_1", ["앱 시작", "설치 실패: 다운로드할 수 없음", "VPN 상태: 꺼짐"]))
        let server = AgentMCPServer(deviceLogsDir: dir.url) { _, _, _ in Data() }
        let reply = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"remotedebug_device_logs","arguments":{"lines":2,"contains":"설치"}}}"#.utf8)))
        let text = String(decoding: reply, as: UTF8.self)
        #expect(text.contains("설치 실패"))
        #expect(!text.contains("앱 시작"))
        #expect(text.contains("1/1"))
    }
}
