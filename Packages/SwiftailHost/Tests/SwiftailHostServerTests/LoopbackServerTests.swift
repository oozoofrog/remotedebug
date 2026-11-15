import Foundation
import Network
import Swiftail
import SwiftailLoopback
import Synchronization
import Testing

@testable import SwiftailHostServer

/// 루프백 소켓만 쓰는 시험. 계정·제어 서버·인증서 없이 서버의 HTTP 동작과 다리 없는 연결의 거절을 본다.
@Suite("루프백 서버", .serialized, .timeLimit(.minutes(1)))
struct LoopbackServerTests {
    final class EventLog: Sendable {
        private let events = Mutex<[HostEvent]>([])
        func append(_ event: HostEvent) { events.withLock { $0.append(event) } }
        var responses: [ResponseRecord] {
            events.withLock { $0.compactMap { if case .response(let record) = $0 { record } else { nil } } }
        }
        var rejected: Int { events.withLock { $0.count { if case .connectionRejected = $0 { true } else { false } } } }
        var connections: Int { events.withLock { $0.count { if case .connection = $0 { true } else { false } } } }
    }

    private func withFile<T>(_ bytes: [UInt8], _ body: (String) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftail-host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "payload.bin")
        try Data(bytes).write(to: url)
        return try await body(url.path)
    }

    private func startPlain(content: ServedContent, log: EventLog) async throws -> LoopbackHTTPSServer {
        try await LoopbackHTTPSServer.start(security: .plaintextForTesting, admission: .acceptAllForTesting(stableID: "nTEST"),
                                            domain: "rd-mac-1a2b3c4d.tail0001.ts.net", content: content,
                                            timeouts: .init(ready: 5, head: 2, idle: 5), events: log.append)
    }

    /// 요청을 보내고 상대가 닫을 때까지 받은 바이트. 머리와 본문으로 나눈다.
    private func exchange(port: UInt16, _ request: [UInt8], finish: Bool = true) async -> (head: String, body: [UInt8]) {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        guard await LoopbackHTTPSServer.ready(connection) else { return ("", []) }
        _ = await LoopbackHTTPSServer.send(connection, request, final: finish)
        var received: [UInt8] = []
        while case .bytes(let more) = await LoopbackHTTPSServer.receive(connection) { received += more }
        connection.cancel()
        guard let split = HTTPRequestParser.firstIndex(of: [13, 10, 13, 10], in: received) else {
            return (String(decoding: received, as: UTF8.self), [])
        }
        return (String(decoding: received[..<split], as: UTF8.self), Array(received[(split + 4)...]))
    }

    private func get(_ path: String, _ extra: String = "", method: String = "GET") -> [UInt8] {
        Array("\(method) \(path) HTTP/1.1\r\nHost: x\r\n\(extra)\r\n".utf8)
    }

    @Test func rangeFullHeadAndErrors() async throws {
        let payload = (0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        try await withFile(payload) { path in
            let log = EventLog()
            let server = try await startPlain(content: ServedContent(filePath: path), log: log)
            defer { server.close() }

            let full = await exchange(port: server.port, get("/file"))
            #expect(full.head.hasPrefix("HTTP/1.1 200 OK"))
            #expect(full.head.contains("Content-Length: 1000000"))
            #expect(full.body == payload)

            let partial = await exchange(port: server.port, get("/file", "Range: bytes=999990-\r\n"))
            #expect(partial.head.hasPrefix("HTTP/1.1 206 Partial Content"))
            #expect(partial.head.contains("Content-Range: bytes 999990-999999/1000000"))
            #expect(partial.body == Array(payload[999_990...]))

            let unsatisfiable = await exchange(port: server.port, get("/file", "Range: bytes=1000000-\r\n"))
            #expect(unsatisfiable.head.hasPrefix("HTTP/1.1 416"))
            #expect(unsatisfiable.head.contains("Content-Range: bytes */1000000"))
            #expect(unsatisfiable.body.isEmpty)

            let head = await exchange(port: server.port, get("/file", method: "HEAD"))
            #expect(head.head.contains("Content-Length: 1000000") && head.body.isEmpty)

            #expect(await exchange(port: server.port, get("/manifest.plist")).head.hasPrefix("HTTP/1.1 404"))
            #expect(await exchange(port: server.port, get("/../file")).head.hasPrefix("HTTP/1.1 404"))
            #expect(await exchange(port: server.port, get("/file", method: "POST")).head.hasPrefix("HTTP/1.1 405"))
            let oversized = await exchange(port: server.port, get("/", "X: " + String(repeating: "a", count: 20_000) + "\r\n"))
            #expect(oversized.head.hasPrefix("HTTP/1.1 431"))

            // 기록: 경로 표에 없거나 해석에서 거절한 요청은 경로 없이 남는다.
            try await waitUntil { log.responses.count == 8 }
            let records = log.responses
            #expect(records.first { $0.route == .file && $0.status == 200 }?.bodyBytes == 1_000_000)
            #expect(records.allSatisfy { $0.peerStableID == "nTEST" && $0.completed })
            #expect(records.filter { $0.route == nil }.map(\.status).sorted() == [404, 404, 405, 431])
            try await waitUntil { server.activeConnectionCount == 0 }
        }
    }

    @Test func stalledHeadIsCut() async throws {
        let log = EventLog()
        let server = try await startPlain(content: ServedContent(), log: log)
        defer { server.close() }
        let started = ContinuousClock.now
        // 머리를 끝내지 않고 쓰기도 닫지 않는다. 머리 기한(2초)에 서버가 끊는다.
        let result = await exchange(port: server.port, Array("GET / HTTP/1.1\r\n".utf8), finish: false)
        #expect(result.head.isEmpty)
        #expect(started.duration(to: .now) < .seconds(10))
        try await waitUntil { server.activeConnectionCount == 0 }
    }

    /// 다리의 framer를 넣은 리스너에 토큰 없이 직접 건 연결은 `.ready`가 되지 못하고, 서버는 그것을 끊고 놓는다(동작 B6·B7).
    @Test func directConnectionWithoutBridgeTokenIsRejectedAndReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftail-host-node-\(UUID().uuidString)")
        // `TailnetNode.init`은 파일·소켓을 만들지 않는다. `run()`은 부르지 않는다.
        let node = try TailnetNode(configuration: NodeConfiguration(stateDirectory: directory, hostname: "rd-mac-1a2b3c4d"),
                                   device: .inProcess)
        let bridge = LoopbackBridge(node: node)
        let log = EventLog()
        let server = try await LoopbackHTTPSServer.start(security: .plaintextForTesting, admission: .bridge(bridge),
                                                         domain: "rd-mac-1a2b3c4d.tail0001.ts.net", content: ServedContent(),
                                                         timeouts: .init(), events: log.append)
        defer { server.close() }

        // 32바이트를 채운 틀린 토큰과 요청. 상대에게는 아무 응답 없이 끝나야 한다.
        let result = await exchange(port: server.port, Array(String(repeating: "x", count: 32).utf8) + get("/"))
        #expect(result.head.isEmpty && result.body.isEmpty)
        try await waitUntil { log.rejected == 1 }
        #expect(log.connections == 0)
        #expect(log.responses.isEmpty)
        try await waitUntil { server.activeConnectionCount == 0 }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("10초 안에 조건이 서지 않음")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@Suite("PEM")
struct PEMCertificatesTests {
    @Test func readsAllCertificateBlocks() throws {
        let pem = """
            # 설명 줄
            -----BEGIN CERTIFICATE-----
            AQID
            -----END CERTIFICATE-----
            -----BEGIN CERTIFICATE-----
            BAUG
            BwgJ
            -----END CERTIFICATE-----
            """
        #expect(try PEMCertificates.ders(from: pem) == [[1, 2, 3], [4, 5, 6, 7, 8, 9]])
    }

    @Test func rejectsOtherBlocksAndBrokenInput() {
        #expect(throws: PEMCertificates.Failure.unexpectedBlock) {
            try PEMCertificates.ders(from: "-----BEGIN PRIVATE KEY-----\nAQID\n-----END PRIVATE KEY-----\n")
        }
        #expect(throws: PEMCertificates.Failure.malformed) {
            try PEMCertificates.ders(from: "-----BEGIN CERTIFICATE-----\nAQID\n")
        }
        #expect(throws: PEMCertificates.Failure.malformed) {
            try PEMCertificates.ders(from: "-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n")
        }
        #expect(throws: PEMCertificates.Failure.empty) { try PEMCertificates.ders(from: "nothing") }
    }
}
