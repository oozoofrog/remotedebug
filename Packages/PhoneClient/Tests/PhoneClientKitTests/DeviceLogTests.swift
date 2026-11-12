import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

@MainActor
@Suite struct DeviceLogTests {
    @Test func refreshSendsPendingLogsAndClearsThem() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        h.transport.on("POST", "/v1/logs", .json(#"{"accepted":3}"#, status: 202))
        h.model.log(.info, "app", "앱 시작")
        await h.model.restore()

        #expect(h.transport.count("POST", "/v1/logs") == 1)
        let body = try #require(h.transport.requests.last { $0.url?.path == "/v1/logs" }?.jsonBody)
        let entries = try #require(body["entries"] as? [[String: Any]])
        #expect(entries.first?["message"] as? String == "앱 시작")
        #expect(entries.contains { ($0["source"] as? String) == "builds" })
        #expect(h.model.logBook.unsentCount == 0)
        #expect(h.model.logsSentAt != nil)
        #expect(h.model.logSendError == nil)
    }

    @Test func failedSendKeepsLogsForNextTime() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        h.transport.on("POST", "/v1/logs", .fail(.networkConnectionLost), .json(#"{"accepted":1}"#, status: 202))
        h.model.log(.warning, "update", "업데이트 설치 시작")
        await h.model.restore()
        #expect(h.model.logBook.unsentCount > 0)
        #expect(h.model.logSendError != nil)
        #expect(h.model.lastError == nil)

        await h.model.sendLogs()
        #expect(h.model.logBook.unsentCount == 0)
        #expect(h.model.logSendError == nil)
    }

    @Test func doesNotSendWithoutTunnelOrHost() async {
        let off = Harness(tunnel: .off, storedHost: Harness.pairedHost)
        off.model.log(.info, "app", "x")
        await off.model.sendLogs()
        #expect(off.transport.count("POST", "/v1/logs") == 0)

        let unpaired = Harness()
        unpaired.model.log(.info, "app", "x")
        await unpaired.model.sendLogs()
        #expect(unpaired.transport.count("POST", "/v1/logs") == 0)
    }

    @Test func sendsInBatchesOf200() async {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        h.transport.on("POST", "/v1/logs", .json(#"{"accepted":200}"#, status: 202))
        for i in 0..<450 { h.model.log(.debug, "test", "줄 \(i)") }
        await h.model.restore()
        #expect(h.transport.count("POST", "/v1/logs") == 3)
        #expect(h.model.logBook.unsentCount == 0)
    }

    @Test func bookSurvivesRelaunchThroughFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("logbook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("device-log.json")

        let first = DeviceLogBook(fileURL: file)
        first.log(.info, "install", "업데이트 설치 시작")
        first.log(.error, "install", String(repeating: "가", count: 3000))

        let second = DeviceLogBook(fileURL: file)
        #expect(second.unsentCount == 2)
        #expect(second.recent.first?.message == "업데이트 설치 시작")
        #expect((second.recent.last?.message.utf8.count ?? 0) <= DeviceLogBatch.maxMessageBytes)

        second.markSent(second.nextBatch())
        #expect(DeviceLogBook(fileURL: file).unsentCount == 0)
    }

    @Test func keepsOnlyNewestWhenOverLimit() {
        let book = DeviceLogBook()
        for i in 0..<(DeviceLogBook.maxUnsent + 5) { book.log(.debug, "t", "\(i)") }
        #expect(book.unsentCount == DeviceLogBook.maxUnsent)
        #expect(book.nextBatch().first?.message == "5")
        #expect(book.recent.count == DeviceLogBook.maxRecent)
    }
}
