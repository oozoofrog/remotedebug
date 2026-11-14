#if os(macOS)
import Foundation

/// 스트리밍 ZIP 작성기. 항목 데이터를 1 MiB 단위로 읽어 CRC32를 계산하고 raw DEFLATE로 압축한다.
/// 압축 결과가 원본보다 작지 않으면 자동으로 stored로 다시 쓴다. ZIP64는 지원하지 않으며
/// 항목 하나라도 4 GiB 이상이면 `ZipError.entryTooLarge`를 던진다.
/// 항목 순서는 호출 순서 그대로다(결정적 순서는 호출자가 보장한다).
public final class ZipWriter {
    public static let chunkSize = 1 << 20

    private struct Record {
        var nameBytes: [UInt8]
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
        var externalAttributes: UInt32
        var localHeaderOffset: UInt32
    }

    private let handle: FileHandle
    private var records: [Record] = []
    private var position: UInt64 = 0
    private var finished = false

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do { handle = try FileHandle(forWritingTo: url) } catch { throw ZipError.io("\(error)") }
    }

    deinit { if !finished { try? handle.close() } }

    // MARK: 공개 API

    public func addDirectory(name: String, mode: UInt16 = 0o755, modified: Date) throws {
        let name = name.hasSuffix("/") ? name : name + "/"
        try addStored(name: name, data: Data(), unixType: 0o040000, mode: mode, modified: modified, dosDirectory: true)
    }

    public func addSymlink(name: String, destination: String, modified: Date) throws {
        try addStored(name: name, data: Data(destination.utf8), unixType: 0o120000, mode: 0o755, modified: modified, dosDirectory: false)
    }

    /// 메모리 데이터를 항목으로 추가한다(작은 데이터용: 압축하지 않고 stored).
    public func addData(_ data: Data, name: String, mode: UInt16 = 0o644, modified: Date) throws {
        try addStored(name: name, data: data, unixType: 0o100000, mode: mode, modified: modified, dosDirectory: false)
    }

    public func addFile(at source: URL, name: String, mode: UInt16, modified: Date) throws {
        try addFile(at: source, name: name, mode: mode, modified: modified, onChunk: nil)
    }

    /// 항목 수 상한. EOCD의 항목 수 0xFFFF는 ZIP64 표시라서 그보다 하나 적게 받는다.
    public static let maxEntryCount = 0xFFFE

    /// `onChunk`는 원본 청크를 하나 읽을 때마다 그 바이트 수로 불린다(진행 보고·취소 확인용, 던지면 중단).
    /// 압축 이득이 없어 stored로 다시 쓸 때는 다시 읽은 바이트의 CRC가 첫 읽기와 같아야 한다(다르면 `ZipError.io`).
    func addFile(at source: URL, name: String, mode: UInt16, modified: Date, onChunk: ((Int) throws -> Void)?) throws {
        let nameBytes = try Self.validatedNameBytes(name)
        let reader: FileHandle
        do { reader = try FileHandle(forReadingFrom: source) } catch { throw ZipError.io("\(source.lastPathComponent): \(error)") }
        defer { try? reader.close() }

        let (dosTime, dosDate) = Self.dosDateTime(modified)
        let ext = (UInt32(0o100000 | (mode & 0o7777)) << 16)
        let headerOffset = try offset32()

        let expectedSize = try Self.fileSize(of: source)
        if expectedSize >= 0xFFFF_FFFF { throw ZipError.entryTooLarge(name) }

        // 자리 채우기 헤더(deflate 가정).
        var record = Record(
            nameBytes: nameBytes, method: 8, crc: 0, compressedSize: 0, uncompressedSize: 0,
            dosTime: dosTime, dosDate: dosDate, externalAttributes: ext, localHeaderOffset: headerOffset
        )
        try write(Self.localHeader(record))
        let dataStart = position

        var crc = CRC32()
        var total: UInt64 = 0
        var compressed: UInt64 = 0
        let deflater = try RawDeflateStream(.encode)

        while true {
            guard let chunk = try reader.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            total += UInt64(chunk.count)
            if total >= 0xFFFF_FFFF { throw ZipError.entryTooLarge(name) }
            crc.update(chunk)
            try onChunk?(chunk.count)
            try chunk.withUnsafeBytes { buf in
                try deflater.process(buf, finalize: false) { out in
                    compressed += UInt64(out.count)
                    try self.write(out)
                }
            }
        }
        try deflater.process(UnsafeRawBufferPointer(start: nil, count: 0), finalize: true) { out in
            compressed += UInt64(out.count)
            try self.write(out)
        }

        record.crc = crc.value
        record.uncompressedSize = UInt32(total)

        if total == 0 || compressed >= total {
            // stored로 다시 쓴다.
            try seek(to: dataStart)
            try reader.seek(toOffset: 0)
            var remaining = total
            var storedCRC = CRC32()
            while remaining > 0 {
                guard let chunk = try reader.read(upToCount: Int(min(UInt64(Self.chunkSize), remaining))), !chunk.isEmpty else {
                    throw ZipError.io(String(localized: "\(name): 읽는 동안 파일이 줄었습니다"))
                }
                remaining -= UInt64(chunk.count)
                storedCRC.update(chunk)
                try write(chunk)
            }
            // 두 번 읽는 사이에 내용이 바뀌면 헤더의 CRC와 저장한 바이트가 어긋난다. 조용히 넘어가지 않는다.
            guard storedCRC.value == crc.value else { throw ZipError.io(String(localized: "\(name): 읽는 동안 파일 내용이 바뀌었습니다")) }
            do { try handle.truncate(atOffset: position) } catch { throw ZipError.io("\(error)") }
            record.method = 0
            record.compressedSize = UInt32(total)
        } else {
            record.method = 8
            record.compressedSize = UInt32(compressed)
        }

        // 최종 헤더를 덮어쓰고 끝으로 돌아온다.
        let end = position
        try seek(to: UInt64(headerOffset))
        try write(Self.localHeader(record))
        try seek(to: end)
        try appendRecord(record)
    }

    public func finish() throws {
        guard !finished else { return }
        let cdOffset = position
        if cdOffset >= 0xFFFF_FFFF { throw ZipError.archiveTooLarge }
        for r in records { try write(Self.centralHeader(r)) }
        let cdSize = position - cdOffset
        var eocd = Data()
        eocd.le32(0x0605_4B50)
        eocd.le16(0); eocd.le16(0)
        eocd.le16(UInt16(records.count)); eocd.le16(UInt16(records.count))
        eocd.le32(UInt32(cdSize))
        eocd.le32(UInt32(cdOffset))
        eocd.le16(0)
        try write(eocd)
        finished = true
        do { try handle.close() } catch { throw ZipError.io("\(error)") }
    }

    // MARK: 내부

    private func addStored(name: String, data: Data, unixType: UInt32, mode: UInt16, modified: Date, dosDirectory: Bool) throws {
        let nameBytes = try Self.validatedNameBytes(name)
        if data.count >= 0xFFFF_FFFF { throw ZipError.entryTooLarge(name) }
        let (dosTime, dosDate) = Self.dosDateTime(modified)
        var ext = (unixType | UInt32(mode & 0o7777)) << 16
        if dosDirectory { ext |= 0x10 }
        let record = Record(
            nameBytes: nameBytes, method: 0, crc: CRC32.checksum(data),
            compressedSize: UInt32(data.count), uncompressedSize: UInt32(data.count),
            dosTime: dosTime, dosDate: dosDate, externalAttributes: ext, localHeaderOffset: try offset32()
        )
        try write(Self.localHeader(record))
        try write(data)
        try appendRecord(record)
    }

    private func appendRecord(_ r: Record) throws {
        if records.count >= Self.maxEntryCount { throw ZipError.tooManyEntries }
        if position >= 0xFFFF_FFFF { throw ZipError.archiveTooLarge }
        records.append(r)
    }

    private func offset32() throws -> UInt32 {
        guard position < 0xFFFF_FFFF else { throw ZipError.archiveTooLarge }
        return UInt32(position)
    }

    private func write(_ data: Data) throws {
        do { try handle.write(contentsOf: data) } catch { throw ZipError.io("\(error)") }
        position += UInt64(data.count)
    }

    private func write(_ buffer: UnsafeRawBufferPointer) throws {
        try write(Data(buffer))
    }

    private func seek(to offset: UInt64) throws {
        do { try handle.seek(toOffset: offset) } catch { throw ZipError.io("\(error)") }
        position = offset
    }

    private static func fileSize(of url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func validatedNameBytes(_ name: String) throws -> [UInt8] {
        let bytes = Array(name.utf8)
        if bytes.isEmpty || bytes.count > 0xFFFF { throw ZipError.invalidName(name) }
        return bytes
    }

    private static func localHeader(_ r: Record) -> Data {
        var d = Data()
        d.le32(0x0403_4B50)
        d.le16(20)
        d.le16(0x0800)  // UTF-8 이름
        d.le16(r.method)
        d.le16(r.dosTime); d.le16(r.dosDate)
        d.le32(r.crc)
        d.le32(r.compressedSize)
        d.le32(r.uncompressedSize)
        d.le16(UInt16(r.nameBytes.count))
        d.le16(0)
        d.append(contentsOf: r.nameBytes)
        return d
    }

    private static func centralHeader(_ r: Record) -> Data {
        var d = Data()
        d.le32(0x0201_4B50)
        d.le16(0x031E)  // made by: Unix(3), spec 3.0
        d.le16(20)
        d.le16(0x0800)
        d.le16(r.method)
        d.le16(r.dosTime); d.le16(r.dosDate)
        d.le32(r.crc)
        d.le32(r.compressedSize)
        d.le32(r.uncompressedSize)
        d.le16(UInt16(r.nameBytes.count))
        d.le16(0); d.le16(0)  // extra, comment
        d.le16(0); d.le16(0)  // disk, internal attrs
        d.le32(r.externalAttributes)
        d.le32(r.localHeaderOffset)
        d.append(contentsOf: r.nameBytes)
        return d
    }

    /// DOS 시각. 결정적 출력을 위해 UTC 기준으로 계산한다. 1980년 이전은 1980-01-01로 올린다.
    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = c.year, y >= 1980 else { return (0, UInt16((1 << 5) | 1)) }
        let year = min(y, 2107) - 1980
        let dosDate = UInt16((year << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        let dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        return (dosTime, dosDate)
    }
}

extension Data {
    mutating func le16(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }

    mutating func le32(_ v: UInt32) {
        for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) }
    }
}
#endif
