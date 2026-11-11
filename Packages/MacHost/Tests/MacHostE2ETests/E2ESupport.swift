import CryptoKit
import Foundation
import MacHostKit
import Synchronization

/// E2E 환경: `RDTESTENV_BIN`(필수), `RD_FIXTURES`(없으면 저장소의 픽스처), `RD_E2E_TMPDIR`(없으면 eyedisk 빌드 폴더).
enum E2EEnv {
    static var rdtestenv: String? {
        guard let p = ProcessInfo.processInfo.environment["RDTESTENV_BIN"], !p.isEmpty,
              FileManager.default.isExecutableFile(atPath: p) else { return nil }
        return p
    }

    static var isEnabled: Bool { rdtestenv != nil }

    static var fixtures: URL {
        if let p = ProcessInfo.processInfo.environment["RD_FIXTURES"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }  // Tests/MacHostE2ETests/E2ESupport.swift → Packages
        return u.appendingPathComponent("RemoteDebugKit/Fixtures/apps", isDirectory: true)
    }

    static var tmpBase: URL {
        let env = ProcessInfo.processInfo.environment
        return URL(fileURLWithPath: env["RD_E2E_TMPDIR"] ?? env["RD_TEST_TMPDIR"] ?? "/Volumes/eyedisk/build/remotedebug/mac-host-tmp",
                   isDirectory: true)
    }
}

final class E2ETempDir: @unchecked Sendable {
    let url: URL

    init() throws {
        url = E2EEnv.tmpBase.appendingPathComponent("e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// 감시 폴더를 쓰지 않는 E2E용 북마크 저장소(UserDefaults를 건드리지 않는다).
final class NoBookmarks: FolderBookmarking {
    func save(_ url: URL) throws {}
    func resolve() -> URL? { nil }
    func clear() {}
}

func sha256Hex(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func randomID8() -> String { String(format: "%08x", UInt32.random(in: .min ... .max)) }

// MARK: 하위 프로세스

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    var json: [String: Any]? {
        for line in stdout.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    var summary: String { "exit=\(status) timedOut=\(timedOut)\nstdout: \(stdout)\nstderr: \(stderr.suffix(1500))" }
}

/// 출력을 모으는 상자.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// 실행 중인 하위 프로세스. 테스트가 끝나면 `terminate()`.
final class Child: @unchecked Sendable {
    let process = Process()
    let out = OutputBox()
    let err = OutputBox()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    init(_ executable: String, _ arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [out] h in out.append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { [err] h in err.append(h.availableData) }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    /// 끝날 때까지(최대 `timeout`) 기다린다. 시간을 넘기면 끝내고 `timedOut`을 표시한다.
    func wait(timeout: Duration) async -> ProcessResult {
        let deadline = ContinuousClock.now + timeout
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let timedOut = process.isRunning
        terminate()
        drainPipes()
        return ProcessResult(status: process.terminationStatus, stdout: out.string, stderr: err.string, timedOut: timedOut)
    }

    /// 프로세스가 끝난 뒤 남은 출력을 파이프 끝(EOF)까지 읽는다(시간으로 기다리지 않는다).
    /// 하위 프로세스가 출력 파이프를 물려준 손자 프로세스를 남겼으면 EOF가 늦을 수 있어 그때는 2초까지만 읽는다.
    private func drainPipes() {
        for (pipe, box) in [(outPipe, out), (errPipe, err)] {
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = nil
            let done = DispatchSemaphore(value: 0)
            let rest = OutputBox()
            Thread.detachNewThread {
                rest.append(handle.readDataToEndOfFile())
                done.signal()
            }
            if done.wait(timeout: .now() + 2) == .success {
                box.append(Data(rest.string.utf8))
            }
        }
    }

    deinit { terminate() }
}

/// `rdtestenv control`: 가짜 제어 서버.
final class FakeControl: @unchecked Sendable {
    let child: Child
    let url: String

    init(binary: String) async throws {
        child = try Child(binary, ["control"])
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let line = child.out.string.split(separator: "\n").first,
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let u = obj["controlURL"] as? String {
                url = u
                return
            }
            guard child.isRunning else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        child.terminate()
        throw E2EError("rdtestenv control이 controlURL을 내지 않았습니다: \(child.err.string)")
    }

    func stop() { child.terminate() }
}

/// `rdtestenv peer`: 가짜 tailnet의 클라이언트 노드(상태 폴더 = 노드 신원).
struct Peer: Sendable {
    let binary: String
    let control: String
    let stateDir: URL
    let hostname: String

    func start(_ action: String, _ flags: [String]) throws -> Child {
        try Child(binary, ["peer", "--control", control, "--state-dir", stateDir.path, "--hostname", hostname, action] + flags)
    }

    func run(_ action: String, _ flags: [String], timeout: Duration = .seconds(90)) async throws -> ProcessResult {
        await (try start(action, flags)).wait(timeout: timeout)
    }
}

/// 루프백 포트에 HTTP 요청을 보낸 결과.
enum RawProbeResult: Sendable, Equatable {
    /// 응답의 첫 부분.
    case responded(String)
    /// 응답 바이트 없이 연결이 닫혔다(EOF 또는 reset).
    case closed
    /// 시간 안에 응답도 닫힘도 없었다.
    case timedOut
    case connectFailed(Int32)
}

/// `GET /v1/builds`를 보내고 첫 응답·닫힘·시간 초과 중 먼저 일어난 것을 돌려준다.
func rawHTTPProbe(port: UInt16, timeout: Duration) async -> RawProbeResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: blockingHTTPProbe(port: port, timeout: timeout))
        }
    }
}

private func blockingHTTPProbe(port: UInt16, timeout: Duration) -> RawProbeResult {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return .connectFailed(errno) }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return .connectFailed(errno) }
    var limit = timeval(tv_sec: Int(timeout.components.seconds), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    let request = Array("GET /v1/builds HTTP/1.1\r\nHost: rd-probe\r\nConnection: close\r\n\r\n".utf8)
    _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var buffer = [UInt8](repeating: 0, count: 256)
    let count = recv(fd, &buffer, buffer.count, 0)
    if count > 0 { return .responded(String(decoding: buffer[..<count], as: UTF8.self)) }
    if count == 0 || errno == ECONNRESET { return .closed }
    return errno == EAGAIN ? .timedOut : .connectFailed(errno)
}

struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
