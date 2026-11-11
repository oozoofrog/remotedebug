import Foundation
import Synchronization

/// 시험 프로세스 안의 루프백 HTTP CONNECT 프록시. WKWebView가 `http://<fqdn>:8080/`을 실제로 방문하게 한다.
///
/// 브라우저(WebKit 네트워크 프로세스)는 `WKWebsiteDataStore.proxyConfigurations`로 이 프록시에 `CONNECT <fqdn>:8080`을 보내고,
/// 프록시는 그 연결을 `rdtestenv forward`의 루프백 포트로 그대로 잇는다. forward는 가짜 tailnet을 거쳐 Mac의 `<fqdn>:8080`에 닿는다.
/// 그래서 페이지의 출처(`location.origin`)는 Mac이 설치 주소에 쓰는 출처(`http://<fqdn>:8080`)와 같다.
///
/// 허용한 대상 하나 말고는 모두 403으로 끊고 기록한다(시험이 루프백·가짜 tailnet 밖으로 나가지 않는다).
final class ConnectProxy: @unchecked Sendable {
    struct Record: Sendable, Equatable {
        var requestLine: String
        var allowed: Bool
    }

    let port: UInt16
    let allowedTarget: String
    private let upstreamPort: UInt16
    private let listenFD: Int32
    private let state = Mutex<(records: [Record], fds: Set<Int32>, stopped: Bool)>(([], [], false))

    /// `allowedTarget`: `host:port` 꼴의 CONNECT 대상. `upstreamPort`: 그 대상으로 가는 루프백 포트(forward).
    init(allowedTarget: String, upstreamPort: UInt16) throws {
        self.allowedTarget = allowedTarget.lowercased()
        self.upstreamPort = upstreamPort
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw E2EError("프록시 소켓을 만들지 못했다: \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            throw E2EError("프록시가 루프백 포트를 열지 못했다: \(errno)")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listenFD = fd
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "rd-connect-proxy"
        thread.start()
    }

    var records: [Record] { state.withLock { $0.records } }

    /// 듣기를 멈추고 열린 연결을 모두 닫는다.
    func stop() {
        let (wasStopped, fds) = state.withLock { s -> (Bool, Set<Int32>) in
            let was = s.stopped
            s.stopped = true
            defer { s.fds = [] }
            return (was, s.fds)
        }
        if wasStopped { return }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        for fd in fds { shutdown(fd, SHUT_RDWR) }
    }

    deinit { stop() }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private func track(_ fd: Int32) -> Bool {
        // 닫힌 연결에 쓸 때 SIGPIPE로 시험 프로세스가 끝나지 않게 한다.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return state.withLock { s in
            if s.stopped { return false }
            s.fds.insert(fd)
            return true
        }
    }

    private func untrack(_ fd: Int32) {
        _ = state.withLock { $0.fds.remove(fd) }
        close(fd)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            guard track(client) else {
                close(client)
                return
            }
            let thread = Thread { [self] in handle(client) }
            thread.start()
        }
    }

    private func handle(_ client: Int32) {
        // 요청 머리(빈 줄까지)를 읽는다. 머리 뒤에 이미 온 바이트는 위로 그대로 넘긴다.
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while head.range(of: terminator) == nil, head.count < 16 * 1024 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 {
                untrack(client)
                return
            }
            head.append(contentsOf: buffer[..<n])
        }
        guard let end = head.range(of: terminator) else {
            untrack(client)
            return
        }
        let headText = String(decoding: head[..<end.lowerBound], as: UTF8.self)
        let rest = head[end.upperBound...]
        let requestLine = headText.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let allowed = parts.count == 3 && parts[0] == "CONNECT" && parts[1].lowercased() == allowedTarget
        state.withLock { $0.records.append(Record(requestLine: requestLine, allowed: allowed)) }
        guard allowed else {
            writeAll(client, Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            untrack(client)
            return
        }

        let upstream = socket(AF_INET, SOCK_STREAM, 0)
        var address = Self.loopback(port: upstreamPort)
        let connected = upstream >= 0 && withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
        guard connected, track(upstream) else {
            if upstream >= 0 { close(upstream) }
            writeAll(client, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            untrack(client)
            return
        }
        writeAll(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        if !rest.isEmpty { writeAll(upstream, Data(rest)) }

        let done = DispatchSemaphore(value: 0)
        let back = Thread { [self] in
            pipe(from: upstream, to: client)
            done.signal()
        }
        back.start()
        pipe(from: client, to: upstream)
        done.wait()
        untrack(upstream)
        untrack(client)
    }

    /// 한쪽이 닫히면 다른 쪽의 쓰기 방향을 닫는다(반쪽 닫힘을 그대로 전한다).
    private func pipe(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(source, &buffer, buffer.count)
            if n <= 0 { break }
            if !writeAll(destination, Data(buffer[..<n])) { break }
        }
        shutdown(destination, SHUT_WR)
    }

    @discardableResult
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
