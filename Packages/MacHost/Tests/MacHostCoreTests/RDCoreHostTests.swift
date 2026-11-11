import Foundation
import MacHostKit
import RDModels
import Synchronization
import Testing
@testable import MacHostCore

/// 임시 폴더는 /Volumes/eyedisk/build 아래에 둔다(내장 디스크를 쓰지 않는다).
final class CoreTempDir: @unchecked Sendable {
    let url: URL

    init(_ label: String) throws {
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: env["RD_TEST_TMPDIR"] ?? "/Volumes/eyedisk/build/remotedebug/mac-host-tmp", isDirectory: true)
        // 경로가 길면 tsnet 소켓 경로 한도에 걸릴 수 있어 짧게 짓는다.
        url = base.appendingPathComponent("c-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func config(controlURL: String = "http://127.0.0.1:1", listenTLS: Bool = false) throws -> CoreConfig {
        let paths = HostPaths(root: url)
        try paths.prepare()
        return CoreConfig(mode: .host, stateDir: paths.stateDir.path, hostname: "rd-mac-0000test", controlURL: controlURL,
                          listenTLS: listenTLS, port: 0, publishDir: paths.publishedDir.path, logPath: paths.coreLogFile.path)
    }
}

func expectCode(_ code: String, _ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        try await body()
        Issue.record("\(code) 오류가 나야 했다", sourceLocation: sourceLocation)
    } catch let error as APIErrorBody {
        #expect(error.error.code == code, "code=\(error.error.code) message=\(error.error.message)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("APIErrorBody가 아니다: \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("RDCoreHost", .serialized)
struct RDCoreHostTests {
    @Test func invalidConfigFailsWithoutStartingANode() async throws {
        let tmp = try CoreTempDir("invalid")
        let host = RDCoreHost()
        // 평문 HTTP는 루프백 제어 서버에서만 허용된다.
        let config = try tmp.config(controlURL: "https://control.invalid", listenTLS: false)
        await expectCode("invalid_config") { try await host.start(config) }
        #expect(host.handle == nil)
        await expectCode("not_running") { _ = try await host.status() }
    }

    @Test func callsBeforeStartReportNotRunning() async throws {
        let host = RDCoreHost()
        await expectCode("not_running") { _ = try await host.status() }
        await expectCode("not_running") { try await host.setDevices([]) }
        await expectCode("not_running") { _ = try await host.openPairing(ttlSeconds: 60) }
        await expectCode("not_running") { try await host.unpublish(buildID: "b_00000000") }
        await expectCode("not_running") { _ = try await host.decidePairing(requestID: "pr_x", allow: true) }
        var count = 0
        for await _ in host.events() { count += 1 }
        #expect(count == 0)
        await host.stop()  // 노드가 없어도 안전하다
    }

    /// 닿지 않는 루프백 제어 서버로 노드를 띄운다(tailnet에는 올라가지 않는다).
    @Test(.timeLimit(.minutes(2)))
    func lifecycleWithUnreachableControlServer() async throws {
        let tmp = try CoreTempDir("life")
        let config = try tmp.config()
        let host = RDCoreHost(eventPollMilliseconds: 100)
        try await host.start(config)
        #expect(host.handle != nil)

        let status = try await host.status()
        #expect(status.backendState != .running)

        // 같은 stateDir를 쓰는 두 번째 노드는 거절된다(addenda A.3).
        let other = RDCoreHost()
        await expectCode("invalid_config") { try await other.start(config) }
        // 이미 실행 중인 어댑터에 다시 start하면 거절한다.
        await expectCode("invalid_config") { try await host.start(config) }

        // 코어 오류 코드가 그대로 올라온다.
        await expectCode("bad_request") { _ = try await host.openPairing(ttlSeconds: 4000) }
        await expectCode("build_not_found") { try await host.unpublish(buildID: "b_deadbeef") }
        try await host.setDevices([])

        let code = try await host.openPairing(ttlSeconds: 60)
        #expect(code.code.count == 8)
        #expect(code.expiresAt > Date())
        #expect(code.expiresAt < Date().addingTimeInterval(120))

        // stop하면 이벤트 스트림이 끝난다.
        let stream = host.events()
        let drained = Task { for await _ in stream {} }
        await host.stop()
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await drained.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(ended, "stop 뒤 이벤트 스트림이 끝나지 않았다")
        #expect(host.handle == nil)
        await expectCode("not_running") { _ = try await host.status() }

        // stop 뒤 같은 stateDir로 다시 시작할 수 있다.
        try await other.start(config)
        await other.stop()
    }

    /// rd_stop 뒤에 원시 스트림에 들어온 이벤트(세션 failed, addenda C.3)를 stop이 끝나기 전에 구독자에게 넘긴다.
    /// 원시 스트림은 노드가 멈춘 것을 본 뒤 150ms 늦게 이벤트를 내고 끝난다(펌프가 아직 넘기지 못한 이벤트를 흉내 낸다).
    @Test(.timeLimit(.minutes(1)))
    func stopDeliversEventsQueuedAtShutdown() async throws {
        let tmp = try CoreTempDir("drain")
        let config = try tmp.config()
        let failed = #"{"type":"session","sessionId":"s_1","buildId":"b_00000001","nodeName":"rd-phone-1","state":"failed","userAgent":"","bytesServed":7}"#
        let host = RDCoreHost(eventPollMilliseconds: 100, drainMargin: .seconds(2)) { node, _ in
            AsyncStream<Data> { continuation in
                let task = Task.detached {
                    // 노드가 멈출 때까지(rd_status가 실패할 때까지) 기다린다.
                    while (try? node.status()) != nil { try? await Task.sleep(for: .milliseconds(10)) }
                    try? await Task.sleep(for: .milliseconds(150))
                    continuation.yield(Data(failed.utf8))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        try await host.start(config)
        let stream = host.events()
        let collected = Task { () -> [CoreEvent] in
            var events: [CoreEvent] = []
            for await e in stream { events.append(e) }
            return events
        }
        await host.stop()
        let events = await collected.value
        let sessions = events.compactMap { if case .session(let e) = $0 { e } else { nil } }
        #expect(sessions.map(\.state) == [.failed], "stop이 rd_stop 뒤의 이벤트를 넘기지 않았다: \(events)")
        #expect(sessions.first?.bytesServed == 7)
    }

    /// 원시 스트림이 끝나지 않아도 stop은 한도 안에 끝나고 스트림을 닫는다.
    /// `.timeLimit`은 취소할 수 없는 대기를 끊지 못한다. 그래서 테스트 안에서 기한을 두고, 막히면 실패로 끝낸다.
    @Test(.timeLimit(.minutes(1)))
    func stopIsBoundedWhenRawStreamHangs() async throws {
        let tmp = try CoreTempDir("hang")
        let config = try tmp.config()
        let host = RDCoreHost(eventPollMilliseconds: 50, drainMargin: .milliseconds(200)) { _, _ in
            AsyncStream<Data> { _ in }
        }
        try await host.start(config)
        let stream = host.events()
        let drained = Task { for await _ in stream {} }
        let stopped = await finishes(within: .seconds(5)) { await host.stop() }
        #expect(stopped, "stop이 한도 안에 끝나지 않았다")
        guard stopped else { return }
        let ended = await finishes(within: .seconds(5)) { await drained.value }
        #expect(ended, "stop 뒤 이벤트 스트림이 끝나지 않았다")
    }

    /// `body`가 `limit` 안에 끝나면 true. 막히면 그 작업을 버리고 false로 돌아온다.
    private func finishes(within limit: Duration, _ body: @escaping @Sendable () async -> Void) async -> Bool {
        let waiter = Mutex<CheckedContinuation<Bool, Never>?>(nil)
        let answer: @Sendable (Bool) -> Void = { value in waiter.withLock { $0.take() }?.resume(returning: value) }
        return await withCheckedContinuation { continuation in
            waiter.withLock { $0 = continuation }
            Task.detached { await body(); answer(true) }
            Task.detached { try? await Task.sleep(for: limit); answer(false) }
        }
    }

    @Test func publishOutsidePublishDirIsRejectedByCore() async throws {
        let tmp = try CoreTempDir("pub")
        let config = try tmp.config()
        let host = RDCoreHost()
        try await host.start(config)
        let outside = tmp.url.appendingPathComponent("outside.ipa")
        try Data("x".utf8).write(to: outside)
        let descriptor = BuildDescriptor(
            id: BuildDescriptor.makeID(bundleId: "com.example.x", ipaSHA256: String(repeating: "0", count: 64)),
            bundleId: "com.example.x", displayName: "X", version: "1", buildNumber: "1", minOS: "26.0", debug: true,
            configuration: "Debug", configurationEvidence: .path,
            signing: .init(teamId: "T", profileName: "P", profileExpires: Date().addingTimeInterval(86_400), provisionedDeviceCount: 1, getTaskAllow: true),
            ipa: .init(size: 1, sha256: String(repeating: "0", count: 64)), publishedAt: Date())
        await expectCode("path_outside_publish_dir") {
            try await host.publish(PublishRequest(build: descriptor, ipaPath: outside.path))
        }
        await host.stop()
    }
}
