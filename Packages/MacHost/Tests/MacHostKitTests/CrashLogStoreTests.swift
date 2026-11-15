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

    private func report(_ n: Int, device: String, crashedAt: Date) -> DeviceCrashEvent {
        DeviceCrashEvent(deviceId: device, deviceName: device, nodeName: "rd-phone-1",
                         report: CrashReport(kind: .ips, name: "r\(n).ips", bundleId: "com.example.app", appVersion: "1",
                                             crashedAt: crashedAt, text: "report \(n) \(device)"))
    }

    @Test func keepsAtMostPerDeviceLimitPerDevice() throws {
        let dir = try TempDir("crashes-cap")
        let clock = TickingClock()
        let store = CrashLogStore(directory: dir.url, now: { clock.tick() })
        for n in 0..<(CrashLogStore.perDeviceLimit + 5) {
            store.receive(report(n, device: "d_a", crashedAt: Date(timeIntervalSince1970: 1_000_000 + Double(n))))
        }
        store.receive(report(0, device: "d_b", crashedAt: Date(timeIntervalSince1970: 1_000_000)))
        #expect(store.items.filter { $0.deviceId == "d_a" }.count == CrashLogStore.perDeviceLimit)
        #expect(store.items.filter { $0.deviceId == "d_b" }.count == 1)
        // 지운 기록의 원문 파일도 없다.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).filter { $0.hasSuffix(".ips") }
        #expect(files.count == CrashLogStore.perDeviceLimit + 1)
    }

    /// 보관 기록을 고를 때 보낸 쪽의 `crashedAt`이 아니라 이 Mac이 받은 시각을 쓴다.
    @Test func pruningUsesReceiveTimeNotCrashTime() throws {
        let dir = try TempDir("crashes-receive")
        let clock = TickingClock()
        let store = CrashLogStore(directory: dir.url, now: { clock.tick() })
        // 먼저 받은 기록들의 crashedAt이 나중 것보다 늦다.
        for n in 0..<CrashLogStore.perDeviceLimit {
            store.receive(report(n, device: "d_a", crashedAt: Date(timeIntervalSince1970: 4_000_000_000 - Double(n))))
        }
        store.receive(report(999, device: "d_a", crashedAt: Date(timeIntervalSince1970: 1)))
        let names = Set(store.items.map(\.name))
        #expect(names.contains("r999.ips"), "가장 최근에 받은 기록이 남는다")
        #expect(!names.contains("r0.ips"), "가장 먼저 받은 기록이 지워진다")
        #expect(store.items.count == CrashLogStore.perDeviceLimit)
    }
}

/// 부를 때마다 1초씩 가는 시계.
final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func tick() -> Date {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
