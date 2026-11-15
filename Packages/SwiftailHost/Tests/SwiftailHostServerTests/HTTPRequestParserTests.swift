import Testing

@testable import SwiftailHostServer

@Suite("요청 머리 해석")
struct HTTPRequestParserTests {
    private func parse(_ text: String, limits: HTTPRequestParser.Limits = .standard) -> HTTPRequestParser.Outcome {
        HTTPRequestParser.parse(Array(text.utf8), limits: limits)
    }

    private func head(_ text: String) -> HTTPRequestHead? {
        if case .request(let head, _) = parse(text) { head } else { nil }
    }

    @Test func targetQueryAndHeaderOrder() throws {
        let text = "GET /v1/builds?x=1&y=%2F HTTP/1.1\r\nHost: a\r\nX-B: 2\r\nx-a:  1 \r\nX-B: 3\r\n\r\n"
        guard case .request(let head, let consumed) = parse(text) else { Issue.record("요청이 아님"); return }
        #expect(consumed == text.utf8.count)
        #expect(head.method == "GET")
        #expect(head.target == "/v1/builds?x=1&y=%2F")
        #expect(head.path == "/v1/builds")
        #expect(head.headers.map(\.name) == ["host", "x-b", "x-a", "x-b"])
        #expect(head.headers.map(\.value) == ["a", "2", "1", "3"])
        #expect(head.keepAlive && head.contentLength == 0)
    }

    @Test func methodsAreNotFilteredByTheTransport() {
        for method in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"] {
            #expect(head("\(method) / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n")?.method == method)
        }
    }

    @Test func contentLengthAndPipelining() {
        let first = "POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\n"
        guard case .request(let head, let consumed) = parse(first + "hello" + "GET /b HTTP/1.1\r\nHost: a\r\n\r\n") else {
            Issue.record("요청이 아님")
            return
        }
        #expect(head.contentLength == 5)
        #expect(consumed == first.utf8.count)
    }

    @Test func bodyFramingRejections() {
        #expect(parse("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n") == .reject(status: 411))
        #expect(parse("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\n\r\n") == .reject(status: 411))
        #expect(parse("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\n\r\n") == .reject(status: 501))
        #expect(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n") == .reject(status: 400))
        #expect(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1, 1\r\n\r\n") == .reject(status: 400))
        #expect(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n") == .reject(status: 400))
        #expect(parse("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 99999999999999999999\r\n\r\n") == .reject(status: 400))
    }

    @Test func keepAliveRules() {
        #expect(head("GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n")?.keepAlive == false)
        #expect(head("GET / HTTP/1.1\r\nHost: a\r\nConnection: Keep-Alive, Upgrade\r\n\r\n")?.keepAlive == true)
        #expect(head("GET / HTTP/1.0\r\n\r\n")?.keepAlive == false)
        #expect(head("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")?.keepAlive == true)
    }

    @Test func leadingEmptyLinesAreSkipped() {
        guard case .request(let head, let consumed) = parse("\r\n\r\nGET / HTTP/1.1\r\nHost: a\r\n\r\n") else {
            Issue.record("요청이 아님")
            return
        }
        #expect(head.target == "/" && consumed == 4 + 27)
    }

    @Test func incompleteHeadNeedsMore() {
        #expect(parse("") == .needMore)
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n") == .needMore)
    }

    @Test func requestLineLimit() {
        let limits = HTTPRequestParser.Limits(requestLine: 32, headerLine: 64, headerCount: 4, head: 256)
        #expect(parse("GET /\(String(repeating: "a", count: 40)) HTTP/1.1\r\nHost: a\r\n\r\n", limits: limits) == .reject(status: 414))
        // 줄 끝이 오기 전에도 한도를 넘으면 곧바로 414.
        #expect(parse("GET /\(String(repeating: "a", count: 40))", limits: limits) == .reject(status: 414))
    }

    @Test func headerLimits() {
        let limits = HTTPRequestParser.Limits(requestLine: 64, headerLine: 32, headerCount: 2, head: 128)
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nX: \(String(repeating: "b", count: 40))\r\n\r\n", limits: limits) == .reject(status: 431))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nA: 1\r\nB: 2\r\n\r\n", limits: limits) == .reject(status: 431))
        #expect(parse("GET / HTTP/1.1\r\n" + String(repeating: "X: 1\r\n", count: 40), limits: limits) == .reject(status: 431))
    }

    @Test func malformedInputIsRejected() {
        #expect(parse("GET / HTTP/1.1\r\n\r\n") == .reject(status: 400))  // Host 없음
        #expect(parse("GET  / HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET http://a/ HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET /#x HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nX: a\u{0}b\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\nX: 1\r\n\r\n") == .reject(status: 400))
        #expect(parse("G(T / HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / HTTP/2.0\r\nHost: a\r\n\r\n") == .reject(status: 505))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nRange: bytes=0-1\r\nRange: bytes=2-3\r\n\r\n") == .reject(status: 400))
    }
}
