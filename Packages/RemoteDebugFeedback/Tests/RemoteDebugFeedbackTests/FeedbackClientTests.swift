import XCTest
@testable import RemoteDebugFeedback

final class FeedbackClientTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rdfeedback-\(UUID().uuidString)", isDirectory: true)
    }

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

    func testReportCarriesMessageAndKind() throws {
        let report = RemoteDebugFeedback.report(message: "느려요", details: "최근 화면: 설정", date: Date(timeIntervalSince1970: 1_794_478_500))
        XCTAssertEqual(report.kind, "feedback")
        XCTAssertTrue(report.text.hasPrefix("느려요\n"))
        XCTAssertTrue(report.text.contains("최근 화면: 설정"))
        XCTAssertTrue(report.name.hasSuffix(".txt"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "name", "bundleId", "appVersion", "crashedAt", "text"])
    }
}
