import Darwin
import Foundation

/// 저장 폴더 하나를 한 프로세스만 쓰게 하는 배타적 권고 잠금(`<root>/.lock`, `flock`).
///
/// 코어 `rd_start`의 `state_dir_in_use` 검사는 한 프로세스 안에서만 동작한다(addenda A.3). 두 번째 앱 인스턴스가
/// `Work/`·`Published/`를 비우거나 같은 노드 신원으로 tailnet에 오르지 않도록, 불러오기·공유 시작 전에 잡고 종료할 때 놓는다.
/// 프로세스가 죽으면 커널이 잠금을 푼다.
public final class StateDirLock: @unchecked Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// 다른 프로세스(또는 같은 프로세스의 다른 잠금)가 이미 잡고 있다.
        case held
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .held: "이미 실행 중인 RemoteDebug가 같은 폴더를 쓰고 있습니다."
            case .io(let detail): "저장 폴더를 잠그지 못했습니다: \(detail)"
            }
        }
    }

    public let url: URL
    private let lock = NSLock()
    private var fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    /// `root`(없으면 만든다)의 `.lock`을 잠근다. 이미 잠겨 있으면 기다리지 않고 `.held`를 던진다.
    public static func acquire(root: URL) throws -> StateDirLock {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw Failure.io(HostErrorText.message(for: error))
        }
        let url = root.appendingPathComponent(".lock")
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw Failure.held }
            throw Failure.io(String(cString: strerror(code)))
        }
        return StateDirLock(url: url, fd: fd)
    }

    public var isHeld: Bool { lock.withLock { fd >= 0 } }

    /// 잠금을 놓는다. 여러 번 불러도 된다.
    public func release() {
        let old: Int32 = lock.withLock {
            defer { fd = -1 }
            return fd
        }
        guard old >= 0 else { return }
        flock(old, LOCK_UN)
        close(old)
    }

    deinit { release() }
}
