import Foundation
import Testing
@testable import RDModels

/// docs/protocol-addenda.md L.1의 선택 필드 `attachments`. 옛 모양(`image`만)과 새 모양을 모두 읽는다.
@Suite struct CrashAttachmentTests {
    @Test func oldShapeWithImageOnlyStillDecodes() throws {
        let json = #"{"kind":"feedback","crashedAt":"2026-11-13T05:05:01.000Z","text":"화면이 깨져요","image":"aGVsbG8="}"#
        let report = try RDJSON.decoder().decode(CrashReport.self, from: Data(json.utf8))
        #expect(report.image == Data("hello".utf8))
        #expect(report.attachments.isEmpty)
        // 첨부가 없으면 키를 쓰지 않는다.
        let object = try #require(JSONSerialization.jsonObject(with: RDJSON.encoder().encode(report)) as? [String: Any])
        #expect(object["attachments"] == nil && object["image"] as? String == "aGVsbG8=")
    }

    @Test func idCoversAttachmentsAndStaysTheSameWithoutThem() throws {
        let date = Date(timeIntervalSince1970: 1_794_478_500)
        func report(_ files: [String], image: String? = nil) -> CrashReport {
            CrashReport(kind: .feedback, name: "f.txt", bundleId: "com.example.app", appVersion: "1.0", crashedAt: date, text: "같은 글",
                        image: image.map { Data($0.utf8) }, attachments: files.map { .init(name: "a.txt", data: Data($0.utf8)) })
        }
        // 첨부가 없으면 글의 SHA-256 앞 6바이트(예전 값) 그대로다.
        #expect(report([]).id == "c_c550da31bb69")
        let ids = [report([]), report(["하나"]), report(["둘"]), report(["하나", "둘"]), report([], image: "하나")].map(\.id)
        #expect(Set(ids).count == ids.count, "글이 같아도 첨부가 다르면 다른 기록이다")
        #expect(report(["하나"]).id == report(["하나"]).id)
        // 이름과 종류는 id에 넣지 않는다(코어가 이름을 고쳐도 같은 기록이다).
        var renamed = report(["하나"])
        renamed.attachments[0].name = "b.txt"
        #expect(renamed.id == report(["하나"]).id)
    }

    @Test func messageIsCarriedSeparatelyAndOmittedWhenAbsent() throws {
        let report = CrashReport.feedback(message: "  느려요\n둘째 줄 ", bundleId: "com.example.app", appVersion: "1.0", details: "최근 로그",
                                          date: Date(timeIntervalSince1970: 1_794_478_500))
        #expect(report.message == "느려요\n둘째 줄" && report.text.hasPrefix("느려요\n둘째 줄\n\n---\n"))
        let data = try RDJSON.encoder().encode(report)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String == "느려요\n둘째 줄")
        #expect(try RDJSON.decoder().decode(CrashReport.self, from: data) == report)
        let old = #"{"kind":"feedback","crashedAt":"2026-11-13T05:05:01.000Z","text":"x"}"#
        let decoded = try RDJSON.decoder().decode(CrashReport.self, from: Data(old.utf8))
        #expect(decoded.message == nil)
        #expect((try JSONSerialization.jsonObject(with: RDJSON.encoder().encode(decoded)) as? [String: Any])?["message"] == nil)
    }

    @Test func attachmentsRoundTripAsNameTypeBase64() throws {
        let report = CrashReport.feedback(message: "느려요", bundleId: "com.example.app", appVersion: "1.0",
                                          attachments: [.init(name: "photo-1.jpg", type: "image/jpeg", data: Data("jpeg".utf8)),
                                                        .init(name: "log.txt", data: Data("log".utf8))],
                                          date: Date(timeIntervalSince1970: 1_794_478_500))
        #expect(report.text.contains("첨부: photo-1.jpg, log.txt"))
        let data = try RDJSON.encoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try #require((object["attachments"] as? [[String: String]])?.first)
        #expect(first == ["name": "photo-1.jpg", "type": "image/jpeg", "base64": "anBlZw=="])
        #expect(object["image"] == nil)
        let decoded = try RDJSON.decoder().decode(CrashReport.self, from: data)
        #expect(decoded.attachments == report.attachments)
        #expect(decoded.attachments.last?.type == "application/octet-stream")
    }

    @Test func badBase64IsRejected() {
        let json = #"{"kind":"feedback","crashedAt":"2026-11-13T05:05:01.000Z","text":"x","attachments":[{"name":"a","base64":"not base64!"}]}"#
        #expect(throws: (any Error).self) { try RDJSON.decoder().decode(CrashReport.self, from: Data(json.utf8)) }
    }

    @Test func limitsRefuseInsteadOfTruncating() {
        typealias Attachment = CrashReport.Attachment
        let small = Attachment(name: "a", data: Data(count: 10))
        #expect(CrashReport.attachmentRefusal(adding: 10, to: []) == nil)
        #expect(CrashReport.attachmentRefusal(adding: CrashReport.maxAttachmentBytes, to: []) == nil)
        #expect(CrashReport.attachmentRefusal(adding: CrashReport.maxAttachmentBytes + 1, to: []) == .tooLarge)
        #expect(CrashReport.attachmentRefusal(adding: 10, to: Array(repeating: small, count: CrashReport.maxAttachments)) == .tooMany)
        let big = Attachment(name: "b", data: Data(count: CrashReport.maxAttachmentBytes))
        #expect(CrashReport.attachmentRefusal(adding: CrashReport.maxAttachmentTotalBytes - CrashReport.maxAttachmentBytes, to: [big]) == nil)
        #expect(CrashReport.attachmentRefusal(adding: CrashReport.maxAttachmentBytes, to: [big]) == .totalTooLarge)
        // 사진 다섯 장은 언제나 합계 한도에 들어가고, 합계는 base64로 코어의 본문 한도(4MiB)에서 글 한도를 뺀 것보다 작다.
        #expect(CrashReport.maxAttachedImageBytes * CrashReport.maxAttachments <= CrashReport.maxAttachmentTotalBytes)
        #expect(CrashReport.maxAttachmentTotalBytes * 4 / 3 + CrashReport.maxTextBytes < 4 << 20)
    }

    @Test func fileNamesLoseDirectoriesAndControlCharacters() {
        let safe = CrashReport.Attachment.safeName
        #expect(safe("../../etc/passwd") == "passwd")
        #expect(safe("..\\..\\boot.ini") == "boot.ini")
        #expect(safe("/Users/someone/Library/a b.txt") == "a b.txt")
        #expect(safe("...hidden") == "hidden")
        #expect(safe("..") == "attachment")
        #expect(safe("") == "attachment")
        #expect(safe("a\u{0}b\nc\u{202E}d:e.txt") == "abcde.txt")
        let long = safe(String(repeating: "한", count: 200) + ".jpeg")
        #expect(long.utf8.count <= 100 && long.hasSuffix(".jpeg"))
        #expect(!safe("x/" + String(repeating: "a", count: 300)).contains("/"))
    }
}
