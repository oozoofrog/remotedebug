import CoreGraphics
import Foundation
import ImageIO
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

    @Test func receiveTimeComesFromTheCoreWhenGiven() {
        let store = CrashLogStore(directory: nil, now: { Date(timeIntervalSince1970: 2_000) })
        var given = event(ips)
        given.receivedAt = Date(timeIntervalSince1970: 1_000)
        store.receive(given)
        store.receive(event("다른 기록", name: "Other.ips"))
        #expect(store.items.first { $0.name == "Sample.ips" }?.receivedAt == Date(timeIntervalSince1970: 1_000))
        #expect(store.items.first { $0.name == "Other.ips" }?.receivedAt == Date(timeIntervalSince1970: 2_000))
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

    private func feedback(_ n: Int, attachments: [CrashReport.Attachment]) -> DeviceCrashEvent {
        DeviceCrashEvent(deviceId: "d_a", deviceName: "폰", nodeName: "rd-phone-1",
                         report: CrashReport(kind: .feedback, name: "f\(n).txt", bundleId: "com.example.app", appVersion: "1",
                                             crashedAt: Date(timeIntervalSince1970: Double(n)), text: "feedback \(n)", attachments: attachments))
    }

    /// 첨부는 기록 옆에 고친 이름으로 저장되고, 목록 글에 경로가 나온다.
    @Test func attachmentsAreStoredBesideTheReportWithSafeNames() throws {
        let dir = try TempDir("crashes-attached")
        let store = CrashLogStore(directory: dir.url)
        store.receive(feedback(1, attachments: [.init(name: "../../../escape.sh", type: "text/x-shellscript", data: Data("#!/bin/sh".utf8)),
                                                .init(name: "photo-1.jpg", type: "image/jpeg", data: Data("jpeg".utf8))]))
        let item = try #require(store.items.first)
        let attached = try #require(item.attachments)
        #expect(attached.map(\.name) == ["escape.sh", "photo-1.jpg"])
        #expect(attached.map(\.file) == ["\(item.id)-1-escape.sh", "\(item.id)-2-photo-1.jpg"])
        #expect(attached.map(\.bytes) == [9, 4])
        let urls = attached.compactMap(store.attachmentURL)
        #expect(urls.count == 2)
        for url in urls {
            #expect(url.deletingLastPathComponent().standardizedFileURL == dir.url.standardizedFileURL)
            let permissions = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
            #expect(permissions & 0o111 == 0, "실행 권한이 없다")
        }
        #expect(try Data(contentsOf: urls[1]) == Data("jpeg".utf8))

        let list = CrashLogStore.listText(directory: dir.url, kind: "feedback")
        #expect(list.contains("\n    첨부: \(urls[0].path) (9바이트)"))
        #expect(list.contains("\n    첨부: \(urls[1].path) (4바이트)"))
        // 다시 읽어도 첨부가 남아 있다.
        #expect(CrashLogStore(directory: dir.url).items.first?.attachments == attached)
    }

    /// 지우거나 보관 한도로 밀려난 기록은 첨부 파일도 함께 지운다.
    @Test func retentionAndRemovalDeleteAttachmentFiles() throws {
        let dir = try TempDir("crashes-attached-retention")
        let clock = TickingClock()
        let store = CrashLogStore(directory: dir.url, now: { clock.tick() })
        store.receive(feedback(0, attachments: [.init(name: "old.txt", data: Data("old".utf8))]))
        let old = try #require(store.items.first?.attachments?.first.flatMap(store.attachmentURL))
        #expect(FileManager.default.fileExists(atPath: old.path))
        for n in 1...CrashLogStore.perDeviceLimit { store.receive(feedback(n, attachments: [.init(name: "a.txt", data: Data("a".utf8))])) }
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(store.items.count == CrashLogStore.perDeviceLimit)

        for item in store.items { store.remove(item.id) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == ["index.json"])
    }

    /// 확인 목록의 답은 원문 끝에 글로 붙어, 화면과 에이전트가 같은 글에서 읽는다.
    @Test func checkAnswersAreAppendedToTheStoredText() throws {
        let dir = try TempDir("crashes-checks")
        let store = CrashLogStore(directory: dir.url)
        var event = feedback(1, attachments: [])
        event.report.checks = [.init(id: "pay.sheet", title: "결제 화면이 열린다", answer: "안 보임", note: "빈 화면", build: "59", answeredAt: "2026-11-13T05:05:01.000Z"),
                               .init(id: "launch", title: "앱이 켜진다")]
        store.receive(event)
        let item = try #require(store.items.first)
        #expect(item.id == event.report.id && item.checks == event.report.checks)
        let text = try #require(CrashLogStore.reportText(directory: dir.url, id: item.id))
        #expect(text.hasPrefix("feedback 1\n---\n확인 목록의 답 (1/2개 답함)"))
        #expect(text.contains("- [안 보임] pay.sheet: 결제 화면이 열린다 (빌드 59, 2026-11-13T05:05:01.000Z)\n  메모: 빈 화면"))
        #expect(text.contains("- [답 없음] launch: 앱이 켜진다"))
        #expect(store.text(item) == text)
        #expect(CrashLogStore.listText(directory: dir.url).contains("\n    확인 목록의 답: 1/2개 답함"))
        #expect(CrashLogStore(directory: dir.url).items.first?.checks == event.report.checks)

        let memory = CrashLogStore(directory: nil)
        memory.receive(event)
        #expect(memory.text(try #require(memory.items.first))?.contains("확인 목록의 답") == true)
    }

    /// 옛 기록(첨부 없음, 사진 한 장)은 그대로 읽히고 목록 글의 `사진:`도 남는다. 폴더 밖을 가리키는 저장 이름은 쓰지 않는다.
    @Test func oldRecordsAndUnsafeStoredNames() throws {
        let dir = try TempDir("crashes-old")
        let store = CrashLogStore(directory: dir.url)
        store.receive(DeviceCrashEvent(deviceId: "d_a", deviceName: "폰", nodeName: "rd-phone-1",
                                       report: CrashReport(kind: .feedback, name: "f.txt", bundleId: "com.example.app", appVersion: "1",
                                                           crashedAt: Date(timeIntervalSince1970: 1), text: "옛 피드백", image: Data([0x89, 0x50]))))
        let item = try #require(store.items.first)
        #expect(item.attachments == nil && item.imageFile == "\(item.id).png")
        let list = CrashLogStore.listText(directory: dir.url)
        #expect(list.contains("  사진: ") && !list.contains("첨부: /"))
        // 첨부 필드가 없던 때의 index.json도 읽힌다.
        let index = dir.url.appendingPathComponent("index.json")
        var objects = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        #expect(objects[0]["attachments"] == nil)
        objects[0]["attachments"] = [["name": "x", "file": "../outside.txt", "bytes": 1], ["name": "y", "file": ".hidden", "bytes": 1]]
        try JSONSerialization.data(withJSONObject: objects).write(to: index)
        let reloaded = CrashLogStore(directory: dir.url)
        #expect(reloaded.items.first?.attachments?.count == 2)
        #expect(reloaded.items.first?.attachments?.compactMap(reloaded.attachmentURL).isEmpty == true)
        #expect(!CrashLogStore.listText(directory: dir.url).contains("첨부: /"))
    }

    /// 글이 같아도 첨부가 다르거나 다른 기기가 보낸 기록은 버리지 않는다. 같은 기기가 같은 것을 다시 보낸 것만 하나로 남는다.
    @Test func sameTextWithOtherAttachmentsOrFromAnotherDeviceIsKept() throws {
        let dir = try TempDir("crashes-dedupe")
        let store = CrashLogStore(directory: dir.url)
        func feedback(_ device: String, _ attachment: String?) -> DeviceCrashEvent {
            var report = CrashReport(kind: .feedback, name: "feedback.txt", bundleId: "com.example.sample", appVersion: "1.2 (7)",
                                     crashedAt: Date(timeIntervalSince1970: 1_794_478_500), text: "같은 글\n\n---\n앱: com.example.sample 1.2 (7)\n")
            if let attachment { report.attachments = [.init(name: "a.txt", type: "text/plain", data: Data(attachment.utf8))] }
            return DeviceCrashEvent(deviceId: device, deviceName: "폰", nodeName: "", report: report)
        }
        // 첨부가 없는 기록의 id는 글만으로 정하던 예전 값 그대로다(이미 저장한 기록과 이어진다).
        #expect(feedback("d_1", nil).report.id == "c_4d74866afce4")
        #expect(feedback("d_1", "하나").report.id != feedback("d_1", nil).report.id)
        #expect(feedback("d_1", "하나").report.id != feedback("d_1", "둘").report.id)

        for event in [feedback("d_1", nil), feedback("d_1", "하나"), feedback("d_1", "둘"), feedback("d_2", nil), feedback("d_2", "하나")] {
            store.receive(event)
        }
        #expect(store.items.count == 5 && Set(store.items.map(\.id)).count == 5)
        #expect(store.items.filter { $0.deviceId == "d_2" }.count == 2)
        // 다시 보낸 것은 어느 기기 것이든 더해지지 않는다.
        for event in [feedback("d_1", nil), feedback("d_1", "둘"), feedback("d_2", nil), feedback("d_2", "하나")] { store.receive(event) }
        #expect(store.items.count == 5)
        // 첨부 파일은 기록마다 따로 남는다.
        let files = Set(store.items.flatMap { $0.attachments ?? [] }.map(\.file))
        #expect(files.count == 3)
        for attached in store.items.flatMap({ $0.attachments ?? [] }) {
            #expect(FileManager.default.fileExists(atPath: try #require(store.attachmentURL(attached)).path))
        }
        #expect(CrashLogStore(directory: dir.url).items.count == 5)
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

/// 기기가 보낸 사진은 앞머리가 JPEG나 PNG일 때만, 줄인 그림으로 푼다.
@Suite struct ReceivedPictureTests {
    private func encoded(_ type: String, width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func jpegAndPNGAreDecodedAsBoundedThumbnails() throws {
        let png = try encoded("public.png", width: 400, height: 200), jpeg = try encoded("public.jpeg", width: 300, height: 600)
        #expect(ReceivedPicture.format(of: png) == .png && ReceivedPicture.format(of: jpeg) == .jpeg)
        let small = try #require(ReceivedPicture.thumbnail(of: png))
        #expect(small.image.width == 400 && small.image.height == 200)
        // 긴 변을 한도 아래로 줄인다(원본을 통째로 그리지 않는다).
        let bounded = try #require(ReceivedPicture.thumbnail(of: jpeg, maxPixelSize: 100))
        #expect(max(bounded.image.width, bounded.image.height) == 100 && bounded.image.width == 50)
        #expect(ReceivedPicture.maxPixelSize == 1600)

        let dir = try TempDir("picture")
        let file = dir.path("c_000000000000-1-photo.jpg")
        try jpeg.write(to: file)
        #expect(ReceivedPicture.thumbnail(at: file) != nil)
        #expect(ReceivedPicture.thumbnail(at: dir.path("nosuch.jpg")) == nil)
        #expect(ReceivedPicture.thumbnail(at: dir.url) == nil, "폴더는 풀지 않는다")
    }

    /// 확장자가 사진이어도 앞머리가 JPEG·PNG가 아니면 디코더에 넘기지 않는다.
    @Test func otherFormatsAndBrokenFilesAreNotDecoded() throws {
        let tiff = try encoded("public.tiff", width: 10, height: 10), gif = try encoded("com.compuserve.gif", width: 10, height: 10)
        #expect(ReceivedPicture.format(of: tiff) == nil && ReceivedPicture.thumbnail(of: tiff) == nil)
        #expect(ReceivedPicture.format(of: gif) == nil && ReceivedPicture.thumbnail(of: gif) == nil)
        for text in ["%PDF-1.7\n", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>", "<html>", "", "BM"] {
            #expect(ReceivedPicture.thumbnail(of: Data(text.utf8)) == nil, "\(text)")
        }
        // 앞머리만 사진인 파일: 형식은 맞아 보이지만 풀리지 않는다.
        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("not a picture".utf8)
        let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0]) + tiff
        #expect(ReceivedPicture.format(of: fakePNG) == .png && ReceivedPicture.thumbnail(of: fakePNG) == nil)
        #expect(ReceivedPicture.format(of: fakeJPEG) == .jpeg && ReceivedPicture.thumbnail(of: fakeJPEG) == nil)
        // 너무 큰 파일은 읽지 않는다.
        let dir = try TempDir("picture-large")
        let large = dir.path("large.png")
        try (try encoded("public.png", width: 8, height: 8) + Data(count: ReceivedPicture.maxFileBytes)).write(to: large)
        #expect(ReceivedPicture.thumbnail(at: large) == nil)
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
