import Darwin
import Foundation
import Network
import RDHostLogic
import Synchronization

/// HTTP/1.1 서버 한 리스너의 한도. 시간은 초.
public struct HTTPServerLimits: Sendable {
    /// 받은 연결이 `.ready`가 되기까지(다리 framer의 토큰 5초 + TLS 핸드셰이크).
    public var readyTimeout: Double = 20
    /// 요청의 첫 바이트부터 머리가 다 오기까지.
    public var headTimeout: Double = 20
    /// 응답을 다 보낸 뒤 다음 요청을 기다리는 시간(keep-alive 유휴).
    public var idleTimeout: Double = 30
    /// 본문을 받거나 응답을 보내는 동안 진전이 없어도 되는 시간.
    public var progressTimeout: Double = 60
    /// 이 리스너의 열린 연결이 이 수를 넘으면 응답에 `Connection: close`를 붙여 유휴 연결을 남기지 않는다.
    /// 다리의 상한(256)보다 한참 낮게 둔다: 유휴 연결이 새 연결을 막지 않게 한다.
    public var keepAliveConnections: Int = 48
    /// 연결 하나에서 받는 요청 수.
    public var requestsPerConnection: Int = 1_000
    /// 받는 본문의 상한. 넘으면 413으로 답하고 닫는다. 경로별 한도는 로직이 정한다.
    public var requestBody: UInt64 = 1 << 30
    /// 로직이 읽지 않고 남긴 본문을 이만큼까지는 읽어 버리고 연결을 이어 쓴다. 넘으면 응답 뒤 닫는다.
    public var drainBody: UInt64 = 65_536
    public var parser: HTTPRequestParser.Limits = .standard

    public init() {}
}

/// NWConnection 하나로 HTTP/1.1 요청을 차례로 받아 로직에 넘기고 응답을 보낸다. 상대 확인은 부른 쪽이 끝냈다.
///
/// 접점(`RDHostLogic/HostHTTP.swift`)의 전송 쪽 몫: 머리 이름을 소문자로 넘기고, `Content-Length`·`Connection`·`Date`를
/// 붙이고, `HEAD`는 본문을 빼고, chunked 요청 본문은 411로 거절하고, `onFinished`를 한 번 부른다.
enum HTTPConnectionServer {
    static let sendChunk = 262_144
    static let receiveChunk = 65_536

    /// 연결이 끝나면 돌아온다. 연결을 닫고 놓는 일은 부른 쪽이 한다.
    static func serve(_ connection: NWConnection, origin: HostOrigin, handler: any HostRequestHandling, limits: HTTPServerLimits,
                      watchdog: Watchdog, openConnections: @escaping @Sendable () -> Int) async {
        var buffer: [UInt8] = []
        var served = 0
        watchdog.extend(seconds: limits.idleTimeout)
        while true {
            // 머리.
            var outcome = HTTPRequestParser.parse(buffer, limits: limits.parser)
            while outcome == .needMore {
                guard case .bytes(let more) = await ConnectionIO.receive(connection, maximum: receiveChunk) else { return }
                if buffer.isEmpty { watchdog.extend(seconds: limits.headTimeout) }
                buffer += more
                outcome = HTTPRequestParser.parse(buffer, limits: limits.parser)
            }
            watchdog.extend(seconds: limits.progressTimeout)
            let head: HTTPRequestHead
            switch outcome {
            case .needMore:
                return
            case .reject(let status):
                await ResponseWriter.sendError(connection, status: status, watchdog: watchdog)
                return
            case .request(let parsed, let consumed):
                head = parsed
                buffer.removeFirst(consumed)
            }
            if head.contentLength > limits.requestBody {
                await ResponseWriter.sendError(connection, status: 413, watchdog: watchdog)
                return
            }

            // 본문: 이미 받은 바이트에서 본문 몫을 떼고, 나머지(다음 요청)는 버퍼에 남긴다.
            let inBuffer = Int(min(UInt64(buffer.count), head.contentLength))
            let pending = Array(buffer.prefix(inBuffer))
            buffer.removeFirst(inBuffer)
            let reader = ConnectionBodyReader(connection: connection, pending: pending,
                                              remaining: head.contentLength - UInt64(inBuffer), watchdog: watchdog,
                                              progressTimeout: limits.progressTimeout)
            let request = HostRequest(method: head.method, target: head.target,
                                      headers: head.headers.map { (name: $0.name, value: $0.value) },
                                      body: head.contentLength > 0 ? reader : nil, contentLength: head.contentLength,
                                      origin: origin)
            // 로직이 도는 동안은 기한을 멈춘다(본문을 읽을 때만 진전 기한이 선다).
            watchdog.pause()
            let response = await handler.handle(request)
            watchdog.extend(seconds: limits.progressTimeout)
            reader.close()

            // 남은 본문: 작으면 읽어 버리고, 크면 응답 뒤 닫는다.
            var bodyIntact = true
            let unread = reader.unreadCount
            if unread > 0 {
                if unread <= limits.drainBody {
                    bodyIntact = await reader.drain()
                } else {
                    bodyIntact = false
                }
            }
            served += 1
            let keepAlive = head.keepAlive && bodyIntact && served < limits.requestsPerConnection
                && openConnections() <= limits.keepAliveConnections
            let sent = await ResponseWriter.send(response, to: connection, isHead: head.method == "HEAD", keepAlive: keepAlive,
                                                 watchdog: watchdog, progressTimeout: limits.progressTimeout)
            guard sent, keepAlive else {
                if sent { await ResponseWriter.closeGracefully(connection, watchdog: watchdog) }
                return
            }
            watchdog.extend(seconds: limits.idleTimeout)
        }
    }
}

/// 요청 본문을 연결에서 읽는다. `Content-Length`를 넘겨 읽지 않는다(다음 요청의 바이트는 연결에 남는다).
final class ConnectionBodyReader: HostBodyReader, Sendable {
    enum Failure: Error, Equatable {
        /// 본문이 다 오기 전에 연결이 끝났다.
        case truncated
        /// 같은 본문을 둘이 함께 읽으려 했다.
        case concurrentRead
        /// 로직의 처리가 끝난 뒤의 읽기.
        case closed
    }

    private struct State {
        var pending: [UInt8]
        var remaining: UInt64
        var reading = false
        var closed = false
        var failed = false
    }

    private let connection: NWConnection
    private let watchdog: Watchdog
    private let progressTimeout: Double
    private let state: Mutex<State>

    init(connection: NWConnection, pending: [UInt8], remaining: UInt64, watchdog: Watchdog, progressTimeout: Double) {
        self.connection = connection
        self.watchdog = watchdog
        self.progressTimeout = progressTimeout
        state = Mutex(State(pending: pending, remaining: remaining))
    }

    /// 아직 읽지 않은 본문 바이트(연결에서 받지 않은 것 포함). 읽기가 실패했으면 큰 값이다(연결을 이어 쓰지 않는다).
    var unreadCount: UInt64 {
        state.withLock { $0.failed ? .max : UInt64($0.pending.count) + $0.remaining }
    }

    func read(upTo count: Int) async throws -> [UInt8]? {
        guard count > 0 else { return [] }
        enum Step { case give([UInt8]), end, fetch(Int) }
        let step = try state.withLock { value throws -> Step in
            if value.closed { throw Failure.closed }
            if value.reading { throw Failure.concurrentRead }
            if value.failed { throw Failure.truncated }
            if !value.pending.isEmpty {
                let chunk = Array(value.pending.prefix(count))
                value.pending.removeFirst(chunk.count)
                return .give(chunk)
            }
            if value.remaining == 0 { return .end }
            value.reading = true
            return .fetch(Int(min(UInt64(min(count, HTTPConnectionServer.receiveChunk)), value.remaining)))
        }
        switch step {
        case .give(let chunk): return chunk
        case .end: return nil
        case .fetch(let maximum):
            watchdog.extend(seconds: progressTimeout)
            let received = await ConnectionIO.receive(connection, maximum: maximum)
            watchdog.pause()
            return try state.withLock { value throws -> [UInt8]? in
                value.reading = false
                guard case .bytes(let bytes) = received, !bytes.isEmpty else {
                    value.failed = true
                    throw Failure.truncated
                }
                value.remaining -= UInt64(bytes.count)
                return bytes
            }
        }
    }

    /// 로직이 돌려준 뒤에는 읽지 못하게 한다.
    func close() {
        state.withLock { $0.closed = true }
    }

    /// 남은 본문을 읽어 버린다. 다 읽었으면 참.
    func drain() async -> Bool {
        state.withLock { $0.pending = [] }
        while true {
            let remaining = state.withLock { $0.remaining }
            if remaining == 0 { return true }
            let received = await ConnectionIO.receive(connection, maximum: Int(min(remaining, UInt64(HTTPConnectionServer.receiveChunk))))
            guard case .bytes(let bytes) = received, !bytes.isEmpty else {
                state.withLock { $0.failed = true }
                return false
            }
            state.withLock { $0.remaining -= UInt64(bytes.count) }
        }
    }
}

/// 응답 보내기.
enum ResponseWriter {
    static let reasons: [Int: String] = [
        100: "Continue", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
        301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        409: "Conflict", 410: "Gone", 421: "Misdirected Request", 411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large",
        414: "URI Too Long", 415: "Unsupported Media Type", 416: "Range Not Satisfiable", 422: "Unprocessable Content",
        429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
        501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable", 505: "HTTP Version Not Supported",
    ]

    /// 전송이 붙이는 머리. 로직이 넣었으면 빼고 전송의 값을 쓴다.
    static let transportHeaders: Set<String> = ["content-length", "connection", "date", "transfer-encoding", "keep-alive"]

    /// 본문이 없어야 하는 상태(RFC 9110 6.4.1).
    static func forbidsBody(_ status: Int) -> Bool {
        (100..<200).contains(status) || status == 204 || status == 304
    }

    static func head(status: Int, headers: [(name: String, value: String)], contentLength: UInt64, keepAlive: Bool,
                     date: Date = Date()) -> [UInt8] {
        var lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Status")"]
        for header in headers where !transportHeaders.contains(header.name.lowercased()) {
            // 이름은 토큰 문자만, 값에는 CR·LF·NUL이 없어야 한다(바이트로 본다. "\r\n"은 Character 하나다).
            guard !header.name.isEmpty, header.name.utf8.allSatisfy(HTTPRequestParser.isTokenCharacter),
                  !header.value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }) else { continue }
            lines.append("\(header.name): \(header.value)")
        }
        if !forbidsBody(status) { lines.append("Content-Length: \(contentLength)") }
        lines.append("Date: \(HTTPDate.string(date))")
        lines.append("Connection: \(keepAlive ? "keep-alive" : "close")")
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// 전송이 만든 오류 응답(본문 없음)을 보내고 닫는다.
    static func sendError(_ connection: NWConnection, status: Int, watchdog: Watchdog) async {
        guard await ConnectionIO.send(connection, head(status: status, headers: [], contentLength: 0, keepAlive: false)) else { return }
        await closeGracefully(connection, watchdog: watchdog)
    }

    /// 응답을 보낸다. 다 보냈으면 참. `onFinished`는 어느 길이든 한 번 부른다.
    static func send(_ response: HostResponse, to connection: NWConnection, isHead: Bool, keepAlive: Bool, watchdog: Watchdog,
                     progressTimeout: Double) async -> Bool {
        let finished = FinishOnce(response.onFinished)
        defer { finished.call(0, false) }
        let noBody = forbidsBody(response.status)
        switch response.body {
        case .none:
            guard await ConnectionIO.send(connection, head(status: response.status, headers: response.headers, contentLength: 0,
                                                           keepAlive: keepAlive)) else { return false }
            finished.call(0, true)
            return true
        case .bytes(let bytes):
            let body = noBody ? [] : bytes
            let headBytes = head(status: response.status, headers: response.headers, contentLength: UInt64(body.count),
                                 keepAlive: keepAlive)
            guard await ConnectionIO.send(connection, isHead ? headBytes : headBytes + body) else { return false }
            finished.call(isHead ? 0 : UInt64(body.count), true)
            return true
        case .file(let path, let offset, let count):
            let source: FileSource
            do {
                source = try FileSource(path: path)
            } catch {
                _ = await ConnectionIO.send(connection, head(status: 500, headers: [], contentLength: 0, keepAlive: false))
                return false
            }
            let (end, overflow) = offset.addingReportingOverflow(count)
            guard !overflow, end <= source.length else {
                _ = await ConnectionIO.send(connection, head(status: 500, headers: [], contentLength: 0, keepAlive: false))
                return false
            }
            let length = noBody ? 0 : count
            guard await ConnectionIO.send(connection, head(status: response.status, headers: response.headers,
                                                           contentLength: length, keepAlive: keepAlive)) else { return false }
            if isHead || length == 0 {
                finished.call(0, true)
                return true
            }
            var sent: UInt64 = 0
            while sent < length {
                watchdog.extend(seconds: progressTimeout)
                let size = Int(min(UInt64(HTTPConnectionServer.sendChunk), length - sent))
                guard let chunk = try? source.read(at: offset + sent, count: size) else {
                    finished.call(sent, false)
                    return false
                }
                guard await ConnectionIO.send(connection, chunk) else {
                    finished.call(sent, false)
                    return false
                }
                sent += UInt64(size)
            }
            finished.call(sent, true)
            return true
        }
    }

    /// 쓰기를 닫고(TLS는 close_notify) 상대가 닫기를 잠깐 기다린다. 마지막 바이트가 RST에 잘리지 않게 한다.
    static func closeGracefully(_ connection: NWConnection, watchdog: Watchdog) async {
        guard await ConnectionIO.send(connection, [], final: true) else { return }
        watchdog.extend(seconds: 2)
        while case .bytes = await ConnectionIO.receive(connection, maximum: HTTPConnectionServer.receiveChunk) {}
    }
}

/// `onFinished`를 한 번만 부른다.
final class FinishOnce: Sendable {
    private let callback: Mutex<(@Sendable (UInt64, Bool) -> Void)?>

    init(_ callback: (@Sendable (UInt64, Bool) -> Void)?) { self.callback = Mutex(callback) }

    func call(_ sent: UInt64, _ completed: Bool) {
        callback.withLock { value in
            defer { value = nil }
            return value
        }?(sent, completed)
    }
}

/// RFC 9110 5.6.7 IMF-fixdate.
enum HTTPDate {
    private static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func string(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%@, %02d %@ %04d %02d:%02d:%02d GMT", days[Int(parts.tm_wday)], parts.tm_mday,
                      months[Int(parts.tm_mon)], parts.tm_year + 1900, parts.tm_hour, parts.tm_min, parts.tm_sec)
    }
}

// MARK: - NWConnection의 비동기 감싸개

enum ConnectionIO {
    enum Received: Sendable, Equatable { case bytes([UInt8]), end }

    /// `.ready`가 되면 참. 준비 전에 `.failed`·`.cancelled`·`.waiting`이면 거짓.
    static func ready(_ connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "swiftail-host.connection")) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Mutex<CheckedContinuation<Bool, Never>?>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.withLock { $0.take() }?.resume(returning: true)
                case .failed, .cancelled, .waiting: once.withLock { $0.take() }?.resume(returning: false)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    static func receive(_ connection: NWConnection, maximum: Int) async -> Received {
        await withCheckedContinuation { (continuation: CheckedContinuation<Received, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, maximum)) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: .bytes([UInt8](data))) }
                else if error != nil || isComplete { continuation.resume(returning: .end) }
                else { continuation.resume(returning: .bytes([])) }
            }
        }
    }

    /// 보내고 네트워크 스택이 받아 갈 때까지 기다린다. 실패하면 거짓. `final`이면 쓰기 방향을 닫는다.
    static func send(_ connection: NWConnection, _ bytes: [UInt8], final: Bool = false) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: bytes.isEmpty ? nil : Data(bytes), contentContext: final ? .finalMessage : .defaultMessage,
                            isComplete: true, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}

/// 기한이 지나면 연결을 끊는다. 진전이 있을 때마다 `extend`로 기한을 민다. 끊긴 연결의 받기·보내기는 곧바로 끝난다.
final class Watchdog: Sendable {
    private let deadline: Mutex<ContinuousClock.Instant?>
    private let task: Mutex<Task<Void, Never>?>

    init(connection: NWConnection, seconds: Double) {
        deadline = Mutex(.now + .milliseconds(Int(seconds * 1000)))
        task = Mutex(nil)
        let watched = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if let limit = self.deadline.withLock({ $0 }), ContinuousClock.now > limit {
                    connection.cancel()
                    return
                }
            }
        }
        task.withLock { $0 = watched }
    }

    func extend(seconds: Double) {
        deadline.withLock { $0 = .now + .milliseconds(Int(seconds * 1000)) }
    }

    /// 기한을 멈춘다(로직이 도는 동안).
    func pause() {
        deadline.withLock { $0 = nil }
    }

    func stop() {
        task.withLock { $0?.cancel() }
    }
}

/// 받은 연결의 목록. 끝난 연결은 `cancel()`하고 참조를 놓는다(준비되지 않고 끝난 연결의 소켓은 놓아야 닫힌다. 동작 B7).
final class ConnectionRegistry: Sendable {
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])

    var count: Int { connections.withLock { $0.count } }

    func add(_ connection: NWConnection) {
        connections.withLock { $0[ObjectIdentifier(connection)] = connection }
    }

    func remove(_ connection: NWConnection) {
        connection.cancel()
        connection.stateUpdateHandler = nil
        _ = connections.withLock { $0.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    func cancelAll() {
        let open = connections.withLock { Array($0.values) }
        for connection in open { connection.cancel() }
    }
}
