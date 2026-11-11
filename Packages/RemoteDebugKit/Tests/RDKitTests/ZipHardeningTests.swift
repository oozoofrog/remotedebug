import Darwin
import Foundation
import Testing

@testable import RDBuildInspection
@testable import RDPackaging

/// 던진 오류를 ZipError로 돌려준다(던지지 않으면 nil).
func zipError(_ body: () throws -> Void) -> ZipError? {
    do { try body() } catch let e as ZipError { return e } catch { Issue.record("ZipError가 아닌 오류: \(error)") }
    return nil
}

extension ZipError {
    var isUnsafePath: Bool { if case .unsafePath = self { true } else { false } }
    var isCorrupt: Bool { if case .corrupt = self { true } else { false } }
}

private func craft(_ tmp: TempDir, _ build: (ZipWriter) throws -> Void) throws -> URL {
    let url = tmp.path("craft-\(UUID().uuidString).zip")
    let w = try ZipWriter(url: url)
    try build(w)
    try w.finish()
    return url
}

/// `root` 아래 모든 항목의 실제 경로가 `root` 안에 있는지(심볼릭 링크를 끝까지 따라감).
private func everythingResolvesInside(_ root: URL) -> Bool {
    let realRoot = root.resolvingSymlinksInPath().path
    let e = FileManager.default.enumerator(atPath: root.path)
    while let rel = e?.nextObject() as? String {
        guard let raw = realpath(root.appendingPathComponent(rel).path, nil) else { continue }  // 끊긴 링크는 밖을 가리키지 않는다
        let resolved = String(validatingCString: raw) ?? ""
        free(raw)
        if resolved != realRoot && !resolved.hasPrefix(realRoot + "/") { return false }
    }
    return true
}

@Suite struct ZipHardeningTests {
    // MARK: ZIP-2 / T1: 심볼릭 링크 사슬

    @Test func chainedSymlinkThroughDotIsRejected() throws {
        let tmp = try TempDir("chain-dot")
        try Data("secret".utf8).write(to: tmp.path("outside-marker"))
        // s -> "." 다음 l -> "s/../outside-marker": 글자로는 루트 안이지만 실제로는 루트의 부모를 가리킨다.
        let zip = try craft(tmp) { w in
            try w.addSymlink(name: "s", destination: ".", modified: Date())
            try w.addSymlink(name: "l", destination: "s/../outside-marker", modified: Date())
        }
        let dest = tmp.path("dest")
        let err = zipError { try ZipReader(url: zip).extractAll(to: dest) }
        #expect(err == .unsafePath("l → 루트 밖을 가리키는 링크"))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("l").path))
        #expect(everythingResolvesInside(dest))
    }

    @Test func chainedSymlinkInReverseOrderIsRejected() throws {
        let tmp = try TempDir("chain-rev")
        let zip = try craft(tmp) { w in
            try w.addSymlink(name: "l", destination: "s/../outside-marker", modified: Date())
            try w.addSymlink(name: "s", destination: ".", modified: Date())
        }
        let dest = tmp.path("dest")
        let err = zipError { try ZipReader(url: zip).extractAll(to: dest) }
        #expect(err?.isUnsafePath == true, "\(String(describing: err))")
        #expect(everythingResolvesInside(dest))
    }

    @Test func parentLinkChainIsRejected() throws {
        // 리뷰 재현: d/up -> "..", d/esc -> "up/../secret.txt"
        let tmp = try TempDir("chain-up")
        try Data("secret".utf8).write(to: tmp.path("secret.txt"))
        let zip = try craft(tmp) { w in
            try w.addDirectory(name: "d/", modified: Date())
            try w.addSymlink(name: "d/up", destination: "..", modified: Date())
            try w.addSymlink(name: "d/esc", destination: "up/../secret.txt", modified: Date())
        }
        let dest = tmp.path("dest")
        let err = zipError { try ZipReader(url: zip).extractAll(to: dest) }
        #expect(err == .unsafePath("d/esc → 루트 밖을 가리키는 링크"))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("d/esc").path))
        #expect(everythingResolvesInside(dest))
    }

    @Test func deepSelfLinkChainIsRejected() throws {
        // IPA 모양: Payload/A.app/s -> "." 과 Info.plist -> "s/s/s/../../../../../x"
        let tmp = try TempDir("chain-deep")
        let zip = try craft(tmp) { w in
            try w.addDirectory(name: "Payload/A.app/", modified: Date())
            try w.addSymlink(name: "Payload/A.app/s", destination: ".", modified: Date())
            try w.addSymlink(name: "Payload/A.app/Info.plist", destination: "s/s/s/../../../../../x", modified: Date())
        }
        let dest = tmp.path("dest")
        let err = zipError { try ZipReader(url: zip).extractAll(to: dest) }
        #expect(err?.isUnsafePath == true)
        #expect(everythingResolvesInside(dest))
    }

    @Test func writingThroughAnEarlierSymlinkIsRejectedBeforeWriting() throws {
        let tmp = try TempDir("through")
        let zip = try craft(tmp) { w in
            try w.addData(Data("first".utf8), name: "first.txt", modified: Date())
            try w.addSymlink(name: "via", destination: ".", modified: Date())
            try w.addData(Data("x".utf8), name: "via/sub/file", modified: Date())
        }
        let dest = tmp.path("dest")
        let err = zipError { try ZipReader(url: zip).extractAll(to: dest) }
        #expect(err == .unsafePath("via/sub/file (심볼릭 링크를 거치는 경로)"))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("first.txt").path), "검사 전에 쓰기가 시작됨")
    }

    @Test func preexistingSymlinkInDestinationIsNotFollowed() throws {
        let tmp = try TempDir("preexisting")
        let outside = tmp.path("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let dest = tmp.path("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dest.appendingPathComponent("a").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: dest.appendingPathComponent("leaf").path, withDestinationPath: outside.appendingPathComponent("leaf").path)
        let zip = try craft(tmp) { w in try w.addData(Data("x".utf8), name: "a/file", modified: Date()) }
        #expect(zipError { try ZipReader(url: zip).extractAll(to: dest) } == .unsafePath("a"))
        let zip2 = try craft(tmp) { w in try w.addData(Data("x".utf8), name: "leaf", modified: Date()) }
        #expect(zipError { try ZipReader(url: zip2).extractAll(to: dest) } == .unsafePath("leaf"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func frameworkStyleLinksInsideTheRootAreAllowed() throws {
        // macOS 프레임워크 모양: 앞선 링크가 나중 링크(Current)를 거친다. 정상 구조는 통과해야 한다.
        let tmp = try TempDir("framework")
        let zip = try craft(tmp) { w in
            try w.addDirectory(name: "F.framework/", modified: Date())
            try w.addSymlink(name: "F.framework/F", destination: "Versions/Current/F", modified: Date())
            try w.addSymlink(name: "F.framework/Resources", destination: "Versions/Current/Resources", modified: Date())
            try w.addDirectory(name: "F.framework/Versions/A/Resources/", modified: Date())
            try w.addData(Data("bin".utf8), name: "F.framework/Versions/A/F", modified: Date())
            try w.addData(Data("r".utf8), name: "F.framework/Versions/A/Resources/Info.plist", modified: Date())
            try w.addSymlink(name: "F.framework/Versions/Current", destination: "A", modified: Date())
            try w.addSymlink(name: "dangling", destination: "not-there", modified: Date())
        }
        let dest = tmp.path("dest")
        try ZipReader(url: zip).extractAll(to: dest)
        #expect(try String(contentsOf: dest.appendingPathComponent("F.framework/F"), encoding: .utf8) == "bin")
        #expect(try String(contentsOf: dest.appendingPathComponent("F.framework/Resources/Info.plist"), encoding: .utf8) == "r")
        #expect(everythingResolvesInside(dest))
    }

    // MARK: ZIP-3 / API-2: 읽기 전용 폴더

    @Test func readOnlyDirectoryModesKeepOwnerAccessAndCleanUp() throws {
        let tmp = try TempDir("ro-dirs")
        let zip = try craft(tmp) { w in
            try w.addDirectory(name: "Payload/", mode: 0o555, modified: Date())
            try w.addDirectory(name: "Payload/A.app/", mode: 0o500, modified: Date())
            try w.addData(Data("x".utf8), name: "Payload/A.app/file", mode: 0o000, modified: Date())
        }
        let dest = tmp.path("dest")
        try ZipReader(url: zip).extractAll(to: dest)
        let mode = { (p: String) in ((try? FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(p).path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
        #expect(mode("Payload") == 0o755 && mode("Payload/A.app") == 0o700)
        #expect(mode("Payload/A.app/file") == 0o600)

        // 정리: 소유자 권한이 없는 폴더도 지운다.
        let hard = tmp.path("hard/inner")
        try FileManager.default.createDirectory(at: hard, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: hard.appendingPathComponent("f"))
        chmod(hard.path, 0o000)
        chmod(tmp.path("hard").path, 0o500)
        try ZipReader.removeTree(at: tmp.path("hard"))
        #expect(!FileManager.default.fileExists(atPath: tmp.path("hard").path))
        try ZipReader.removeTree(at: tmp.path("missing"))  // 없으면 아무것도 안 함
    }

    @Test func ipaWithReadOnlyDirectoriesLeavesNothingBehind() throws {
        let tmp = try TempDir("ro-ipa")
        let ipa = tmp.path("ro.ipa")
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.ro", "DTPlatformName": "iphoneos"], format: .xml, options: 0)
        let w = try ZipWriter(url: ipa)
        try w.addDirectory(name: "Payload/", mode: 0o555, modified: Date())
        try w.addDirectory(name: "Payload/A.app/", mode: 0o500, modified: Date())
        try w.addData(info, name: "Payload/A.app/Info.plist", mode: 0o444, modified: Date())
        try w.finish()
        let work = tmp.path("w")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // 서명이 없어 거부되거나(정책) 읽을 수 없다는 오류가 날 수 있다. 어느 쪽이든 풀어 낸 폴더는 남지 않는다.
        _ = try? BuildInspector.inspect(ipaAt: ipa, options: .init(), workDirectory: work)
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty, "풀어 낸 폴더가 남았습니다")
    }

    // MARK: ZIP-4: 한도와 겹친 항목

    /// 중앙 디렉터리 항목 하나를 복제해 같은 로컬 레코드를 두 번 가리키게 만든다.
    private func duplicateCentralEntry(_ zip: URL, to out: URL) throws {
        var b = try Data(contentsOf: zip)
        let eocd = b.count - 22
        let count = Int(b.u16(eocd + 10)), cdSize = Int(b.u32(eocd + 12)), cdOffset = Int(b.u32(eocd + 16))
        #expect(count == 1)
        let record = b.subdata(in: cdOffset..<(cdOffset + cdSize))
        var tail = Data()
        tail.append(record); tail.append(record)
        var newEOCD = b.subdata(in: eocd..<b.count)
        newEOCD.replaceSubrange(8..<10, with: [2, 0]); newEOCD.replaceSubrange(10..<12, with: [2, 0])
        let size = UInt32(cdSize * 2)
        newEOCD.replaceSubrange(12..<16, with: withUnsafeBytes(of: size.littleEndian) { Array($0) })
        b = b.subdata(in: 0..<cdOffset) + tail + newEOCD
        try b.write(to: out)
    }

    @Test func overlappingEntriesAreRejected() throws {
        let tmp = try TempDir("overlap")
        let src = tmp.path("zeros")
        try Data(count: 1 << 20).write(to: src)
        let zip = try craft(tmp) { w in try w.addFile(at: src, name: "z", mode: 0o644, modified: Date()) }
        let bomb = tmp.path("bomb.zip")
        try duplicateCentralEntry(zip, to: bomb)
        #expect(zipError { _ = try ZipReader(url: bomb) } == .corrupt("항목 데이터가 겹칩니다: z"))
    }

    @Test func compressionRatioAndEntryCountLimits() throws {
        let tmp = try TempDir("limits")
        let src = tmp.path("zeros")
        try Data(count: 2 << 20).write(to: src)
        let zip = try craft(tmp) { w in
            try w.addFile(at: src, name: "z", mode: 0o644, modified: Date())
            try w.addData(Data("a".utf8), name: "a", modified: Date())
            try w.addData(Data("b".utf8), name: "b", modified: Date())
        }
        let r = try ZipReader(url: zip)
        #expect(r.archiveSize < 64 << 10)  // 2 MiB의 0은 수 KiB로 줄어든다
        let ratio = ZipLimits(maxTotalSize: .max, maxCompressionRatio: 50, ratioFloor: 0)
        #expect(zipError { try r.extractAll(to: tmp.path("d1"), limits: ratio) } == .sizeLimitExceeded)
        #expect(!FileManager.default.fileExists(atPath: tmp.path("d1/z").path), "한도 검사 전에 쓰기가 시작됨")
        // 바닥값 아래면 비율과 관계없이 허용한다.
        try r.extractAll(to: tmp.path("d2"), limits: ZipLimits(maxTotalSize: .max, maxCompressionRatio: 50, ratioFloor: 4 << 20))
        #expect(zipError { try r.extractAll(to: tmp.path("d3"), limits: ZipLimits(maxTotalSize: .max, maxEntryCount: 2)) } == .tooManyEntries)
        #expect(zipError { try r.extractAll(to: tmp.path("d4"), maxTotalSize: 1 << 20) } == .sizeLimitExceeded)

        #expect(ZipLimits.ipaInspection.maxTotalSize == 4 << 30)
        #expect(ZipLimits.ipaInspection.maxCompressionRatio != nil)
        #expect(ZipLimits.ipaInspection.maxEntryCount <= ZipWriter.maxEntryCount)
    }

    // MARK: ZIP-5: 항목 수

    @Test func entryCountStopsBeforeZip64Marker() throws {
        let tmp = try TempDir("count")
        let url = tmp.path("many.zip")
        let w = try ZipWriter(url: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<ZipWriter.maxEntryCount {
            try w.addData(Data(), name: "f\(i)", modified: date)
        }
        #expect(ZipWriter.maxEntryCount == 65_534)
        #expect(throws: ZipError.tooManyEntries) { try w.addData(Data(), name: "one-too-many", modified: date) }
        try w.finish()
        let r = try ZipReader(url: url)
        #expect(r.entries.count == 65_534)
    }

    // MARK: ZIP-6: stored 다시 쓰기 중 파일 변경

    @Test func fileChangingBetweenPassesFailsInsteadOfWritingBadCRC() throws {
        let tmp = try TempDir("crc-race")
        let src = tmp.path("noise.bin")
        var g = SystemRandomNumberGenerator()
        let size = 200_000
        try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &g) }).write(to: src)
        let w = try ZipWriter(url: tmp.path("o.zip"))
        // 첫 읽기(압축 시도)가 끝나면 같은 크기의 다른 내용으로 바꾼다 → stored로 다시 읽을 때 CRC가 달라진다.
        let err = zipError {
            try w.addFile(at: src, name: "noise.bin", mode: 0o644, modified: Date(), onChunk: { _ in
                try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &g) }).write(to: src)
            })
        }
        #expect(err == .io("noise.bin: 읽는 동안 파일 내용이 바뀌었습니다"))
    }

    // MARK: T9: 잘린 아카이브, 범위 오류

    private func sampleZip(_ tmp: TempDir) throws -> Data {
        let url = try craft(tmp) { w in
            try w.addData(Data(repeating: 0x61, count: 300), name: "first", modified: Date(timeIntervalSince1970: 1_700_000_000))
            try w.addData(Data(repeating: 0x62, count: 300), name: "second", modified: Date(timeIntervalSince1970: 1_700_000_000))
        }
        return try Data(contentsOf: url)
    }

    private func open(_ tmp: TempDir, _ bytes: Data) throws -> ZipError? {
        let url = tmp.path("mut-\(UUID().uuidString).zip")
        try bytes.write(to: url)
        return zipError { _ = try ZipReader(url: url) }
    }

    @Test func truncatedArchivesAreRejected() throws {
        let tmp = try TempDir("trunc")
        let good = try sampleZip(tmp)
        #expect(try open(tmp, good) == nil)
        let eocd = good.count - 22
        let cdOffset = Int(good.u32(eocd + 16))
        // EOCD가 잘림, 중앙 디렉터리 중간에서 잘림, 데이터 중간에서 잘림: EOCD를 찾을 수 없다.
        for cut in [good.count - 1, good.count - 10, cdOffset + 5, 100, 22] {
            #expect(try open(tmp, good.prefix(cut)) == .notAZip, "cut=\(cut)")
        }
        // 데이터 중간을 잘라 내고 EOCD의 중앙 디렉터리 오프셋을 맞춰 다시 만든 경우.
        var shrunk = good
        shrunk.removeSubrange(60..<160)
        let e2 = shrunk.count - 22
        let newOffset = UInt32(cdOffset - 100)
        shrunk.replaceSubrange((e2 + 16)..<(e2 + 20), with: withUnsafeBytes(of: newOffset.littleEndian) { Array($0) })
        let err = try open(tmp, shrunk)
        #expect(err?.isCorrupt == true, "\(String(describing: err))")
    }

    @Test func outOfRangeOffsetsAreRejected() throws {
        let tmp = try TempDir("range")
        let good = try sampleZip(tmp)
        let eocd = good.count - 22
        let cdOffset = Int(good.u32(eocd + 16))

        // 중앙 디렉터리 오프셋이 파일 끝 너머.
        var a = good
        a.replaceSubrange((eocd + 16)..<(eocd + 20), with: withUnsafeBytes(of: UInt32(good.count + 1000).littleEndian) { Array($0) })
        #expect(try open(tmp, a) == .corrupt("중앙 디렉터리 범위 오류"))

        // 첫 항목의 로컬 헤더 오프셋이 파일 끝 너머.
        var b = good
        b.replaceSubrange((cdOffset + 42)..<(cdOffset + 46), with: withUnsafeBytes(of: UInt32(good.count + 10).littleEndian) { Array($0) })
        #expect(try open(tmp, b) == .corrupt("로컬 헤더 범위 오류: first"))

        // 첫 항목의 압축 크기가 커서 데이터가 중앙 디렉터리·파일 끝을 넘는다.
        var c = good
        c.replaceSubrange((cdOffset + 20)..<(cdOffset + 24), with: withUnsafeBytes(of: UInt32(1 << 20).littleEndian) { Array($0) })
        #expect(try open(tmp, c) == .corrupt("데이터 범위 오류: first"))

        // 로컬 헤더 이름이 중앙 디렉터리와 다르다.
        var d = good
        d[30] = UInt8(ascii: "F")
        #expect(try open(tmp, d) == .corrupt("로컬 헤더 이름이 중앙 디렉터리와 다릅니다: first"))

        // 로컬 헤더 서명이 깨짐.
        var f = good
        f[0] = 0
        #expect(try open(tmp, f) == .corrupt("로컬 헤더 오류: first"))
    }

    // MARK: ZIP-1: 출력 위치

    @Test func packagingRefusesNonRegularDestinationAndLeavesItUntouched() throws {
        let tmp = try TempDir("dest")
        let dir = tmp.path("out")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: dir.appendingPathComponent("keep.txt"))
        let err = zipError { _ = try IPABuilder.package(appAt: Fixtures.app("loose/DebugDylib.app"), to: dir) }
        #expect(err == .invalidDestination("out"))
        #expect(try String(contentsOf: dir.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["out"], "임시 파일이 남았습니다")

        // 심볼릭 링크도 거부하고, 링크가 가리키는 파일도 건드리지 않는다.
        let target = tmp.path("target.txt")
        try Data("target".utf8).write(to: target)
        let link = tmp.path("link.ipa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(zipError { _ = try IPABuilder.package(appAt: Fixtures.app("loose/DebugDylib.app"), to: link) } == .invalidDestination("link.ipa"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "target")
    }

    @Test func packagingReplacesExistingRegularFile() throws {
        let tmp = try TempDir("replace")
        let ipa = tmp.path("app.ipa")
        try Data("old contents".utf8).write(to: ipa)
        let r = try IPABuilder.package(appAt: Fixtures.app("loose/DebugDylib.app"), to: ipa)
        let attrs = try FileManager.default.attributesOfItem(atPath: ipa.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
        #expect((attrs[.size] as? NSNumber)?.int64Value == r.size)
        #expect(try ZipReader(url: ipa).entries.first?.name == "Payload/")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["app.ipa"])
    }
}
