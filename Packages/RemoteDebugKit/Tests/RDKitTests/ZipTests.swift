import Foundation
import Testing

@testable import RDPackaging

@Suite struct ZipTests {
    private func randomData(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    private func compressible(_ n: Int) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: ($0 / 7) % 13) })
    }

    @Test func roundTripWithPermissionsSymlinksAndMethods() throws {
        let tmp = try TempDir("zip")
        let src = tmp.path("src")
        let fm = FileManager.default
        try fm.createDirectory(at: src.appendingPathComponent("dir/sub"), withIntermediateDirectories: true)
        let small = Data("hello zip\n".utf8)
        let big = compressible(3 * 1024 * 1024 + 17)  // 여러 청크
        let noise = randomData(2 * 1024 * 1024 + 5)  // 압축 안 됨 → stored
        try small.write(to: src.appendingPathComponent("small.txt"))
        try big.write(to: src.appendingPathComponent("dir/big.bin"))
        try noise.write(to: src.appendingPathComponent("dir/sub/noise.bin"))
        try Data().write(to: src.appendingPathComponent("empty"))
        try Data("#!/bin/sh\n".utf8).write(to: src.appendingPathComponent("run.sh"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("run.sh").path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: src.appendingPathComponent("small.txt").path)
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "dir/big.bin")

        let zipURL = tmp.path("out.zip")
        let w = try ZipWriter(url: zipURL)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try w.addDirectory(name: "dir/", modified: date)
        try w.addDirectory(name: "dir/sub/", modified: date)
        for (name, mode) in [("small.txt", UInt16(0o600)), ("dir/big.bin", 0o644), ("dir/sub/noise.bin", 0o644), ("empty", 0o644), ("run.sh", 0o755)] {
            try w.addFile(at: src.appendingPathComponent(name), name: name, mode: mode, modified: date)
        }
        try w.addSymlink(name: "link", destination: "dir/big.bin", modified: date)
        try w.finish()

        // 시스템 unzip이 무결성을 확인한다.
        let t = try runTool("/usr/bin/unzip", ["-t", zipURL.path])
        #expect(t.status == 0, "\(t.output)")

        let r = try ZipReader(url: zipURL)
        let byName = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.name, $0) })
        #expect(byName["dir/big.bin"]?.method == 8)
        #expect((byName["dir/big.bin"]?.compressedSize ?? .max) < (byName["dir/big.bin"]?.uncompressedSize ?? 0))
        #expect(byName["dir/sub/noise.bin"]?.method == 0)  // 압축 이득이 없으면 stored
        #expect(byName["empty"]?.method == 0 && byName["empty"]?.uncompressedSize == 0)
        #expect(byName["link"]?.isSymlink == true)
        #expect(byName["dir/"]?.isDirectory == true)
        #expect(byName["run.sh"]?.permissions == 0o755)
        #expect(byName["small.txt"]?.permissions == 0o600)

        let dest = tmp.path("dest")
        try r.extractAll(to: dest)
        #expect(try Data(contentsOf: dest.appendingPathComponent("small.txt")) == small)
        #expect(try Data(contentsOf: dest.appendingPathComponent("dir/big.bin")) == big)
        #expect(try Data(contentsOf: dest.appendingPathComponent("dir/sub/noise.bin")) == noise)
        #expect(try Data(contentsOf: dest.appendingPathComponent("empty")).isEmpty)
        let mode = { (p: String) -> Int in
            ((try? fm.attributesOfItem(atPath: dest.appendingPathComponent(p).path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
        }
        #expect(mode("run.sh") == 0o755)
        #expect(mode("small.txt") == 0o600)
        #expect(try fm.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("link").path) == "dir/big.bin")

        // ditto(시스템 도구)로도 풀린다.
        let d2 = tmp.path("dest2")
        let dit = try runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, d2.path])
        #expect(dit.status == 0, "\(dit.output)")
        #expect(try Data(contentsOf: d2.appendingPathComponent("dir/big.bin")) == big)
    }

    @Test func crcMatchesKnownVector() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func dosTimestampsAreUTCAndClamped() {
        let (t, d) = ZipWriter.dosDateTime(Date(timeIntervalSince1970: 1_794_387_600))  // 2026-11-11 09:00:00Z
        #expect(d == UInt16(((2026 - 1980) << 9) | (11 << 5) | 11))
        #expect(t == UInt16(9 << 11))
        let old = ZipWriter.dosDateTime(Date(timeIntervalSince1970: 0))
        #expect(old.date == UInt16((1 << 5) | 1) && old.time == 0)
    }

    @Test func entryOverFourGiBIsRejected() throws {
        let tmp = try TempDir("big")
        let sparse = tmp.path("sparse.bin")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let h = try FileHandle(forWritingTo: sparse)
        try h.truncate(atOffset: 4 * 1024 * 1024 * 1024)
        try h.close()
        let w = try ZipWriter(url: tmp.path("o.zip"))
        #expect(throws: ZipError.entryTooLarge("huge")) {
            try w.addFile(at: sparse, name: "huge", mode: 0o644, modified: Date())
        }
    }

    // MARK: 경로 안전

    private func craft(_ tmp: TempDir, _ build: (ZipWriter) throws -> Void) throws -> URL {
        let url = tmp.path("evil-\(UUID().uuidString).zip")
        let w = try ZipWriter(url: url)
        try build(w)
        try w.finish()
        return url
    }

    @Test(arguments: ["../evil.txt", "a/../../evil.txt", "/abs/evil.txt", "a/..", "ok/../../x", "back\\slash"])
    func traversalNamesAreRejectedBeforeAnythingIsWritten(_ name: String) throws {
        let tmp = try TempDir("evil")
        let zip = try craft(tmp) { w in
            try w.addData(Data("fine".utf8), name: "first.txt", modified: Date())
            try w.addData(Data("evil".utf8), name: name, modified: Date())
        }
        let dest = tmp.path("dest/inner")
        let r = try ZipReader(url: zip)
        #expect(throws: ZipError.unsafePath(name)) { try r.extractAll(to: dest) }
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("first.txt").path), "검사 전에 쓰기가 시작됨")
        #expect(!FileManager.default.fileExists(atPath: tmp.path("dest/evil.txt").path))
        #expect(!FileManager.default.fileExists(atPath: tmp.path("evil.txt").path))
    }

    @Test func symlinkEscapesAreRejected() throws {
        let tmp = try TempDir("evil-link")
        for (target, label) in [("/etc", "absolute"), ("../../outside", "escape"), ("a/../../../outside", "escape2")] {
            let zip = try craft(tmp) { w in
                try w.addDirectory(name: "a/", modified: Date())
                try w.addSymlink(name: "a/l", destination: target, modified: Date())
            }
            let dest = tmp.path("dest-\(label)")
            #expect(throws: ZipError.self) { try ZipReader(url: zip).extractAll(to: dest) }
        }
        // 안쪽을 가리키는 상대 링크는 허용.
        let ok = try craft(tmp) { w in
            try w.addDirectory(name: "a/", modified: Date())
            try w.addData(Data("x".utf8), name: "a/file", modified: Date())
            try w.addSymlink(name: "a/l", destination: "file", modified: Date())
            try w.addSymlink(name: "up", destination: "a/file", modified: Date())
        }
        try ZipReader(url: ok).extractAll(to: tmp.path("dest-ok"))
    }

    @Test func writingThroughASymlinkIsRejected() throws {
        let tmp = try TempDir("evil-through")
        let zip = try craft(tmp) { w in
            try w.addDirectory(name: "real/", modified: Date())
            try w.addSymlink(name: "via", destination: "real", modified: Date())
            try w.addData(Data("x".utf8), name: "via/file", modified: Date())
        }
        let dest = tmp.path("dest")
        #expect(throws: ZipError.self) { try ZipReader(url: zip).extractAll(to: dest) }
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("real/file").path))
    }

    @Test func corruptDataIsDetected() throws {
        let tmp = try TempDir("corrupt")
        let zip = try craft(tmp) { w in try w.addData(Data("payload-payload-payload".utf8), name: "f", modified: Date()) }
        var bytes = try Data(contentsOf: zip)
        // 로컬 헤더(30) + 이름(1) 뒤 첫 데이터 바이트를 뒤집는다.
        bytes[31] ^= 0xFF
        let bad = tmp.path("bad.zip")
        try bytes.write(to: bad)
        let r = try ZipReader(url: bad)
        #expect(throws: ZipError.crcMismatch("f")) { try r.extractAll(to: tmp.path("d")) }
        let junk = tmp.path("junk.zip")
        try Data(repeating: 0x41, count: 100).write(to: junk)
        #expect(throws: ZipError.notAZip) { try ZipReader(url: junk) }
    }
}
