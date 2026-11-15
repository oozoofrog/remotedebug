import Darwin

/// 운영자가 정한 파일 하나를 오프셋으로 읽는다. 파일 전체를 메모리에 올리지 않는다.
///
/// 길이는 연 기술자의 `fstat`로 한 번 정한다(응답의 `Content-Length`와 실제 보낸 양이 어긋나지 않게). 읽는 도중 파일이
/// 줄면 `read`가 실패하고 응답은 끊긴다.
final class FileSource {
    enum Failure: Error, Equatable {
        /// 열지 못했거나 정규 파일이 아니다. 연관 값은 errno 이름만 담는다(경로를 담지 않는다).
        case unavailable(String)
        /// 읽는 도중 끝났거나 실패했다.
        case readFailed(String)
    }

    let length: UInt64
    private let descriptor: Int32

    init(path: String) throws(Failure) {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw .unavailable(Self.errnoName(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw .unavailable(Self.errnoName(code))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            close(descriptor)
            throw .unavailable("EFTYPE")
        }
        self.descriptor = descriptor
        length = UInt64(info.st_size)
    }

    deinit { close(descriptor) }

    /// `offset`부터 `count`바이트. 다 채우지 못하면(파일이 줄었다) 실패한다.
    func read(at offset: UInt64, count: Int) throws(Failure) -> [UInt8] {
        guard count > 0 else { return [] }
        guard offset <= UInt64(Int64.max) else { throw .readFailed("EINVAL") }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let result = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress! + filled, count - filled, off_t(offset) + off_t(filled))
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw .readFailed(Self.errnoName(errno))
            }
            if result == 0 { throw .readFailed("EOF") }
            filled += result
        }
        return buffer
    }

    static func errnoName(_ code: Int32) -> String {
        switch code {
        case ENOENT: "ENOENT"
        case EACCES: "EACCES"
        case EPERM: "EPERM"
        case EISDIR: "EISDIR"
        case ELOOP: "ELOOP"
        case EIO: "EIO"
        case EINVAL: "EINVAL"
        default: "errno \(code)"
        }
    }
}
