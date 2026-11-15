import Foundation

// 요청 머리 해석(RFC 9112 2·3·5·6장의 좁힌 부분집합). 요청은 모두 믿지 않는 입력이다: 크기를 묶고, 대상은 로직에 그대로
// 넘기되 파일 시스템에는 닿지 않는다.

/// 요청 머리 하나. 본문은 `contentLength`만큼 머리 뒤에 온다.
public struct HTTPRequestHead: Sendable, Equatable {
    /// 대문자 메서드 그대로(토큰 문자만).
    public var method: String
    /// 요청 대상 그대로(origin-form, 질의 문자열 포함). 퍼센트 디코딩을 하지 않는다.
    public var target: String
    /// 받은 순서의 머리. 이름은 소문자, 값은 앞뒤 공백을 뗀 것.
    public var headers: [HTTPField]
    /// `Content-Length`. 없으면 0.
    public var contentLength: UInt64
    /// 이 요청 뒤에 연결을 이어 쓰자고 했는가(HTTP/1.1 기본은 참, `Connection: close`면 거짓. HTTP/1.0은 `keep-alive`일 때만).
    public var keepAlive: Bool

    public init(method: String, target: String, headers: [HTTPField], contentLength: UInt64 = 0, keepAlive: Bool = true) {
        (self.method, self.target, self.headers) = (method, target, headers)
        (self.contentLength, self.keepAlive) = (contentLength, keepAlive)
    }

    /// 소문자 이름으로 첫 값을 찾는다.
    public func header(_ name: String) -> String? {
        headers.first { $0.name == name }?.value
    }

    /// 대상에서 질의 문자열을 뗀 경로.
    public var path: String {
        String(target.prefix { $0 != "?" })
    }
}

public struct HTTPField: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) { (self.name, self.value) = (name, value) }
}

/// 받은 바이트에서 요청 머리 하나를 읽는다. 소켓을 모른다.
public enum HTTPRequestParser {
    /// 머리의 한도.
    public struct Limits: Sendable, Equatable {
        /// 요청 줄(CRLF 제외). 넘으면 414.
        public var requestLine: Int
        /// 머리 한 줄(CRLF 제외). 넘으면 431.
        public var headerLine: Int
        /// 머리 줄 수. 넘으면 431.
        public var headerCount: Int
        /// 요청 줄부터 빈 줄까지 전체. 넘으면 431.
        public var head: Int

        public static let standard = Limits(requestLine: 8_192, headerLine: 8_192, headerCount: 64, head: 16_384)

        public init(requestLine: Int, headerLine: Int, headerCount: Int, head: Int) {
            (self.requestLine, self.headerLine, self.headerCount, self.head) = (requestLine, headerLine, headerCount, head)
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// 머리가 아직 다 오지 않았다. 더 받아서 처음부터 다시 부른다.
        case needMore
        /// 머리와 그것이 차지한 바이트 수(빈 줄의 CRLF까지). 그 뒤는 본문이나 다음 요청이다.
        case request(HTTPRequestHead, consumed: Int)
        /// 이 상태 코드로 답하고 연결을 닫는다(400, 411, 414, 431, 501, 505).
        case reject(status: Int)
    }

    /// 두 번 오면 안 되는 머리. 두 번 오면 400이다(요청 밀반입과 Range 해석의 모호함을 막는다).
    static let singletonHeaders: Set<String> = ["host", "range", "if-range", "content-length", "transfer-encoding"]

    /// 시작 전 빈 줄(CRLF)은 몇 개까지 건너뛴다(RFC 9112 2.2).
    static let leadingEmptyLines = 4

    public static func parse(_ buffer: [UInt8], limits: Limits = .standard) -> Outcome {
        // 요청 사이의 빈 줄을 건너뛴다.
        var start = 0
        var skipped = 0
        while skipped < leadingEmptyLines, buffer.count >= start + 2, buffer[start] == 13, buffer[start + 1] == 10 {
            start += 2
            skipped += 1
        }
        let body = buffer[start...]
        let window = body.prefix(limits.head + 4)
        guard let relativeEnd = firstIndex(of: [13, 10, 13, 10], in: window) else {
            // 요청 줄이 한도를 넘었으면 414, 머리 전체가 한도를 넘었으면 431을 곧바로 낸다.
            if firstIndex(of: [13, 10], in: body.prefix(limits.requestLine + 2)) == nil, body.count > limits.requestLine {
                return .reject(status: 414)
            }
            return body.count > limits.head ? .reject(status: 431) : .needMore
        }
        guard relativeEnd <= limits.head else { return .reject(status: 431) }
        let headBytes = Array(body.prefix(relativeEnd))
        let consumed = start + relativeEnd + 4
        let lines = split(headBytes)
        guard let requestLine = lines.first else { return .reject(status: 400) }
        guard requestLine.count <= limits.requestLine else { return .reject(status: 414) }
        // 머리 줄 안에 홀로 선 CR·LF는 받지 않는다(줄 끝은 CRLF만).
        guard lines.allSatisfy({ !$0.contains(13) && !$0.contains(10) }) else { return .reject(status: 400) }

        // 요청 줄: method SP request-target SP HTTP-version. 보이는 ASCII와 SP 하나씩만.
        guard requestLine.allSatisfy({ (0x20...0x7E).contains($0) }) else { return .reject(status: 400) }
        let parts = requestLine.split(separator: 0x20, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return .reject(status: 400) }
        guard parts[0].allSatisfy(isTokenCharacter) else { return .reject(status: 400) }
        let method = String(decoding: parts[0], as: UTF8.self)
        let target = Array(parts[1])
        let version = String(decoding: parts[2], as: UTF8.self)
        switch version {
        case "HTTP/1.1", "HTTP/1.0": break
        default:
            return isVersionShaped(version) ? .reject(status: 505) : .reject(status: 400)
        }
        // origin-form만 받는다("/" 시작). 절대 형식, "*", 조각(#)은 400.
        guard target.first == 0x2F, !target.contains(0x23) else { return .reject(status: 400) }

        var headers: [HTTPField] = []
        let headerLines = lines.dropFirst()
        guard headerLines.count <= limits.headerCount else { return .reject(status: 431) }
        for line in headerLines {
            guard line.count <= limits.headerLine else { return .reject(status: 431) }
            // obs-fold(공백으로 시작하는 이어진 줄)는 받지 않는다(RFC 9112 5.2).
            guard let colon = line.firstIndex(of: 0x3A), colon > 0 else { return .reject(status: 400) }
            let name = line[..<colon]
            guard name.allSatisfy(isTokenCharacter) else { return .reject(status: 400) }
            let rawValue = line[(colon + 1)...]
            // 값: HTAB, SP, 보이는 ASCII, obs-text. 그 밖의 제어 문자(NUL 포함)는 400.
            guard rawValue.allSatisfy({ $0 == 0x09 || $0 >= 0x20 && $0 != 0x7F }) else { return .reject(status: 400) }
            let key = String(decoding: name, as: UTF8.self).lowercased()
            if singletonHeaders.contains(key), headers.contains(where: { $0.name == key }) { return .reject(status: 400) }
            headers.append(HTTPField(name: key, value: String(decoding: trimOWS(rawValue), as: UTF8.self)))
        }
        let find = { (name: String) in headers.first { $0.name == name }?.value }

        // HTTP/1.1은 Host가 있어야 한다(RFC 9112 3.2).
        if version == "HTTP/1.1", find("host") == nil { return .reject(status: 400) }
        // 본문은 Content-Length로만 받는다. chunked는 411(길이를 달라), 그 밖의 전송 코딩은 501(RFC 9112 6.1).
        if let coding = find("transfer-encoding") {
            let last = coding.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return .reject(status: last == "chunked" ? 411 : 501)
        }
        var contentLength: UInt64 = 0
        if let text = find("content-length") {
            guard !text.isEmpty, text.utf8.count <= 19, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let value = UInt64(text) else { return .reject(status: 400) }
            contentLength = value
        }
        let connection = (find("connection") ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let keepAlive = version == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
        return .request(HTTPRequestHead(method: method, target: String(decoding: target, as: UTF8.self), headers: headers,
                                        contentLength: contentLength, keepAlive: keepAlive), consumed: consumed)
    }

    // MARK: - 바이트 도우미

    static func firstIndex(of needle: [UInt8], in haystack: some Collection<UInt8>) -> Int? {
        let bytes = Array(haystack)
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count) where bytes[start] == needle[0] {
            if bytes[start..<(start + needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }

    /// CRLF로 나눈다(마지막 CRLF 없이 끝나는 머리).
    private static func split(_ head: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        var index = 0
        while index < head.count {
            if head[index] == 13, index + 1 < head.count, head[index + 1] == 10 {
                lines.append(current)
                current = []
                index += 2
            } else {
                current.append(head[index])
                index += 1
            }
        }
        lines.append(current)
        return lines
    }

    private static func trimOWS(_ value: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var slice = value
        while let first = slice.first, first == 0x20 || first == 0x09 { slice = slice.dropFirst() }
        while let last = slice.last, last == 0x20 || last == 0x09 { slice = slice.dropLast() }
        return slice
    }

    /// RFC 9110 5.6.2 tchar.
    static func isTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        case UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"), UInt8(ascii: "&"),
             UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."),
             UInt8(ascii: "^"), UInt8(ascii: "_"), UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"): true
        default: false
        }
    }

    /// `HTTP/숫자.숫자` 꼴이면 버전만 다른 것이다(505).
    private static func isVersionShaped(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 8, text.hasPrefix("HTTP/") else { return false }
        return (0x30...0x39).contains(bytes[5]) && bytes[6] == 0x2E && (0x30...0x39).contains(bytes[7])
    }
}
