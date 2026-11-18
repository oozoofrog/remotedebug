import XCTest
@testable import RemoteDebugFeedback

final class FeedbackClientTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rdfeedback-\(UUID().uuidString)", isDirectory: true)
    }

    // Mac으로 보내는 길은 개발 빌드에만 있다.
    #if DEBUG
    private func reply(_ status: Int) -> FeedbackClient.Send {
        { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    func testEndpointAcceptsHostAndURL() {
        XCTAssertEqual(FeedbackClient.endpoint(host: " https://RD-Mac-1a2b3c4d.tail0001.ts.net/ ")?.absoluteString,
                       "https://rd-mac-1a2b3c4d.tail0001.ts.net/v1/crashes")
        XCTAssertNil(FeedbackClient.endpoint(host: "localhost"))
        XCTAssertNil(FeedbackClient.endpoint(host: "a b.example"))
        XCTAssertNil(FeedbackClient.endpoint(host: ""))
    }

    func testDeliveredReportLeavesNothingBehind() async {
        let dir = directory()
        let client = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: dir, send: reply(202))
        let delivered = await client.submit(RemoteDebugFeedback.report(message: "버튼이 눌리지 않아요", details: "", date: Date()))
        let pending = await client.pending()
        XCTAssertTrue(delivered)
        XCTAssertTrue(pending.isEmpty)
    }

    func testUnreachableMacKeepsReportUntilNextFlush() async {
        let dir = directory()
        let offline = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: dir) { _ in throw URLError(.cannotFindHost) }
        let delivered = await offline.submit(RemoteDebugFeedback.report(message: "화면이 멈춰요", details: "", date: Date()))
        let kept = await offline.pending()
        XCTAssertFalse(delivered)
        XCTAssertEqual(kept.count, 1)

        let unpaired = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: dir, send: reply(403))
        await unpaired.flush()
        let stillKept = await unpaired.pending()
        XCTAssertEqual(stillKept.count, 1)

        let online = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: dir, send: reply(202))
        await online.flush()
        let left = await online.pending()
        XCTAssertTrue(left.isEmpty)
    }

    func testTrySendDoesNotQueue() async {
        let dir = directory()
        let offline = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: dir) { _ in throw URLError(.timedOut) }
        let delivered = await offline.trySend(RemoteDebugFeedback.report(message: "느려요", details: "", date: Date()))
        let pending = await offline.pending()
        XCTAssertFalse(delivered)
        XCTAssertTrue(pending.isEmpty)
    }

    #endif

    func testLogKeepsRecentLinesOnly() {
        let log = FeedbackLog(isAllowed: { true })
        for index in 0..<(FeedbackLog.limit + 20) { log.add("line \(index)") }
        XCTAssertEqual(log.recorded.count, FeedbackLog.limit)
        XCTAssertTrue(log.recorded.last?.hasSuffix("line \(FeedbackLog.limit + 19)") ?? false)
    }

    func testLogFilterKeepsOnlyLinesFromImagesInsideTheApp() {
        let app: Set<String> = ["SampleApp", "SampleKit"]
        XCTAssertTrue(FeedbackLog.isFromApp(subsystem: "", sender: "SampleApp", appImages: app))
        XCTAssertTrue(FeedbackLog.isFromApp(subsystem: "com.example.app", sender: "SampleKit", appImages: app))
        // 하위 시스템 이름이 붙어 있어도, 남긴 이미지가 앱 것이 아니면 받지 않는다(시스템 라이브러리, 다른 SDK).
        XCTAssertFalse(FeedbackLog.isFromApp(subsystem: "com.example.app", sender: "CFNetwork", appImages: app))
        XCTAssertFalse(FeedbackLog.isFromApp(subsystem: "org.example.sdk", sender: "libsystem_trace.dylib", appImages: app))
        XCTAssertFalse(FeedbackLog.isFromApp(subsystem: "", sender: "Metal", appImages: app))
        XCTAssertFalse(FeedbackLog.isFromApp(subsystem: "", sender: "", appImages: app))
        // Apple 하위 시스템은 앱 이미지가 남겼어도 뺀다.
        XCTAssertFalse(FeedbackLog.isFromApp(subsystem: "com.apple.network", sender: "SampleApp", appImages: app))
    }

    func testAppImagesAreTheExecutableAndImagesUnderTheBundle() {
        let names = FeedbackLog.appImageNames(bundlePath: "/Apps/Sample.app", executable: "Sample", loaded: [
            "/Apps/Sample.app/Sample", "/Apps/Sample.app/Frameworks/SampleKit.framework/SampleKit",
            "/Apps/Sample.app.other/Evil", "/usr/lib/libSystem.B.dylib", "/System/Library/Frameworks/Metal.framework/Metal",
        ])
        XCTAssertEqual(names, ["Sample", "SampleKit"])
        // 실제 프로세스에서도 시스템 라이브러리는 들어가지 않는다.
        let real = FeedbackLog.appImageNames()
        XCTAssertFalse(real.contains("libSystem.B.dylib") || real.contains("Foundation") || real.contains("CFNetwork"))
        XCTAssertFalse(FeedbackLog.loadedImagePaths().isEmpty)
    }

    /// 동의를 거두는 쪽이 `clear`를 끝낸 뒤에, 그 전에 허락을 확인해 둔 `add`가 줄을 덧붙이면 안 된다.
    func testLineIsNotAddedWhenConsentIsWithdrawnWhileWaitingForTheLock() {
        let calls = Counter()
        // 첫 확인(잠그기 전)은 허락, 그 뒤(잠근 뒤)는 거둔 상태.
        let log = FeedbackLog(isAllowed: { calls.next() == 1 })
        log.add("동의를 거두는 사이에 들어온 줄")
        XCTAssertTrue(log.recorded.isEmpty)
        XCTAssertEqual(calls.value, 2, "잠근 뒤에 한 번 더 확인한다")
    }

    #if DEBUG
    func testReportCarriesMessageAndKind() throws {
        let report = RemoteDebugFeedback.report(message: "느려요", details: "최근 화면: 설정", image: Data("jpeg".utf8), date: Date(timeIntervalSince1970: 1_794_478_500))
        XCTAssertEqual(report.kind, "feedback")
        XCTAssertEqual(report.image, "anBlZw==")
        XCTAssertTrue(report.text.hasPrefix("느려요\n"))
        XCTAssertTrue(report.text.contains("최근 화면: 설정"))
        XCTAssertTrue(report.name.hasSuffix(".txt"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "name", "bundleId", "appVersion", "crashedAt", "text", "image", "message"])
        XCTAssertEqual(report.message, "느려요")
    }

    #endif

    /// 기기에 남은 진단 파일은 앱을 시작할 때와 새 파일을 만들기 전에 지운다(옛 이름의 폴더 포함).
    func testLeftoverDiagnosticFilesAreRemoved() throws {
        let root = directory()
        let fm = FileManager.default
        for name in ["AppFeedback", "AppFeedback-1A2B", "Other"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("a.afdiag"))
        }
        FeedbackSession.removeLeftovers(in: root)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["Other"])
    }

    func testLongLogLinesAreCut() {
        let log = FeedbackLog(isAllowed: { true })
        log.add(String(repeating: "a", count: 5000))
        XCTAssertLessThanOrEqual(log.collect(window: 0).last?.count ?? .max, FeedbackLog.lineLimit + 80)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
