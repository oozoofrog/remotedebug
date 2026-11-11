import Foundation
import Synchronization

/// 환경: `RDTESTENV_BIN`(필수), `RD_FIXTURES`, `RD_E2E_TMPDIR`, `RD_E2E_LOG_DIR`(scripts/e2e-full.sh·scripts/e2e-web.sh가 설정한다).
/// 빠진 값은 건너뛰지 않고 실패한다. 건너뛴 E2E가 통과처럼 보이면 안 된다.
public enum E2EEnv {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    public static func rdtestenv() throws -> String {
        guard let path = env["RDTESTENV_BIN"], !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw E2EError("RDTESTENV_BIN이 없거나 실행할 수 없습니다. scripts/e2e-full.sh 또는 scripts/e2e-web.sh로 돌리세요.")
        }
        return path
    }

    public static func directory(_ name: String) throws -> URL {
        guard let path = env[name], !path.isEmpty else {
            throw E2EError("\(name)가 없습니다. scripts/e2e-full.sh 또는 scripts/e2e-web.sh로 돌리세요.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var fixtures: URL {
        if let path = env["RD_FIXTURES"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }  // Tests/E2ESupport/Processes.swift → Packages
        return url.appendingPathComponent("RemoteDebugKit/Fixtures/apps", isDirectory: true)
    }

    /// 첫 실패 시나리오에서 멈춘다(변이 시험의 시간을 줄인다). 결과는 실패로 남는다.
    public static var failFast: Bool { env["RD_E2E_FAIL_FAST"] == "1" }

    /// 시험 프로세스 안의 마지막 안전장치(초).
    public static var hardLimitSeconds: Int { env["RD_E2E_HARD_LIMIT_SECONDS"].flatMap(Int.init) ?? 540 }
}

public struct E2EError: Error, CustomStringConvertible {
    public let description: String
    public init(_ text: String) { description = text }
}

public func randomID8() -> String { String(format: "%08x", UInt32.random(in: .min ... .max)) }

public final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    public func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    public var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// 이 시험이 띄운 하위 프로세스 전부. 성공·실패·시간 초과 어느 쪽이든 여기서 끝낸다.
public enum ChildRegistry {
    private static let children = Mutex<[Child]>([])

    public static func add(_ child: Child) { children.withLock { $0.append(child) } }

    public static func terminateAll() {
        for child in children.withLock({ list -> [Child] in defer { list = [] }; return list }) {
            child.terminate()
        }
    }

    /// 기다리지 않고 바로 끝낸다(시간 초과 때). 목록은 그대로 둔다.
    public static func killAll() {
        for child in children.withLock({ $0 }) where child.isRunning {
            kill(child.process.processIdentifier, SIGKILL)
        }
    }
}

/// 하위 프로세스. SIGTERM을 보내고 5초 안에 끝나지 않으면 SIGKILL로 끝낸다.
public final class Child: @unchecked Sendable {
    public let process = Process()
    public let out = OutputBox()
    public let err = OutputBox()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    public init(_ executable: String, _ arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [out] handle in out.append(handle.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { [err] handle in err.append(handle.availableData) }
        try process.run()
        ChildRegistry.add(self)
    }

    public var isRunning: Bool { process.isRunning }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    /// 첫 줄의 JSON 값 하나. 아직 없으면 nil.
    public func firstLineValue(_ key: String) -> String? {
        guard let line = out.string.split(separator: "\n").first,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    deinit { terminate() }
}

/// 시험 프로세스가 멈췄을 때의 마지막 안전장치. 하위 프로세스를 끝내고 실패 코드로 나간다.
/// 하위 프로세스를 끝내면 forward의 연결이 닫히므로, 그 닫힘이 시나리오 9의 통과로 세어지지 않게 먼저 표시한다.
public enum HardLimit {
    private static let state = Mutex(false)

    public static var fired: Bool { state.withLock { $0 } }

    public static func arm(seconds: Int, label: String = "e2e-full") {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) {
            state.withLock { $0 = true }
            FileHandle.standardError.write(Data("\(label): 시험이 \(seconds)초 안에 끝나지 않아 멈춥니다.\n".utf8))
            ChildRegistry.killAll()
            _exit(70)
        }
    }
}

/// `rdtestenv control`: 가짜 제어 서버.
public final class FakeControl: @unchecked Sendable {
    public let child: Child
    public let url: String

    public init(binary: String) async throws {
        child = try Child(binary, ["control"])
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let value = child.firstLineValue("controlURL") {
                url = value
                return
            }
            guard child.isRunning else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        child.terminate()
        throw E2EError("rdtestenv control이 controlURL을 내지 않았습니다: \(child.err.string)")
    }
}

/// `rdtestenv forward`: 가짜 tailnet의 iPhone 노드. 루프백 TCP를 Mac의 tailnet 주소로 잇는다.
/// 이 노드의 StableID가 호스트 WhoIs에 보이는 iPhone의 신원이다.
public final class Forwarder: @unchecked Sendable {
    public let child: Child
    public let nodeName: String
    public let port: UInt16

    public init(binary: String, control: String, stateDir: URL, nodeName: String, target: String) async throws {
        self.nodeName = nodeName
        child = try Child(binary, ["forward", "--control", control, "--state-dir", stateDir.path, "--hostname", nodeName,
                                   "--listen", "127.0.0.1:0", "--to", target])
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            if let listen = child.firstLineValue("listen"), let text = listen.split(separator: ":").last, let value = UInt16(text) {
                port = value
                return
            }
            guard child.isRunning else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        child.terminate()
        throw E2EError("forward(\(nodeName))가 준비되지 않았습니다: \(child.err.string.suffix(1500))")
    }
}

/// 루프백 포트로 보낸 평문 HTTP 요청의 결과.
public enum RawProbeResult: Sendable, Equatable {
    case responded(String)
    /// 응답 바이트 없이 연결이 닫혔다(EOF 또는 reset).
    case closed
    case timedOut
    case connectFailed(Int32)
}

/// 존재하지 않는 경로 하나. 호스트는 인증 전에 404 `not_found`로 답하므로 `denied` 이벤트를 만들지 않는다
/// (시나리오 1의 거부 기록이 이 탐침 때문에 생기면 안 된다).
public let forwarderProbePath = "/v1/e2e-forwarder-probe"

public func rawHTTPProbe(port: UInt16, timeout: Duration) async -> RawProbeResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: blockingProbe(port: port, timeout: timeout))
        }
    }
}

private func blockingProbe(port: UInt16, timeout: Duration) -> RawProbeResult {
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
    let request = Array("GET \(forwarderProbePath) HTTP/1.1\r\nHost: rd-probe\r\nConnection: close\r\n\r\n".utf8)
    _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var buffer = [UInt8](repeating: 0, count: 512)
    let count = recv(fd, &buffer, buffer.count, 0)
    if count > 0 { return .responded(String(decoding: buffer[..<count], as: UTF8.self)) }
    if count == 0 || errno == ECONNRESET { return .closed }
    return errno == EAGAIN ? .timedOut : .connectFailed(errno)
}
