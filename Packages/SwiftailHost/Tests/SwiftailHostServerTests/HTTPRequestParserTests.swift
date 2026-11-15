import Testing

@testable import SwiftailHostServer

@Suite("요청 머리 해석")
struct HTTPRequestParserTests {
    private func parse(_ text: String, limits: HTTPRequestParser.Limits = .standard) -> HTTPRequestParser.Outcome {
        HTTPRequestParser.parse(Array(text.utf8), limits: limits)
    }

    @Test func getWithQueryAndHeaders() {
        let outcome = parse("GET /file?x=1 HTTP/1.1\r\nHost: example\r\nRange:  bytes=0-9 \r\n\r\n")
        #expect(outcome == .request(HTTPRequest(method: .get, path: "/file", headers: ["host": "example", "range": "bytes=0-9"])))
    }

    @Test func headAndHTTP10WithoutHost() {
        #expect(parse("HEAD / HTTP/1.0\r\n\r\n") == .request(HTTPRequest(method: .head, path: "/")))
    }

    @Test func incompleteHeadNeedsMore() {
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n") == .needMore)
        #expect(parse("") == .needMore)
    }

    @Test func requestLineLimit() {
        let limits = HTTPRequestParser.Limits(requestLine: 32, headerLine: 64, headerCount: 4, head: 256)
        let long = "GET /" + String(repeating: "a", count: 40)
        // 줄 끝이 오기 전이라도 한도를 넘으면 곧바로 414.
        #expect(parse(long, limits: limits) == .reject(status: 414))
        #expect(parse(long + " HTTP/1.1\r\nHost: a\r\n\r\n", limits: limits) == .reject(status: 414))
    }

    @Test func headerLimits() {
        let limits = HTTPRequestParser.Limits(requestLine: 64, headerLine: 32, headerCount: 2, head: 128)
        #expect(parse("GET / HTTP/1.1\r\nHost: " + String(repeating: "b", count: 40) + "\r\n\r\n", limits: limits) == .reject(status: 431))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nA: 1\r\nB: 2\r\n\r\n", limits: limits) == .reject(status: 431))
        // 빈 줄이 오지 않은 채 전체 한도를 넘었다.
        #expect(parse("GET / HTTP/1.1\r\n" + String(repeating: "X: y\r\n", count: 30), limits: limits) == .reject(status: 431))
    }

    @Test func malformedInputIsRejected() {
        #expect(parse("GET / HTTP/1.1\r\n\r\n") == .reject(status: 400))  // Host 없음
        #expect(parse("GET  / HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 400))  // 빈 칸 둘
        #expect(parse("GET http://a/ HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 400))  // 절대 형식
        #expect(parse("GET * HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET /#x HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n") == .reject(status: 400))  // obs-fold
        #expect(parse("GET / HTTP/1.1\r\nHost : a\r\n\r\n") == .reject(status: 400))  // 이름 뒤 공백
        #expect(parse("GET / HTTP/1.1\r\nHost: a\u{0}b\r\n\r\n") == .reject(status: 400))  // NUL
        #expect(parse("GET / HTTP/1.1\r\nHost: a\nX: b\r\n\r\n") == .reject(status: 400))  // 홀로 선 LF
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nRange: bytes=0-1\r\nRange: bytes=2-3\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / FOO\r\nHost: a\r\n\r\n") == .reject(status: 400))
    }

    @Test func versionMethodAndBody() {
        #expect(parse("GET / HTTP/2.0\r\nHost: a\r\n\r\n") == .reject(status: 505))
        #expect(parse("POST / HTTP/1.1\r\nHost: a\r\n\r\n") == .reject(status: 405))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello") == .reject(status: 400))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n") == .reject(status: 400))
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n") == .request(
            HTTPRequest(method: .get, path: "/", headers: ["host": "a", "content-length": "0"])))
    }

    @Test func pathNeverDecodedOrResolved() {
        // 경로는 표의 열쇠일 뿐이다: 풀거나 정규화하지 않으므로 표에 없는 경로가 된다.
        let content = ServedContent(filePath: "/x", app: nil)
        for path in ["/../file", "/file/", "/%66ile", "//file", "/FILE"] {
            #expect(HostRouter.route(for: path, content: content) == nil)
        }
        #expect(HostRouter.route(for: "/file", content: content) == .file)
    }
}
