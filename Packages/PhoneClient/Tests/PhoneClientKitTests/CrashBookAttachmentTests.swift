import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

/// 피드백의 첨부는 보낼 때까지만 이 기기에 둔다.
@MainActor
@Suite struct CrashBookAttachmentTests {
    private func feedback(_ message: String) -> CrashReport {
        .feedback(message: message, bundleId: "com.example.app", appVersion: "1.0",
                  attachments: [.init(name: "photo-1.jpg", type: "image/jpeg", data: Data("jpeg".utf8)),
                                .init(name: "note.txt", type: "text/plain", data: Data("note".utf8))],
                  date: Date(timeIntervalSince1970: 1_794_478_500))
    }

    @Test func attachmentsAreKeptUntilSentThenRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crashbook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = CrashBook(directory: directory)
        let report = feedback("느려요")
        let item = try #require(book.add(report))
        let file = try #require(book.attachmentsURL(item))
        #expect(FileManager.default.fileExists(atPath: file.path))
        // 앱을 다시 열어도 보낼 기록에 첨부가 들어 있다.
        #expect(CrashBook(directory: directory).report(item)?.attachments == report.attachments)

        book.markSent(item.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(book.report(item)?.attachments.isEmpty == true)
    }

    @Test func removingARecordRemovesItsAttachments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crashbook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = CrashBook(directory: directory)
        let item = try #require(book.add(feedback("멈춰요")))
        book.remove(item.id)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["index.json"])
    }

    @Test func memoryOnlyBookCarriesAttachments() throws {
        let book = CrashBook()
        let report = feedback("깨져요")
        let item = try #require(book.add(report))
        #expect(book.report(item)?.attachments == report.attachments)
        book.markSent(item.id)
        #expect(book.report(item)?.attachments.isEmpty == true)
    }
}
