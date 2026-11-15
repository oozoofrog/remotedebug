import CryptoKit
import Darwin
import Foundation
import Network
import RDHostLogic
import Swiftail
import SwiftailLoopback
import Synchronization
import Testing

@testable import SwiftailHostServer

/// 루프백 평문 리스너로 전송의 HTTP 동작을 본다. 계정·제어 서버·인증서 없이 돈다.
@Suite("HTTP 전송", .serialized, .timeLimit(.minutes(2)))
struct HTTPTransportTests {
    @Test func keepAliveCarriesSeveralRequestsWithOrigin() async throws {
        let origins = Mutex<[HostOrigin]>([])
        let server = try await startPlain(ClosureHandler { request in
            origins.withLock { $0.append(request.origin) }
            return HostResponse(status: 200, headers: [("Content-Type", "text/plain"), ("Content-Length", "999"), ("Connection", "close")],
                                body: .bytes(Array(request.target.utf8)))
        })
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        for path in ["/a", "/b?x=1", "/c"] {
            await client.send("GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n")
            let response = try #require(await client.response())
            #expect(response.status == 200)
            #expect(response.body == Array(path.utf8))
            // 로직이 넣은 Content-Length·Connection은 전송의 값으로 바뀐다.
            #expect(response.headers["content-length"] == "\(path.utf8.count)")
            #expect(response.headers["connection"] == "keep-alive")
            #expect(response.headers["date"]?.hasSuffix(" GMT") == true)
        }
        #expect(origins.withLock { $0 } == Array(repeating: .tailnet(testPeer), count: 3))
        #expect(server.activeConnectionCount == 1)
    }

    @Test func requestBodyIsStreamedAndNextPipelinedRequestSurvives() async throws {
        let body = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let server = try await startPlain(ClosureHandler { request in
            guard let reader = request.body else { return HostResponse(status: 200, body: .bytes(Array("none".utf8))) }
            var hasher = SHA256()
            var total = 0
            var chunks = 0
            while let chunk = try? await reader.read(upTo: 10_000) {
                hasher.update(data: chunk)
                total += chunk.count
                chunks += 1
                #expect(chunk.count <= 10_000)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return HostResponse(status: 200, body: .bytes(Array("\(total) \(digest) \(chunks > 1)".utf8)))
        })
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send(Array("POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
                          + Array("GET /next HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        let first = try #require(await client.response())
        let expected = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        #expect(String(decoding: first.body, as: UTF8.self) == "300000 \(expected) true")
        let second = try #require(await client.response())
        #expect(String(decoding: second.body, as: UTF8.self) == "none")
    }

    @Test func unreadBodyIsDrainedWhenSmallAndClosesWhenLarge() async throws {
        var limits = HTTPServerLimits()
        limits.drainBody = 1_000
        let server = try await startPlain(ClosureHandler { _ in HostResponse(status: 403) }, limits: limits)
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 500\r\n\r\n" + String(repeating: "z", count: 500))
        let small = try #require(await client.response())
        #expect(small.status == 403 && small.headers["connection"] == "keep-alive")
        await client.send("POST /a HTTP/1.1\r\nHost: x\r\nContent-Length: 50000\r\n\r\n" + String(repeating: "z", count: 50_000))
        let large = try #require(await client.response())
        #expect(large.status == 403 && large.headers["connection"] == "close")
        #expect(await client.waitForClose(seconds: 5))
    }

    @Test func oversizedAndChunkedBodiesAreRefused() async throws {
        var limits = HTTPServerLimits()
        limits.requestBody = 1_000
        let called = Mutex(0)
        let server = try await startPlain(ClosureHandler { _ in
            called.withLock { $0 += 1 }
            return HostResponse(status: 200)
        }, limits: limits)
        defer { server.close() }
        let big = try await RawClient(port: server.port)
        await big.send("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1001\r\n\r\n")
        #expect(try #require(await big.response()).status == 413)
        let chunked = try await RawClient(port: server.port)
        await chunked.send("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
        let response = try #require(await chunked.response())
        #expect(response.status == 411 && response.headers["connection"] == "close")
        #expect(called.withLock { $0 } == 0)
    }

    @Test func headSendsHeadersWithoutBody() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "a.bin")
        try Data(repeating: 7, count: 12_345).write(to: file)
        let finished = FinishLog()
        let server = try await startPlain(ClosureHandler { request in
            HostResponse(status: 200, headers: [("Content-Type", "application/octet-stream")],
                         body: request.target == "/bytes" ? .bytes([1, 2, 3]) : .file(path: file.path, offset: 0, count: 12_345),
                         onFinished: { finished.record($0, $1) })
        })
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("HEAD /file HTTP/1.1\r\nHost: x\r\n\r\n")
        let head = try #require(await client.response(headOnly: true))
        #expect(head.status == 200 && head.headers["content-length"] == "12345")
        await client.send("HEAD /bytes HTTP/1.1\r\nHost: x\r\n\r\n")
        let bytes = try #require(await client.response(headOnly: true))
        #expect(bytes.headers["content-length"] == "3")
        // HEAD 뒤에 본문이 끼어 있지 않다: 다음 GET이 그대로 읽힌다.
        await client.send("GET /bytes HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try #require(await client.response()).body == [1, 2, 3])
        try await waitUntil { finished.all.count == 3 }
        #expect(finished.all.map(\.0) == [0, 0, 3] && finished.all.allSatisfy(\.1))
    }

    @Test func noBodyStatusesOmitContentLength() async throws {
        let server = try await startPlain(ClosureHandler { _ in HostResponse(status: 204, body: .bytes([1, 2])) })
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        let response = try #require(await client.response())
        #expect(response.status == 204 && response.headers["content-length"] == nil && response.body.isEmpty)
    }

    /// 4GiB를 넘는 오프셋의 구간을 성긴 파일에서 보낸다.
    @Test func fileRangeBeyondFourGiB() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "sparse.bin").path
        let length: UInt64 = 5 << 30
        let offset: UInt64 = (4 << 30) + 1_000
        let marker = Array("swiftail-range-marker".utf8)
        let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        #expect(ftruncate(descriptor, off_t(length)) == 0)
        _ = marker.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
        close(descriptor)

        let finished = FinishLog()
        let server = try await startPlain(ClosureHandler { _ in
            HostResponse(status: 206, headers: [("Content-Range", "bytes \(offset)-\(offset + 29)/\(length)")],
                         body: .file(path: path, offset: offset, count: 30), onFinished: { finished.record($0, $1) })
        })
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("GET /f HTTP/1.1\r\nHost: x\r\nRange: bytes=\(offset)-\(offset + 29)\r\n\r\n")
        let response = try #require(await client.response())
        #expect(response.status == 206)
        #expect(Array(response.body.prefix(marker.count)) == marker)
        #expect(response.body.count == 30 && response.body.suffix(9).allSatisfy { $0 == 0 })
        try await waitUntil { finished.all.count == 1 }
        #expect(finished.all.first?.0 == 30 && finished.all.first?.1 == true)
    }

    @Test func rangePastEndOfFileIsNotSent() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "a.bin")
        try Data(repeating: 1, count: 100).write(to: file)
        let finished = FinishLog()
        let server = try await startPlain(ClosureHandler { _ in
            HostResponse(status: 200, body: .file(path: file.path, offset: 50, count: 100), onFinished: { finished.record($0, $1) })
        })
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try #require(await client.response()).status == 500)
        try await waitUntil { finished.all.count == 1 }
        #expect(finished.all.first?.1 == false)
    }

    /// 상대가 받는 도중 끊으면 `onFinished`는 한 번, 다 보내지 못한 것으로 불린다.
    @Test func onFinishedOnceWhenClientLeavesMidTransfer() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "big.bin").path
        let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
        #expect(ftruncate(descriptor, off_t(256 << 20)) == 0)
        close(descriptor)
        let finished = FinishLog()
        let server = try await startPlain(ClosureHandler { _ in
            HostResponse(status: 200, body: .file(path: path, offset: 0, count: 256 << 20), onFinished: { finished.record($0, $1) })
        })
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        _ = await ConnectionIO.receive(client.connection, maximum: 65_536)
        client.connection.forceCancel()
        try await waitUntil(30) { finished.all.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished.all.count == 1)
        #expect(finished.all.first?.1 == false)
        #expect((finished.all.first?.0 ?? .max) < 256 << 20)
        try await waitUntil { server.activeConnectionCount == 0 }
    }

    @Test func idleKeepAliveConnectionIsClosed() async throws {
        var limits = HTTPServerLimits()
        limits.idleTimeout = 1
        let server = try await startPlain(ClosureHandler { _ in HostResponse(status: 200) }, limits: limits)
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try #require(await client.response()).headers["connection"] == "keep-alive")
        #expect(await client.waitForClose(seconds: 6))
        try await waitUntil { server.activeConnectionCount == 0 }
    }

    @Test func stalledHeadIsCut() async throws {
        var limits = HTTPServerLimits()
        limits.headTimeout = 1
        let server = try await startPlain(ClosureHandler { _ in HostResponse(status: 200) }, limits: limits)
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("GET / HTTP/1.1\r\n")
        #expect(await client.waitForClose(seconds: 6))
    }

    @Test func keepAliveIsRefusedAboveTheConnectionCap() async throws {
        var limits = HTTPServerLimits()
        limits.keepAliveConnections = 1
        let server = try await startPlain(ClosureHandler { _ in HostResponse(status: 200) }, limits: limits)
        defer { server.close() }
        let first = try await RawClient(port: server.port)
        await first.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try #require(await first.response()).headers["connection"] == "keep-alive")
        let second = try await RawClient(port: server.port)
        await second.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try #require(await second.response()).headers["connection"] == "close")
        #expect(await second.waitForClose(seconds: 5))
    }

    @Test func requestsPerConnectionCap() async throws {
        var limits = HTTPServerLimits()
        limits.requestsPerConnection = 2
        let server = try await startPlain(ClosureHandler { _ in HostResponse(status: 200) }, limits: limits)
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try #require(await client.response()).headers["connection"] == "keep-alive")
        await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try #require(await client.response()).headers["connection"] == "close")
    }

    @Test func malformedRequestGetsErrorAndClose() async throws {
        let server = try await startPlain(ClosureHandler { _ in HostResponse(status: 200) })
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send("GET / HTTP/1.1\r\n\r\n")
        let response = try #require(await client.response())
        #expect(response.status == 400 && response.headers["connection"] == "close")
        #expect(await client.waitForClose(seconds: 5))
    }

    @Test func responseHeadersWithLineBreaksAreDropped() {
        let head = String(decoding: ResponseWriter.head(status: 200, headers: [("X-A", "1\r\nX-Injected: 2"), ("X-B", "ok")],
                                                        contentLength: 0, keepAlive: false), as: UTF8.self)
        #expect(!head.contains("X-Injected") && head.contains("X-B: ok"))
    }

    @Test func httpDateFormat() {
        #expect(HTTPDate.string(Date(timeIntervalSince1970: 784_111_777)) == "Sun, 06 Nov 1994 08:49:37 GMT")
    }

    /// 다리의 framer를 넣은 리스너에 토큰 없이 직접 건 연결은 `.ready`가 되지 못하고, 서버는 그것을 끊고 놓는다(동작 B6·B7).
    @Test func connectionWithoutBridgeTokenIsRejectedAndReleased() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // `TailnetNode.init`은 파일·소켓을 만들지 않는다. `run()`은 부르지 않는다.
        let node = try TailnetNode(configuration: NodeConfiguration(stateDirectory: directory, hostname: "rd-mac-1a2b3c4d"),
                                   device: .inProcess)
        let bridge = LoopbackBridge(node: node)
        let rejected = Mutex(0)
        let called = Mutex(0)
        let server = try await HTTPListener.start(binding: .loopback(port: 0), security: .plaintext, admission: .bridge(bridge),
                                                  handler: ClosureHandler { _ in
                                                      called.withLock { $0 += 1 }
                                                      return HostResponse(status: 200)
                                                  }) { event in
            if case .connectionRejected = event { rejected.withLock { $0 += 1 } }
        }
        defer { server.close() }
        let client = try await RawClient(port: server.port)
        await client.send(String(repeating: "x", count: 32) + "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(await client.response() == nil)
        try await waitUntil { rejected.withLock { $0 } == 1 }
        #expect(called.withLock { $0 } == 0)
        try await waitUntil { server.activeConnectionCount == 0 }
    }

    @Test func defaultPathSkipsLoopbackAndTunnelInterfaces() {
        #expect(DefaultPathFollower.choose([("utun4", .other), ("en0", .wifi)]) == 1)
        #expect(DefaultPathFollower.choose([("lo0", .loopback), ("utun0", .other)]) == nil)
        #expect(DefaultPathFollower.choose([("en7", .wiredEthernet), ("en0", .wifi)]) == 0)
        #expect(DefaultPathFollower.choose([("ipsec0", .wifi), ("en0", .wifi)]) == 1)
        #expect(DefaultPathFollower.choose([("pdp_ip0", .cellular)]) == 0)
    }
}

extension RawClient.Response: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.head == rhs.head && lhs.body == rhs.body }
}
