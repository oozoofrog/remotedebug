import Foundation
import Testing

@testable import SwiftailHostServer

@Suite("Range 계산")
struct ByteRangeTests {
    @Test func noRangeOrIgnoredRange() {
        #expect(ByteRange.decide(header: nil, length: 10) == .full)
        #expect(ByteRange.decide(header: "bytes=0-1", hasIfRange: true, length: 10) == .full)
        #expect(ByteRange.decide(header: "bytes=0-1,4-5", length: 10) == .full)  // 여러 구간
        for malformed in ["bytes=", "bytes=-", "bytes=a-b", "bytes 0-1", "items=0-1", "bytes=5-2", "bytes=1-2-3", "bytes=+1-2"] {
            #expect(ByteRange.decide(header: malformed, length: 10) == .full, "\(malformed)")
        }
    }

    @Test func singleRanges() {
        #expect(ByteRange.decide(header: "bytes=0-0", length: 10) == .partial(start: 0, end: 0))
        #expect(ByteRange.decide(header: "BYTES=2-5", length: 10) == .partial(start: 2, end: 5))
        #expect(ByteRange.decide(header: "bytes=4-", length: 10) == .partial(start: 4, end: 9))
        // 끝이 길이를 넘으면 마지막 바이트로 줄인다.
        #expect(ByteRange.decide(header: "bytes=8-100", length: 10) == .partial(start: 8, end: 9))
        #expect(ByteRange.decide(header: "bytes= 3-4 ", length: 10) == .partial(start: 3, end: 4))
    }

    @Test func suffixRanges() {
        #expect(ByteRange.decide(header: "bytes=-3", length: 10) == .partial(start: 7, end: 9))
        #expect(ByteRange.decide(header: "bytes=-30", length: 10) == .partial(start: 0, end: 9))
        #expect(ByteRange.decide(header: "bytes=-0", length: 10) == .unsatisfiable)
        #expect(ByteRange.decide(header: "bytes=-5", length: 0) == .unsatisfiable)
    }

    @Test func unsatisfiable() {
        #expect(ByteRange.decide(header: "bytes=10-", length: 10) == .unsatisfiable)
        #expect(ByteRange.decide(header: "bytes=10-20", length: 10) == .unsatisfiable)
        #expect(ByteRange.decide(header: "bytes=0-", length: 0) == .unsatisfiable)
        #expect(ByteRange.unsatisfiedContentRange(length: 10) == "bytes */10")
    }

    @Test func overflowSaturates() {
        let huge = "99999999999999999999999"
        #expect(ByteRange.decide(header: "bytes=\(huge)-", length: 10) == .unsatisfiable)
        #expect(ByteRange.decide(header: "bytes=3-\(huge)", length: 10) == .partial(start: 3, end: 9))
        #expect(ByteRange.decide(header: "bytes=-\(huge)", length: 10) == .partial(start: 0, end: 9))
    }

    @Test func beyondFourGiB() {
        let length: UInt64 = 6 << 30
        let start: UInt64 = 5 << 30
        #expect(ByteRange.decide(header: "bytes=\(start)-", length: length) == .partial(start: start, end: length - 1))
        #expect(ByteRange.decide(header: "bytes=-\(1 << 30)", length: length) == .partial(start: start, end: length - 1))
        #expect(ByteRange.contentRange(start: start, end: length - 1, length: length) == "bytes 5368709120-6442450943/6442450944")
    }

    @Test func fileResponseHeaders() {
        let base = [ResponseHeader(name: "Content-Type", value: "application/octet-stream")]
        func request(_ range: String?) -> HTTPRequest {
            HTTPRequest(method: .get, path: "/file", headers: range.map { ["range": $0] } ?? [:])
        }
        let full = FileResponse.make(length: 100, request: request(nil), baseHeaders: base)
        #expect(full.status == 200 && full.offset == 0 && full.count == 100)
        #expect(full.headers.contains(ResponseHeader(name: "Accept-Ranges", value: "bytes")))

        let partial = FileResponse.make(length: 100, request: request("bytes=-10"), baseHeaders: base)
        #expect(partial.status == 206 && partial.offset == 90 && partial.count == 10)
        #expect(partial.headers.contains(ResponseHeader(name: "Content-Range", value: "bytes 90-99/100")))

        let none = FileResponse.make(length: 100, request: request("bytes=100-"), baseHeaders: base)
        #expect(none.status == 416 && none.count == 0)
        #expect(none.headers == [ResponseHeader(name: "Content-Range", value: "bytes */100")])
    }

    /// 6GiB짜리 성긴 파일(디스크를 거의 쓰지 않는다)에서 4GiB 너머를 읽는다.
    @Test func sparseFileBeyondFourGiB() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftail-host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "sparse.bin")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        let marker: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let length: UInt64 = 6 << 30
        try handle.seek(toOffset: length - UInt64(marker.count))
        try handle.write(contentsOf: marker)
        try handle.close()

        let source = try FileSource(path: url.path)
        #expect(source.length == length)
        let response = FileResponse.make(length: source.length,
                                         request: HTTPRequest(method: .get, path: "/file", headers: ["range": "bytes=-4"]),
                                         baseHeaders: [])
        #expect(response.status == 206 && response.offset == length - 4 && response.count == 4)
        #expect(try source.read(at: response.offset, count: 4) == marker)
        #expect(try source.read(at: 5 << 30, count: 8) == [UInt8](repeating: 0, count: 8))
        // 끝을 넘는 읽기는 실패한다(파일이 줄어든 경우).
        #expect(throws: FileSource.Failure.self) { try source.read(at: length - 2, count: 4) }
    }

    @Test func fileSourceRejectsDirectoryAndMissing() {
        #expect(throws: FileSource.Failure.self) { try FileSource(path: FileManager.default.temporaryDirectory.path) }
        #expect(throws: FileSource.Failure.self) { try FileSource(path: "/nonexistent-\(UUID().uuidString)") }
    }
}
