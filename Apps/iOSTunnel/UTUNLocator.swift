import Darwin
import Foundation

/// 확장 프로세스의 fd를 훑어 Network Extension이 만든 utun 제어 소켓을 찾는다(docs/tunnel.md 1).
///
/// iOS SDK에는 `sys/kern_control.h`·`net/if_utun.h`가 없으므로 필요한 상수와 구조체 배치를 여기에 둔다.
/// 찾은 fd는 NE 소유다. 닫지 않고 읽고 쓰지도 않는다(코어가 dup해 쓴다). 코어도 시작 전에 한 번 더 검증한다.
enum UTUNLocator {
    struct Found: Equatable, Sendable {
        var fd: Int32
        var interfaceName: String
    }

    static let controlName = "com.apple.net.utun_control"
    /// `_IOWR('N', 3, struct ctl_info)`, `sizeof(struct ctl_info) == 100`.
    static let ctlIOCGInfo: UInt = 0xC064_4E03
    static let afSystem: UInt8 = 32
    static let sysprotoControl: Int32 = 2
    static let utunOptIfName: Int32 = 2
    static let maxFD: Int32 = 1023

    /// 0...1023 중 utun 제어 소켓(peer가 `com.apple.net.utun_control`, 인터페이스 이름이 `utun`으로 시작)의 첫 fd.
    static func find() -> Found? {
        guard let controlID = utunControlID() else { return nil }
        for fd in 0...maxFD {
            guard let peer = peerControlID(fd), peer == controlID else { continue }
            guard let name = interfaceName(fd), name.hasPrefix("utun") else { continue }
            return Found(fd: fd, interfaceName: name)
        }
        return nil
    }

    /// `CTLIOCGINFO`로 utun 제어의 커널 id를 얻는다. 임시 소켓 하나를 열고 닫는다.
    private static func utunControlID() -> UInt32? {
        let fd = socket(Int32(afSystem), SOCK_DGRAM, sysprotoControl)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // struct ctl_info { u_int32_t ctl_id; char ctl_name[96]; }
        var info = [UInt8](repeating: 0, count: 100)
        let name = Array(controlName.utf8)
        info.replaceSubrange(4..<(4 + name.count), with: name)
        let result = info.withUnsafeMutableBytes { raw -> Int32 in
            ioctl(fd, ctlIOCGInfo, raw.baseAddress!)
        }
        guard result == 0 else { return nil }
        return info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    }

    /// fd의 peer가 커널 제어 소켓이면 그 `sc_id`.
    private static func peerControlID(_ fd: Int32) -> UInt32? {
        // struct sockaddr_ctl { u_char sc_len; u_char sc_family; u_int16_t ss_sysaddr;
        //                       u_int32_t sc_id; u_int32_t sc_unit; u_int32_t sc_reserved[5]; }
        var storage = [UInt8](repeating: 0, count: 32)
        var length = socklen_t(storage.count)
        let result = storage.withUnsafeMutableBytes { raw -> Int32 in
            getpeername(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), &length)
        }
        guard result == 0, length >= 8, storage[1] == afSystem else { return nil }
        return storage.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    }

    /// `UTUN_OPT_IFNAME`으로 인터페이스 이름(`utunN`)을 읽는다.
    static func interfaceName(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var length = socklen_t(buffer.count)
        let result = getsockopt(fd, sysprotoControl, utunOptIfName, &buffer, &length)
        guard result == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? nil : name
    }
}
