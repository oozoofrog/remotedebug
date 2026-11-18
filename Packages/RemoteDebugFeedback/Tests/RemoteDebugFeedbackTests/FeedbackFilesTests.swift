import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RemoteDebugFeedback

/// 피드백에 붙는 사진과 파일: 한도, 사진 줄이기, 보내는 모양, 쌓아 두는 기록의 크기 한도.
struct FeedbackFilesTests {
    private let info = FeedbackAppInfo(name: "Sample", version: "1.2", build: "3", system: "Test OS", device: "Device")

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rdfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 잘 줄지 않는 무늬의 PNG.
    private func noisyPNG(side: Int) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        var seed: UInt64 = 0x1234_5678
        for index in pixels.indices where index % 4 != 3 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let context = try #require(CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func limitsRefuseInsteadOfTruncating() {
        var files = FeedbackFiles()
        #expect(throws: FeedbackFiles.Refusal.unreadable) { try files.add(FeedbackFile(name: "empty", data: Data())) }
        #expect(throws: FeedbackFiles.Refusal.tooLarge) {
            try files.add(FeedbackFile(name: "big.bin", data: Data(count: FeedbackFiles.maxBytes + 1)))
        }
        #expect(throws: Never.self) { try files.add(FeedbackFile(name: "a.bin", data: Data(count: FeedbackFiles.maxBytes))) }
        #expect(throws: FeedbackFiles.Refusal.totalTooLarge) {
            try files.add(FeedbackFile(name: "b.bin", data: Data(count: FeedbackFiles.maxBytes)))
        }
        #expect(files.items.map(\.name) == ["a.bin"] && files.totalBytes == FeedbackFiles.maxBytes)
        for index in 1..<FeedbackFiles.maxCount {
            #expect(throws: Never.self) { try files.add(FeedbackFile(name: "s\(index)", data: Data(count: 10))) }
        }
        #expect(files.isFull)
        #expect(throws: FeedbackFiles.Refusal.tooMany) { try files.add(FeedbackFile(name: "extra", data: Data(count: 1))) }
        files.remove(files.items[0].id)
        #expect(files.items.count == FeedbackFiles.maxCount - 1 && !files.isFull)
        // 한도끼리 맞는다: 사진 다섯 장은 합계 안에, 합계(base64)와 글은 본문 한도 안에 들어간다.
        #expect(FeedbackFiles.maxImageBytes * FeedbackFiles.maxCount <= FeedbackFiles.maxTotalBytes)
        #if DEBUG
        #expect(FeedbackFiles.maxTotalBytes * 4 / 3 + FeedbackClient.maxTextBytes < FeedbackClient.maxBodyBytes)
        #endif
    }

    @Test func imagesAreShrunkToTheImageLimit() throws {
        let png = try noisyPNG(side: 2000)
        #expect(png.count > FeedbackFiles.maxBytes)
        var files = FeedbackFiles()
        try files.addImage(png)
        try files.addImage(png)
        #expect(files.items.map(\.name) == ["photo-1.jpg", "photo-2.jpg"])
        let jpeg = try #require(files.items.first)
        #expect(jpeg.type == "image/jpeg" && jpeg.isImage && jpeg.data.count <= FeedbackFiles.maxImageBytes)
        let source = try #require(CGImageSourceCreateWithData(jpeg.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(decoded.width, decoded.height) <= 1600)
        #expect(throws: FeedbackFiles.Refusal.unreadable) { try files.addImage(Data("not an image".utf8)) }
    }

    @Test func pickedFilesAreReadWithoutLeavingCopies() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: note)
        let big = folder.appendingPathComponent("big.zip")
        try Data(count: FeedbackFiles.maxBytes + 1).write(to: big)
        let picture = folder.appendingPathComponent("shot.png")
        try noisyPNG(side: 1800).write(to: picture)

        var files = FeedbackFiles()
        try files.addFile(at: note)
        #expect(throws: FeedbackFiles.Refusal.tooLarge) { try files.addFile(at: big) }
        #expect(throws: FeedbackFiles.Refusal.unreadable) { try files.addFile(at: folder.appendingPathComponent("missing.txt")) }
        try files.addFile(at: picture)
        #expect(files.items.map(\.name) == ["note.txt", "shot.jpg"])
        #expect(files.items.map(\.type) == ["text/plain", "image/jpeg"])
        #expect(files.items[0].data == Data("hello".utf8))
        #expect(files.items[1].data.count <= FeedbackFiles.maxImageBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["big.zip", "note.txt", "shot.png"])
    }

    // Mac으로 보내는 기록의 모양과 쌓아 두는 기록. 개발 빌드에만 있다.
    #if DEBUG
    @Test func reportCarriesAttachmentsAndStaysCompatibleWithoutThem() throws {
        let date = Date(timeIntervalSince1970: 1_794_478_500)
        let plain = RemoteDebugFeedback.report(message: "느려요", details: "", date: date)
        let plainObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(Set(plainObject.keys) == ["kind", "name", "bundleId", "appVersion", "crashedAt", "text"])

        let files = [FeedbackFile(name: "photo-1.jpg", type: "image/jpeg", data: Data("jpeg".utf8)),
                     FeedbackFile(name: "note.txt", type: "text/plain", data: Data("note".utf8))]
        let report = RemoteDebugFeedback.report(message: "느려요", details: "", attachments: files, date: date)
        #expect(report.text.contains("첨부: photo-1.jpg, note.txt"))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["image"] == nil)
        #expect(object["attachments"] as? [[String: String]] == [
            ["name": "photo-1.jpg", "type": "image/jpeg", "base64": "anBlZw=="],
            ["name": "note.txt", "type": "text/plain", "base64": "bm90ZQ=="],
        ])
        // 옛 패키지가 쌓아 둔 기록(첨부 필드 없음)도 읽힌다.
        let old = #"{"kind":"feedback","name":"f.txt","bundleId":"","appVersion":"","crashedAt":"2026-11-13T05:05:01.000Z","text":"x","image":"aGVsbG8="}"#
        #expect(try JSONDecoder().decode(FeedbackReport.self, from: Data(old.utf8)).attachments == nil)
    }

    @Test func longDetailsAreCutToTheTextLimitKeepingTheEnd() {
        let details = String(repeating: "한", count: FeedbackClient.maxTextBytes) + "끝줄"
        let report = RemoteDebugFeedback.report(message: "느려요", details: details, date: Date())
        #expect(report.text.utf8.count <= FeedbackClient.maxTextBytes)
        #expect(report.text.hasPrefix("느려요\n") && report.text.hasSuffix("끝줄\n"))
        #expect(!report.text.contains("\u{FFFD}"))
    }

    @Test func pendingQueueIsCappedByBytesDroppingOldestFirst() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let offline = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: folder) { _ in throw URLError(.cannotFindHost) }
        var files = FeedbackFiles()
        try files.add(FeedbackFile(name: "a.bin", data: Data(count: FeedbackFiles.maxBytes)))
        try files.add(FeedbackFile(name: "b.bin", data: Data(count: FeedbackFiles.maxTotalBytes - FeedbackFiles.maxBytes)))
        var last = ""
        for index in 0..<12 {
            let report = RemoteDebugFeedback.report(message: "큰 기록 \(index)", details: "", attachments: files.items, date: Date())
            last = report.text
            #expect(await offline.submit(report) == false)
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let pending = await offline.pending()
        let sizes = pending.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        #expect(sizes.reduce(0, +) <= FeedbackClient.queueByteLimit)
        #expect(pending.count < 12 && pending.count >= 2)
        #expect(sizes.allSatisfy { $0 <= FeedbackClient.maxBodyBytes })
        let newest = try JSONDecoder().decode(FeedbackReport.self, from: Data(contentsOf: try #require(pending.last)))
        let oldest = try JSONDecoder().decode(FeedbackReport.self, from: Data(contentsOf: try #require(pending.first)))
        #expect(newest.text == last)
        #expect(!oldest.text.hasPrefix("큰 기록 0\n"))
    }

    @Test func oversizedBodyIsNeitherSentNorQueued() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = FeedbackClient(endpoint: URL(string: "https://mac.example/v1/crashes")!, directory: folder) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!)
        }
        var report = RemoteDebugFeedback.report(message: "x", details: "", date: Date())
        report.attachments = [.init(name: "huge.bin", type: "application/octet-stream",
                                    base64: String(repeating: "A", count: FeedbackClient.maxBodyBytes))]
        #expect(await client.trySend(report) == false)
        #expect(await client.submit(report) == false)
        #expect(await client.pending().isEmpty)
    }

    #endif

    @Test @MainActor func mailCarriesPickedFilesAndMailtoSaysItCannot() async throws {
        let files = [FeedbackFile(name: "photo-1.jpg", type: "image/jpeg", data: Data("jpeg".utf8))]
        let session = FeedbackSession(recipient: "dev@example.com", appInfo: info)
        session.files = files
        #expect(await session.prepare(canSendMail: true) == nil)
        #expect(session.composing?.files == files)
        #expect(session.composing?.attachment == nil)
        session.finish(.cancelled)

        let url = try #require(await session.prepare(canSendMail: false))
        #expect(!url.absoluteString.contains("photo-1"))
        session.openedMailLink(accepted: true)
        #expect(session.status == session.labels.separateFiles)

        session.files = []
        #expect(await session.prepare(canSendMail: false) != nil)
        session.openedMailLink(accepted: true)
        #expect(session.status == nil)
    }
}
