#if RD_SWIFTAIL_TUNNEL
import Foundation
import Network

/// 시험 빌드 전용: Mac의 tailnet 주소(설치 페이지)를 1초마다 불러, 성공과 실패가 바뀌는 시각을 기기 로그에 남긴다.
/// 주소가 tailnet 이름이라 요청은 터널을 지난다. 설치 페이지는 접속자를 확인하지 않으므로 페어링이 없어도 응답한다.
@MainActor
final class TunnelProbe {
    static let shared = TunnelProbe()
    private var task: Task<Void, Never>?

    func set(on: Bool, fqdn: String?, log: @escaping @MainActor (String) -> Void) {
        task?.cancel()
        task = nil
        guard on, let fqdn, let url = URL(string: "https://\(fqdn)/") else {
            log("탐침 끔")
            return
        }
        log("탐침 켬")
        task = Task {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            // 요청마다 새 연결을 맺어, 살아 있던 연결 덕에 성공으로 보이지 않게 한다.
            configuration.httpMaximumConnectionsPerHost = 1
            var wasUp: Bool?
            var changed = Date()
            var count = 0
            while !Task.isCancelled {
                let session = URLSession(configuration: configuration)
                let started = Date()
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                let up = (try? await session.data(for: request)) != nil
                session.invalidateAndCancel()
                let took = Date().timeIntervalSince(started)
                count += 1
                if up != wasUp {
                    let since = Date().timeIntervalSince(changed)
                    log(String(format: "탐침 %@ (요청 %.2f초, 앞 상태 %.1f초 유지, %d번째)", up ? "성공" : "실패", took, since, count))
                    wasUp = up
                    changed = Date()
                } else if !up {
                    log(String(format: "탐침 실패 계속 (요청 %.2f초, %d번째)", took, count))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// 시험 빌드 전용: `https://<호스트>/file`을 받아 버리면서 걸린 시간, 속도, 덩어리 사이의 가장 긴 간격(멈춤)을 기기 로그에 남긴다.
/// Swiftail 호스트 관문의 전송 측정에 쓴다. 상대가 Let's Encrypt 스테이징 인증서를 써서 `URLSession`은 ATS에 막히므로
/// (-1200) `NWConnection`으로 직접 요청하고 **이 연결만** 서버 검증을 건너뛴다. 서버는 요청 하나에 연결 하나다
/// (`Connection: close`). 받은 내용은 버리고, 호스트 이름은 로그에 남기지 않는다.
final class TunnelFetch: @unchecked Sendable {
    @MainActor private static var current: TunnelFetch?

    private let connection: NWConnection
    private let request: Data
    private let log: @MainActor (String) -> Void
    private let queue = DispatchQueue(label: "tunnel-fetch")
    // 아래 값은 `queue`에서만 만진다.
    private var started = Date()
    private var lastChunk = Date()
    private var readyAfter: TimeInterval?
    private var firstByte: TimeInterval?
    private var longestGap: TimeInterval = 0
    private var received: Int64 = 0
    private var head = Data()
    private var headLength: Int?
    private var statusLine = ""
    private var finished = false

    private init(host: String, range: String?, log: @escaping @MainActor (String) -> Void) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: NWParameters(tls: tls))
        var text = "GET /file HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n"
        if let range { text += "Range: \(range)\r\n" }
        request = Data((text + "\r\n").utf8)
        self.log = log
    }

    /// `range`는 `Range` 머리의 값(`bytes=0-1048575` 꼴)이고 없으면 전체를 받는다.
    @MainActor
    static func start(host: String, range: String?, log: @escaping @MainActor (String) -> Void) {
        guard current == nil else { return log("받기 시험: 이미 도는 중") }
        let fetch = TunnelFetch(host: host, range: range, log: log)
        current = fetch
        log("받기 시험 시작\(range.map { " (Range \($0))" } ?? "")")
        fetch.run()
    }

    private func run() {
        started = Date()
        lastChunk = started
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                readyAfter = Date().timeIntervalSince(started)
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if let error { finish("보내기 실패(\(error))") } else { receive() }
                })
            case .failed(let error): finish("연결 실패(\(error))")
            case .waiting(let error): finish("연결 대기(\(error))")
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 600) { [self] in finish("10분 한도") }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                let now = Date()
                if firstByte == nil { firstByte = now.timeIntervalSince(started) } else { longestGap = max(longestGap, now.timeIntervalSince(lastChunk)) }
                lastChunk = now
                received += Int64(data.count)
                if headLength == nil {
                    head.append(data.prefix(16_384 - min(head.count, 16_384)))
                    if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                        headLength = end.upperBound
                        statusLine = String(decoding: head.prefix(while: { $0 != 13 }), as: UTF8.self)
                    }
                }
            }
            if let error { return finish("받기 실패(\(error))") }
            if isComplete { return finish(nil) }
            receive()
        }
    }

    private func finish(_ failure: String?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        let seconds = Date().timeIntervalSince(started)
        let body = max(0, received - Int64(headLength ?? 0))
        let mib = Double(body) / 1_048_576
        let line = String(format: "받기 시험 끝%@: %@, 본문 %.1fMiB(%lld바이트), %.2f초, %.1fMiB/s, 연결 준비 %.2f초, 첫 바이트 %.2f초, 가장 긴 멈춤 %.2f초",
                          failure.map { " \($0)" } ?? "", statusLine.isEmpty ? "응답 없음" : statusLine, mib, body, seconds,
                          seconds > 0 ? mib / seconds : 0, readyAfter ?? -1, firstByte ?? -1, longestGap)
        let log = self.log
        Task { @MainActor in
            log(line)
            TunnelFetch.current = nil
        }
    }
}
#endif
