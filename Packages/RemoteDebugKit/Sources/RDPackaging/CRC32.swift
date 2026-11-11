#if os(macOS)
import Foundation

/// ZIP이 쓰는 CRC-32 (IEEE 802.3, 반사형 다항식 0xEDB88320).
public struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update(_ buffer: UnsafeRawBufferPointer) {
        var c = state
        Self.table.withUnsafeBufferPointer { table in
            for byte in buffer {
                c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
            }
        }
        state = c
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    public var value: UInt32 { ~state }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }
}
#endif
