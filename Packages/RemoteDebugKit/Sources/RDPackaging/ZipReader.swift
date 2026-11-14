#if os(macOS)
import Darwin
import Foundation

public struct ZipEntry: Sendable, Hashable {
    public var name: String
    public var method: UInt16
    public var crc32: UInt32
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var localHeaderOffset: UInt64
    public var externalAttributes: UInt32
    public var madeByUnix: Bool
    public var modified: Date

    /// 상위 16비트의 Unix `st_mode`(만든 쪽이 Unix일 때만).
    public var unixMode: UInt16? { madeByUnix ? UInt16(truncatingIfNeeded: externalAttributes >> 16) : nil }
    public var isSymlink: Bool { (unixMode ?? 0) & 0o170000 == 0o120000 }
    public var isDirectory: Bool {
        name.hasSuffix("/") || ((unixMode ?? 0) & 0o170000 == 0o040000) || (externalAttributes & 0x10) != 0
    }
    /// 권한 비트(12비트). 없으면 nil.
    public var permissions: UInt16? { unixMode.map { $0 & 0o7777 } }
}

/// `extractAll`의 한도. 압축 폭탄·겹친 항목으로 디스크를 채우는 것을 막는다.
public struct ZipLimits: Sendable, Hashable {
    /// 풀린 총 크기 한도(포함되는 항목의 선언된 크기 합).
    public var maxTotalSize: UInt64
    /// 풀어 낼 항목 수 한도.
    public var maxEntryCount: Int
    /// 풀린 총 크기 ÷ 아카이브 파일 크기의 상한. nil이면 보지 않는다.
    /// 작은 아카이브가 걸리지 않도록 `ratioFloor`까지는 비율과 관계없이 허용한다.
    public var maxCompressionRatio: UInt64?
    public var ratioFloor: UInt64

    public init(maxTotalSize: UInt64, maxEntryCount: Int = ZipWriter.maxEntryCount, maxCompressionRatio: UInt64? = nil, ratioFloor: UInt64 = 64 << 20) {
        self.maxTotalSize = maxTotalSize
        self.maxEntryCount = maxEntryCount
        self.maxCompressionRatio = maxCompressionRatio
        self.ratioFloor = ratioFloor
    }

    /// 일반 기본값: 16 GiB, 형식 최대 항목 수, 비율 검사 없음(겹친 항목은 언제나 거부).
    public static let `default` = ZipLimits(maxTotalSize: 16 << 30)

    /// IPA 검사용: 4 GiB, 항목 50,000개, 압축률 100:1(64 MiB까지는 비율 무관).
    public static let ipaInspection = ZipLimits(maxTotalSize: 4 << 30, maxEntryCount: 50_000, maxCompressionRatio: 100)
}

/// ZIP 중앙 디렉터리 읽기. stored(0)와 deflate(8)만 지원하고 ZIP64·암호화는 `ZipError.unsupported`.
/// 열 때 모든 로컬 헤더를 확인한다: 서명, 이름이 중앙 디렉터리와 같은지, 데이터 범위가 파일·중앙 디렉터리 안에 있는지,
/// 항목끼리 범위가 겹치지 않는지(같은 압축 데이터를 여러 이름으로 가리키는 압축 폭탄 방지).
public final class ZipReader {
    public let entries: [ZipEntry]
    private let url: URL
    private let fileSize: UInt64

    public init(url: URL) throws {
        self.url = url
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ZipError.io("\(url.lastPathComponent): \(error)") }
        defer { try? handle.close() }
        do {
            fileSize = try handle.seekToEnd()
            guard fileSize >= 22 else { throw ZipError.notAZip }

            // EOCD 찾기: 끝에서 최대 22 + 65535 바이트.
            let tailLen = min(fileSize, 22 + 65535)
            try handle.seek(toOffset: fileSize - tailLen)
            let tail = try handle.read(upToCount: Int(tailLen)) ?? Data()
            guard let eocdIndex = Self.findEOCD(in: tail) else { throw ZipError.notAZip }
            let e = tail.subdata(in: eocdIndex..<tail.endIndex)
            let total = Int(e.u16(10))
            let cdSize = UInt64(e.u32(12))
            let cdOffset = UInt64(e.u32(16))
            if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
            guard cdOffset + cdSize <= fileSize else { throw ZipError.corrupt(String(localized: "중앙 디렉터리 범위 오류")) }

            try handle.seek(toOffset: cdOffset)
            let cd = try handle.read(upToCount: Int(cdSize)) ?? Data()
            guard cd.count == Int(cdSize) else { throw ZipError.corrupt(String(localized: "중앙 디렉터리가 잘렸습니다")) }

            var list: [ZipEntry] = []
            var nameBytes: [Data] = []
            var p = 0
            for _ in 0..<total {
                guard p + 46 <= cd.count, cd.u32(p) == 0x0201_4B50 else { throw ZipError.corrupt(String(localized: "중앙 디렉터리 항목 서명 오류")) }
                let madeBy = cd.u16(p + 4)
                let flags = cd.u16(p + 8)
                let method = cd.u16(p + 10)
                let dosTime = cd.u16(p + 12)
                let dosDate = cd.u16(p + 14)
                let crc = cd.u32(p + 16)
                let csize = cd.u32(p + 20)
                let usize = cd.u32(p + 24)
                let nlen = Int(cd.u16(p + 28)), xlen = Int(cd.u16(p + 30)), clen = Int(cd.u16(p + 32))
                let ext = cd.u32(p + 38)
                let off = cd.u32(p + 42)
                guard p + 46 + nlen + xlen + clen <= cd.count else { throw ZipError.corrupt(String(localized: "항목이 잘렸습니다")) }
                if flags & 0x1 != 0 { throw ZipError.unsupported(String(localized: "암호화")) }
                if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || off == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }
                let rawName = cd.subdata(in: (p + 46)..<(p + 46 + nlen))
                guard let name = String(data: rawName, encoding: .utf8) else {
                    throw ZipError.invalidName(String(localized: "UTF-8이 아닌 이름"))
                }
                list.append(ZipEntry(
                    name: name, method: method, crc32: crc,
                    compressedSize: UInt64(csize), uncompressedSize: UInt64(usize),
                    localHeaderOffset: UInt64(off), externalAttributes: ext,
                    madeByUnix: (madeBy >> 8) == 3, modified: Self.date(dosDate: dosDate, dosTime: dosTime)
                ))
                nameBytes.append(rawName)
                p += 46 + nlen + xlen + clen
            }

            // 로컬 헤더와 데이터 범위 확인.
            var ranges: [(start: UInt64, end: UInt64, name: String)] = []
            ranges.reserveCapacity(list.count)
            for (i, entry) in list.enumerated() {
                guard entry.localHeaderOffset + 30 <= cdOffset else { throw ZipError.corrupt(String(localized: "로컬 헤더 범위 오류: \(entry.name)")) }
                try handle.seek(toOffset: entry.localHeaderOffset)
                guard let header = try handle.read(upToCount: 30), header.count == 30, header.u32(0) == 0x0403_4B50 else {
                    throw ZipError.corrupt(String(localized: "로컬 헤더 오류: \(entry.name)"))
                }
                let lnlen = UInt64(header.u16(26)), lxlen = UInt64(header.u16(28))
                let dataStart = entry.localHeaderOffset + 30 + lnlen + lxlen
                let end = dataStart + entry.compressedSize
                guard end <= cdOffset, end <= fileSize else { throw ZipError.corrupt(String(localized: "데이터 범위 오류: \(entry.name)")) }
                let localName = try handle.read(upToCount: Int(lnlen)) ?? Data()
                guard localName == nameBytes[i] else { throw ZipError.corrupt(String(localized: "로컬 헤더 이름이 중앙 디렉터리와 다릅니다: \(entry.name)")) }
                ranges.append((entry.localHeaderOffset, end, entry.name))
            }
            ranges.sort { $0.start < $1.start }
            for i in ranges.indices.dropFirst() where ranges[i].start < ranges[i - 1].end {
                throw ZipError.corrupt(String(localized: "항목 데이터가 겹칩니다: \(ranges[i].name)"))
            }
            entries = list
        } catch let e as ZipError { throw e } catch { throw ZipError.io("\(error)") }
    }

    /// 아카이브 파일 크기(바이트).
    public var archiveSize: UInt64 { fileSize }

    private static func findEOCD(in tail: Data) -> Int? {
        guard tail.count >= 22 else { return nil }
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == 0x0605_4B50 {
                let commentLen = Int(tail.u16(i + 20))
                if i + 22 + commentLen <= tail.count { return tail.startIndex + i }
            }
            i -= 1
        }
        return nil
    }

    private static func date(dosDate: UInt16, dosTime: UInt16) -> Date {
        var c = DateComponents()
        c.year = 1980 + Int(dosDate >> 9)
        c.month = max(1, Int((dosDate >> 5) & 0xF))
        c.day = max(1, Int(dosDate & 0x1F))
        c.hour = Int(dosTime >> 11)
        c.minute = Int((dosTime >> 5) & 0x3F)
        c.second = Int(dosTime & 0x1F) * 2
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: 데이터 읽기

    /// 항목 데이터를 메모리로 푼다(심볼릭 링크 대상·작은 파일용).
    public func data(for entry: ZipEntry, limit: UInt64 = 64 << 20) throws -> Data {
        guard entry.uncompressedSize <= limit else { throw ZipError.sizeLimitExceeded }
        var out = Data()
        try stream(entry) { out.append(contentsOf: $0) }
        return out
    }

    /// 항목 데이터를 풀면서 `sink`로 넘기고 CRC·크기를 검증한다.
    public func stream(_ entry: ZipEntry, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupported(String(localized: "압축 방식 \(String(entry.method))")) }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw ZipError.io("\(error)") }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: entry.localHeaderOffset)
            guard let header = try handle.read(upToCount: 30), header.count == 30, header.u32(0) == 0x0403_4B50 else {
                throw ZipError.corrupt(String(localized: "로컬 헤더 오류: \(entry.name)"))
            }
            let dataStart = entry.localHeaderOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
            guard dataStart + entry.compressedSize <= fileSize else { throw ZipError.corrupt(String(localized: "데이터 범위 오류: \(entry.name)")) }
            try handle.seek(toOffset: dataStart)

            var crc = CRC32()
            var produced: UInt64 = 0
            func emit(_ buf: UnsafeRawBufferPointer) throws {
                produced += UInt64(buf.count)
                if produced > entry.uncompressedSize { throw ZipError.sizeLimitExceeded }
                crc.update(buf)
                try sink(buf)
            }

            var remaining = entry.compressedSize
            if entry.method == 0 {
                guard entry.compressedSize == entry.uncompressedSize else { throw ZipError.corrupt(String(localized: "stored 크기 불일치: \(entry.name)")) }
                while remaining > 0 {
                    guard let chunk = try handle.read(upToCount: Int(min(UInt64(ZipWriter.chunkSize), remaining))), !chunk.isEmpty else {
                        throw ZipError.corrupt(String(localized: "데이터가 잘렸습니다: \(entry.name)"))
                    }
                    remaining -= UInt64(chunk.count)
                    try chunk.withUnsafeBytes { try emit($0) }
                }
            } else {
                let inflater = try RawDeflateStream(.decode)
                if remaining == 0 { throw ZipError.corrupt(String(localized: "빈 DEFLATE 데이터: \(entry.name)")) }
                while remaining > 0 {
                    guard let chunk = try handle.read(upToCount: Int(min(UInt64(ZipWriter.chunkSize), remaining))), !chunk.isEmpty else {
                        throw ZipError.corrupt(String(localized: "데이터가 잘렸습니다: \(entry.name)"))
                    }
                    remaining -= UInt64(chunk.count)
                    try chunk.withUnsafeBytes { buf in
                        try inflater.process(buf, finalize: remaining == 0, sink: emit)
                    }
                }
                if !inflater.isFinished { throw ZipError.corrupt(String(localized: "DEFLATE가 끝나지 않았습니다: \(entry.name)")) }
            }
            guard produced == entry.uncompressedSize else { throw ZipError.corrupt(String(localized: "크기 불일치: \(entry.name)")) }
            guard crc.value == entry.crc32 else { throw ZipError.crcMismatch(entry.name) }
        } catch let e as ZipError { throw e } catch let e as CancellationError { throw e } catch { throw ZipError.io("\(error)") }
    }

    // MARK: 추출

    /// 이전 API: `limits`의 `maxTotalSize`만 바꿔 `extractAll(to:limits:control:include:)`를 부른다.
    public func extractAll(to directory: URL, maxTotalSize: UInt64, include: (ZipEntry) -> Bool = { _ in true }) throws {
        var limits = ZipLimits.default
        limits.maxTotalSize = maxTotalSize
        try extractAll(to: directory, limits: limits, include: include)
    }

    /// `directory` 아래로 풀어 낸다. 다음은 아무것도 쓰기 전에 거부한다.
    /// - 이름에 `..`·절대 경로·NUL·백슬래시가 있음(`unsafePath`)
    /// - 다른 심볼릭 링크 항목 아래에 놓이는 항목(링크를 거쳐 쓰기, `unsafePath`)
    /// - 절대 경로이거나 글자 그대로 풀어도 `directory` 밖으로 나가는 심볼릭 링크 대상(`unsafePath`)
    /// - 한도 초과: 항목 수(`tooManyEntries`), 총 크기·압축률(`sizeLimitExceeded`)
    ///
    /// 일반 파일과 폴더를 먼저 만들고 심볼릭 링크는 맨 끝에 만든다. 링크마다 대상을 **실제로 풀린 트리**에서
    /// 경로 요소 하나씩 lstat·readlink로 따라가 보고(앞서 만든 링크를 거치는 사슬 포함) 루트 밖으로 나가면 `unsafePath`.
    /// 중간 경로 요소는 모두 lstat으로 확인해 심볼릭 링크를 거쳐 쓰지 않는다. 파일은 O_EXCL|O_NOFOLLOW로 만든다.
    ///
    /// 권한: 파일은 아카이브 권한의 하위 9비트에 소유자 읽기·쓰기(0o600)를 더한다(setuid 등은 버림).
    /// 폴더 권한은 모든 항목을 쓴 뒤 깊은 곳부터 적용하되 소유자 rwx(0o700)는 언제나 남긴다(검사·정리가 가능하도록).
    /// 실패하면 이미 쓴 내용은 남는다. 호출자는 `ZipReader.removeTree(at:)`로 지운다.
    public func extractAll(
        to directory: URL,
        limits: ZipLimits = .default,
        control: OperationControl = .default,
        include: (ZipEntry) -> Bool = { _ in true }
    ) throws {
        // 1) 이름 검사(모든 항목).
        var parsed: [(ZipEntry, [String])] = []
        for entry in entries {
            parsed.append((entry, try Self.safeComponents(entry.name)))
        }
        let selected = parsed.filter { include($0.0) && !$0.1.isEmpty }

        // 2) 한도.
        if selected.count > limits.maxEntryCount { throw ZipError.tooManyEntries }
        var total: UInt64 = 0
        for (entry, _) in selected {
            total += entry.uncompressedSize
            if total > limits.maxTotalSize { throw ZipError.sizeLimitExceeded }
        }
        if let ratio = limits.maxCompressionRatio {
            let (scaled, overflow) = ratio.multipliedReportingOverflow(by: fileSize)
            if total > max(limits.ratioFloor, overflow ? .max : scaled) { throw ZipError.sizeLimitExceeded }
        }

        // 3) 구조 검사: 링크 아래에 놓이는 항목, 링크 대상(글자 그대로).
        let linkPaths = Set(selected.filter { $0.0.isSymlink }.map { $0.1.joined(separator: "/") })
        for (entry, comps) in selected where comps.count > 1 {
            for k in 1..<comps.count where linkPaths.contains(comps[0..<k].joined(separator: "/")) {
                throw ZipError.unsafePath(String(localized: "\(entry.name) (심볼릭 링크를 거치는 경로)"))
            }
        }
        var links: [(entry: ZipEntry, comps: [String], target: String)] = []
        for (entry, comps) in selected where entry.isSymlink {
            try control.check()
            let target = try data(for: entry, limit: 4096)
            guard let targetString = String(data: target, encoding: .utf8), !targetString.isEmpty, !targetString.contains("\0") else {
                throw ZipError.unsafePath(String(localized: "\(entry.name) → (잘못된 심볼릭 링크 대상)"))
            }
            try Self.validateSymlinkLexically(target: targetString, components: comps, entryName: entry.name)
            links.append((entry, comps, targetString))
        }

        // 4) 폴더와 일반 파일.
        let fm = FileManager.default
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) } catch { throw ZipError.io("\(error)") }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let meter = ProgressMeter(control, total: Int64(clamping: total))
        var directoryModes: [([String], UInt16)] = []
        for (entry, comps) in selected where !entry.isSymlink {
            try meter.check()
            if entry.isDirectory {
                try Self.ensureDirectory(root: root, components: comps)
                if let mode = entry.permissions { directoryModes.append((comps, mode)) }
                continue
            }
            try Self.ensureDirectory(root: root, components: Array(comps.dropLast()))
            let dest = Self.url(root, comps)
            try Self.prepareLeaf(dest, root: root)
            let fd = open(dest.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ZipError.io("\(entry.name): \(String(cString: strerror(errno)))") }
            let out = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            do {
                try stream(entry) { buf in
                    try out.write(contentsOf: Data(buf))
                    try meter.advance(buf.count)
                }
                let mode = mode_t(((entry.permissions ?? 0o644) & 0o777) | 0o600)
                if fchmod(fd, mode) != 0 { throw ZipError.io("\(entry.name): \(String(cString: strerror(errno)))") }
                close(fd)
            } catch {
                close(fd)
                unlink(dest.path)
                throw error
            }
        }

        // 5) 심볼릭 링크: 실제 트리에서 따라가 확인한 뒤 만든다. 아직 없는 링크를 거치는 대상은 다음 차례로 미룬다.
        var pending = links
        while !pending.isEmpty {
            var deferred: [(entry: ZipEntry, comps: [String], target: String)] = []
            for link in pending {
                try meter.check()
                let parent = Array(link.comps.dropLast())
                try Self.ensureDirectory(root: root, components: parent)
                switch try Self.resolveLink(root: root, parent: parent, target: link.target, entryName: link.entry.name) {
                case .dangling:
                    deferred.append(link)
                case .inside:
                    let dest = Self.url(root, link.comps)
                    try Self.prepareLeaf(dest, root: root)
                    if symlink(link.target, dest.path) != 0 {
                        throw ZipError.io("\(link.entry.name): \(String(cString: strerror(errno)))")
                    }
                }
            }
            if deferred.count == pending.count {
                throw ZipError.unsafePath(String(localized: "\(deferred[0].entry.name) → 존재하지 않는 경로를 거치는 링크"))
            }
            pending = deferred
        }

        // 6) 폴더 권한: 깊은 곳부터, 소유자 rwx 유지.
        for (comps, mode) in directoryModes.sorted(by: { $0.0.count > $1.0.count }) {
            let path = Self.url(root, comps).path
            guard Self.lstatMode(URL(fileURLWithPath: path)) == S_IFDIR else { continue }
            if chmod(path, mode_t((mode & 0o777) | 0o700)) != 0 {
                throw ZipError.io("\(comps.joined(separator: "/")): \(String(cString: strerror(errno)))")
            }
        }
    }

    /// 풀어 낸 폴더를 지운다. 읽기 전용 폴더도 지울 수 있도록 폴더마다 소유자 rwx를 먼저 준다. 심볼릭 링크는 따라가지 않는다.
    /// 없으면 아무것도 하지 않는다.
    public static func removeTree(at url: URL) throws {
        try removeRecursively(url.path)
    }

    private static func removeRecursively(_ path: String) throws {
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno == ENOENT { return }
            throw ZipError.io("\(path): \(String(cString: strerror(errno)))")
        }
        if st.st_mode & S_IFMT == S_IFDIR {
            if chmod(path, (st.st_mode & 0o7777) | 0o700) != 0 { throw ZipError.io("\(path): \(String(cString: strerror(errno)))") }
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: path) } catch { throw ZipError.io("\(error)") }
            for name in names { try removeRecursively(path + "/" + name) }
            if rmdir(path) != 0 { throw ZipError.io("\(path): \(String(cString: strerror(errno)))") }
        } else if unlink(path) != 0 {
            throw ZipError.io("\(path): \(String(cString: strerror(errno)))")
        }
    }

    /// 이름을 안전한 경로 요소로 바꾼다. `.`과 빈 요소는 버리고 `..`·절대 경로·NUL·백슬래시는 거부한다.
    public static func safeComponents(_ name: String) throws -> [String] {
        if name.isEmpty || name.hasPrefix("/") || name.contains("\0") || name.contains("\\") {
            throw ZipError.unsafePath(name)
        }
        var comps: [String] = []
        for part in name.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." { throw ZipError.unsafePath(name) }
            if part == "." { continue }
            comps.append(String(part))
        }
        return comps
    }

    private static func url(_ root: URL, _ comps: [String]) -> URL {
        comps.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// 쓰기 전 빠른 검사: 링크가 놓인 폴더 기준으로 글자 그대로 풀어 루트 밖으로 나가는지 본다.
    /// 앞선 링크를 거치는 사슬은 `resolveLink`가 실제 트리에서 다시 확인한다.
    private static func validateSymlinkLexically(target: String, components: [String], entryName: String) throws {
        if target.hasPrefix("/") { throw ZipError.unsafePath(String(localized: "\(entryName) → 절대 경로 링크")) }
        var depth = components.count - 1
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." {
                depth -= 1
                if depth < 0 { throw ZipError.unsafePath(String(localized: "\(entryName) → 루트 밖을 가리키는 링크")) }
            } else if part != "." {
                depth += 1
            }
        }
    }

    private enum LinkResolution {
        /// 루트 안에서 끝난다(마지막 요소는 없어도 된다).
        case inside
        /// 중간 요소가 아직 없다(나중에 만들 링크일 수 있음).
        case dangling
    }

    /// 링크 대상을 커널처럼 한 요소씩 따라간다. 이미 있는 링크는 readlink로 펼친다. 루트 밖으로 나가면 `unsafePath`.
    private static func resolveLink(root: URL, parent: [String], target: String, entryName: String) throws -> LinkResolution {
        func parts(_ s: String) -> [String] {
            s.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        }
        if target.hasPrefix("/") { throw ZipError.unsafePath(String(localized: "\(entryName) → 절대 경로 링크")) }
        var stack = parent
        var pending = Array(parts(target).reversed())
        var hops = 0
        while let part = pending.popLast() {
            if part == ".." {
                guard !stack.isEmpty else { throw ZipError.unsafePath(String(localized: "\(entryName) → 루트 밖을 가리키는 링크")) }
                stack.removeLast()
                continue
            }
            stack.append(part)
            let path = url(root, stack)
            switch lstatMode(path) {
            case S_IFDIR?:
                continue
            case S_IFLNK?:
                hops += 1
                guard hops <= 40 else { throw ZipError.unsafePath(String(localized: "\(entryName) → 링크가 너무 깊거나 순환합니다")) }
                let dest: String
                do { dest = try FileManager.default.destinationOfSymbolicLink(atPath: path.path) } catch { throw ZipError.io("\(error)") }
                if dest.hasPrefix("/") { throw ZipError.unsafePath(String(localized: "\(entryName) → 절대 경로 링크를 거칩니다")) }
                stack.removeLast()
                pending.append(contentsOf: parts(dest).reversed())
            case nil:
                return pending.isEmpty ? .inside : .dangling
            default:
                if pending.isEmpty { return .inside }
                throw ZipError.unsafePath(String(localized: "\(entryName) → 파일을 폴더처럼 거치는 링크"))
            }
        }
        return .inside
    }

    private static func lstatMode(_ url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    /// `root` 아래 `components` 디렉터리를 만든다. 중간에 심볼릭 링크나 일반 파일이 있으면 거부한다.
    private static func ensureDirectory(root: URL, components: [String]) throws {
        var current = root
        for part in components {
            current = current.appendingPathComponent(part)
            switch lstatMode(current) {
            case nil:
                if mkdir(current.path, 0o755) != 0 && errno != EEXIST {
                    throw ZipError.io("\(current.lastPathComponent): \(String(cString: strerror(errno)))")
                }
                guard lstatMode(current) == S_IFDIR else { throw ZipError.unsafePath(relative(current, root)) }
            case S_IFDIR:
                continue
            default:
                throw ZipError.unsafePath(relative(current, root))
            }
        }
    }

    /// 쓸 자리를 비운다. 없으면 그대로, 일반 파일(같은 이름의 앞선 항목)은 지운다. 폴더·링크 등은 건드리지 않고 거부한다.
    private static func prepareLeaf(_ url: URL, root: URL) throws {
        switch lstatMode(url) {
        case nil: return
        case S_IFREG?:
            if unlink(url.path) != 0 { throw ZipError.io("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        default:
            throw ZipError.unsafePath(relative(url, root))
        }
    }

    private static func relative(_ url: URL, _ root: URL) -> String {
        let p = url.path, r = root.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : url.lastPathComponent
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8) | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
}
#endif
