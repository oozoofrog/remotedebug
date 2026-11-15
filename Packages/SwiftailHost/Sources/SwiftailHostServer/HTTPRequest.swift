// 요청 머리 해석(RFC 9112 2·3·5장의 좁힌 부분집합). 요청은 모두 믿지 않는 입력이다: 크기를 묶고, 경로는 경로 표의 열쇠로만
// 쓰며 파일 시스템에 닿지 않는다.

/// 요청 하나. 이 서버는 본문이 없는 GET·HEAD만 받는다.
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET"
        case head = "HEAD"
    }

    public var method: Method
    /// 요청 대상에서 질의 문자열을 뗀 것. 퍼센트 디코딩을 하지 않는다. 경로 표와 바이트로 견주기만 한다.
    public var path: String
    /// 머리 이름은 소문자. 같은 이름이 여러 번 오면 처음 값이다(`range`·`host`처럼 두 번 오면 안 되는 것은 해석이 거절한다).
    public var headers: [String: String]

    public init(method: Method, path: String, headers: [String: String] = [:]) {
        (self.method, self.path, self.headers) = (method, path, headers)
    }
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
        case request(HTTPRequest)
        /// 이 상태 코드로 답하고 연결을 닫는다(400, 405, 414, 431, 505).
        case reject(status: Int)
    }

    /// 두 번 오면 안 되는 머리. 두 번 오면 400이다(요청 밀반입과 Range 해석의 모호함을 막는다).
    static let singletonHeaders: Set<String> = ["host", "range", "if-range", "content-length", "transfer-encoding"]

    public static func parse(_ buffer: [UInt8], limits: Limits = .standard) -> Outcome {
        let window = buffer.prefix(limits.head + 4)
        guard let headEnd = firstIndex(of: [13, 10, 13, 10], in: window) else {
            // 요청 줄이 한도를 넘었으면 414, 머리 전체가 한도를 넘었으면 431을 곧바로 낸다.
            if firstIndex(of: [13, 10], in: buffer.prefix(limits.requestLine + 2)) == nil, buffer.count > limits.requestLine {
                return .reject(status: 414)
            }
            return buffer.count > limits.head ? .reject(status: 431) : .needMore
        }
        guard headEnd <= limits.head else { return .reject(status: 431) }
        let lines = split(Array(buffer[..<headEnd]))
        guard let requestLine = lines.first else { return .reject(status: 400) }
        guard requestLine.count <= limits.requestLine else { return .reject(status: 414) }
        // 머리 줄 안에 홀로 선 CR·LF는 받지 않는다(줄 끝은 CRLF만).
        guard lines.allSatisfy({ !$0.contains(13) && !$0.contains(10) }) else { return .reject(status: 400) }

        // 요청 줄: method SP request-target SP HTTP-version. 보이는 ASCII와 SP 하나씩만.
        guard requestLine.allSatisfy({ (0x20...0x7E).contains($0) }) else { return .reject(status: 400) }
        let parts = requestLine.split(separator: 0x20, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return .reject(status: 400) }
        let methodText = String(decoding: parts[0], as: UTF8.self)
        let target = Array(parts[1])
        let version = String(decoding: parts[2], as: UTF8.self)
        guard parts[0].allSatisfy(isTokenCharacter) else { return .reject(status: 400) }
        switch version {
        case "HTTP/1.1", "HTTP/1.0": break
        default:
            return isVersionShaped(version) ? .reject(status: 505) : .reject(status: 400)
        }
        // origin-form만 받는다("/" 시작). 절대 형식, "*", 조각(#)은 400.
        guard target.first == 0x2F, !target.contains(0x23) else { return .reject(status: 400) }
        let pathBytes = target.prefix { $0 != 0x3F }
        let path = String(decoding: pathBytes, as: UTF8.self)

        var headers: [String: String] = [:]
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
            let value = String(decoding: trimOWS(rawValue), as: UTF8.self)
            if headers[key] != nil {
                if singletonHeaders.contains(key) { return .reject(status: 400) }
                continue
            }
            headers[key] = value
        }

        // HTTP/1.1은 Host가 있어야 한다(RFC 9112 3.2).
        if version == "HTTP/1.1", headers["host"] == nil { return .reject(status: 400) }
        // 본문은 받지 않는다. Transfer-Encoding이 있거나 Content-Length가 0이 아니면 400.
        if headers["transfer-encoding"] != nil { return .reject(status: 400) }
        if let length = headers["content-length"], length.isEmpty || !length.utf8.allSatisfy({ $0 == 0x30 }) {
            return .reject(status: 400)
        }

        guard let method = HTTPRequest.Method(rawValue: methodText) else { return .reject(status: 405) }
        return .request(HTTPRequest(method: method, path: path, headers: headers))
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
