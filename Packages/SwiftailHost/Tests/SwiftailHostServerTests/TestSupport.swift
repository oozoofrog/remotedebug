import Foundation
import Network
import RDHostLogic
import Synchronization
import Testing

@testable import SwiftailHostServer

/// 시험 임시 폴더. `RD_TEST_TMPDIR`가 있으면 그 아래(빌드 디스크), 없으면 시스템 임시 폴더.
func makeTestDirectory(_ name: String = "t") throws -> URL {
    let base = ProcessInfo.processInfo.environment["RD_TEST_TMPDIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        ?? FileManager.default.temporaryDirectory
    let url = base.appending(path: "\(name)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let testPeer = HostPeer(stableID: "nTEST1234", nodeName: "rd-phone-1a2b3c4d", loginName: "user@example.com")

/// 처리기를 클로저로.
struct ClosureHandler: HostRequestHandling {
    let body: @Sendable (HostRequest) async -> HostResponse
    func handle(_ request: HostRequest) async -> HostResponse { await body(request) }
}

/// `onFinished` 기록.
final class FinishLog: Sendable {
    private let calls = Mutex<[(UInt64, Bool)]>([])
    func record(_ sent: UInt64, _ completed: Bool) { calls.withLock { $0.append((sent, completed)) } }
    var all: [(UInt64, Bool)] { calls.withLock { $0 } }
}

func startPlain(_ handler: any HostRequestHandling, limits: HTTPServerLimits = HTTPServerLimits()) async throws -> HTTPListener {
    try await HTTPListener.start(binding: .loopback(port: 0), security: .plaintext, admission: .acceptAllForTesting(testPeer),
                                 handler: handler, limits: limits)
}

func waitUntil(_ seconds: Double = 10, _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("기한 안에 조건이 서지 않음")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// 평문 HTTP 클라이언트(시험용). 응답 하나씩 `Content-Length`로 끊어 읽는다.
final class RawClient: @unchecked Sendable {
    struct Response {
        var status: Int
        var head: String
        var headers: [String: String]
        var body: [UInt8]
    }

    let connection: NWConnection
    private var buffer: [UInt8] = []

    init(port: UInt16) async throws {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        guard await ConnectionIO.ready(connection) else { throw CancellationError() }
    }

    deinit { connection.cancel() }

    func send(_ text: String) async { _ = await ConnectionIO.send(connection, Array(text.utf8)) }
    func send(_ bytes: [UInt8]) async { _ = await ConnectionIO.send(connection, bytes) }

    /// 응답 하나. `headOnly`면 본문을 읽지 않는다(HEAD). 연결이 끝나면 nil.
    func response(headOnly: Bool = false) async -> Response? {
        while HTTPRequestParser.firstIndex(of: [13, 10, 13, 10], in: buffer) == nil {
            guard case .bytes(let more) = await ConnectionIO.receive(connection, maximum: 65_536), !more.isEmpty else { return nil }
            buffer += more
        }
        let end = HTTPRequestParser.firstIndex(of: [13, 10, 13, 10], in: buffer)!
        let head = String(decoding: buffer[..<end], as: UTF8.self)
        buffer.removeFirst(end + 4)
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let status = Int(head.split(separator: " ")[1]) ?? 0
        let length = headOnly ? 0 : Int(headers["content-length"] ?? "0") ?? 0
        while buffer.count < length {
            guard case .bytes(let more) = await ConnectionIO.receive(connection, maximum: 1 << 20), !more.isEmpty else { return nil }
            buffer += more
        }
        let body = Array(buffer.prefix(length))
        buffer.removeFirst(length)
        return Response(status: status, head: head, headers: headers, body: body)
    }

    /// 상대가 닫을 때까지 기다린다. 닫혔으면 참.
    func waitForClose(seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [connection] in
                while case .bytes(let more) = await ConnectionIO.receive(connection, maximum: 65_536), !more.isEmpty {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first { connection.cancel() }
            return first
        }
    }
}
