#if RD_SWIFTAIL_TUNNEL
import Foundation

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
/// Swiftail 호스트 관문의 전송 측정에 쓴다. 상대가 Let's Encrypt 스테이징 인증서를 쓰므로 **이 요청만** 서버 검증을 건너뛴다.
/// 받은 내용은 쓰지 않고 버리며, 호스트 이름은 로그에 남기지 않는다.
final class TunnelFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    @MainActor private static var current: TunnelFetch?

    private let host: String
    private let log: @MainActor (String) -> Void
    // 아래 값은 세션의 직렬 델리게이트 큐에서만 만진다.
    private var started = Date()
    private var lastChunk = Date()
    private var firstByte: TimeInterval?
    private var longestGap: TimeInterval = 0
    private var bytes: Int64 = 0
    private var status = 0

    private init(host: String, log: @escaping @MainActor (String) -> Void) {
        (self.host, self.log) = (host, log)
    }

    /// `range`는 `Range` 머리의 값(`bytes=0-1048575` 꼴)이고 없으면 전체를 받는다.
    @MainActor
    static func start(host: String, range: String?, log: @escaping @MainActor (String) -> Void) {
        guard current == nil else { return log("받기 시험: 이미 도는 중") }
        guard let url = URL(string: "https://\(host)/file") else { return log("받기 시험: 주소가 잘못됨") }
        let fetch = TunnelFetch(host: host, log: log)
        current = fetch
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: queue)
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        log("받기 시험 시작\(range.map { " (Range \($0))" } ?? "")")
        fetch.started = Date()
        fetch.lastChunk = fetch.started
        session.dataTask(with: request).resume()
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async
        -> URLSession.ResponseDisposition {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let now = Date()
        if firstByte == nil { firstByte = now.timeIntervalSince(started) } else { longestGap = max(longestGap, now.timeIntervalSince(lastChunk)) }
        lastChunk = now
        bytes += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let seconds = Date().timeIntervalSince(started)
        let mib = Double(bytes) / 1_048_576
        let failure = error.map { " 실패(\(($0 as NSError).domain) \(($0 as NSError).code))" } ?? ""
        let line = String(format: "받기 시험 끝%@: HTTP %d, %.1fMiB, %.2f초, %.1fMiB/s, 첫 바이트 %.2f초, 가장 긴 멈춤 %.2f초",
                          failure, status, mib, seconds, seconds > 0 ? mib / seconds : 0, firstByte ?? -1, longestGap)
        let log = self.log
        Task { @MainActor in
            log(line)
            TunnelFetch.current = nil
        }
    }
}
#endif
