import Foundation

/// HTTP 요청 하나를 보내고 응답을 받는다. 테스트는 가짜 구현을 넣는다.
/// 구현은 `URLRequest.timeoutInterval`을 요청 하나의 전체 제한 시간으로 지켜야 한다.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// 본문을 임시 파일로 받는다. 돌려준 파일은 부른 쪽이 옮기거나 지운다.
    /// `key`가 같은 이전 전송이 끊겼으면 이어 받는다. `progress`는 받은 바이트와 전체 바이트를 알린다.
    func download(_ request: URLRequest, key: String, context: Data?, progress: @escaping FileDownloader.Progress) async throws -> (URL, HTTPURLResponse)
}

extension HTTPTransport {
    /// 기본 구현은 `send`로 받은 본문을 임시 파일에 쓴다(시험용 가짜 전송).
    public func download(_ request: URLRequest, key: String, context: Data?, progress: @escaping FileDownloader.Progress) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await send(request)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rd-download-\(UUID().uuidString)")
        try data.write(to: url)
        progress(Int64(data.count), Int64(data.count))
        return (url, response)
    }
}

/// 실제 전송. 임시(ephemeral) 세션, 쿠키·캐시 없음, 리다이렉트를 따르지 않는다.
/// 제한 시간은 요청마다 `URLRequest.timeoutInterval`로 정하고(`HostAPI.Timeouts`), 넘으면 `URLError(.timedOut)`을 던진다.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let maximumTimeout: TimeInterval

    /// - Parameter maximumTimeout: 요청 하나에 허용하는 최대 시간(초). 요청의 `timeoutInterval`이 더 길어도 이 값에서 끊는다.
    public init(maximumTimeout: TimeInterval = 120) {
        self.maximumTimeout = maximumTimeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = maximumTimeout
        config.timeoutIntervalForResource = maximumTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// 시스템 백그라운드 세션(`FileDownloader.shared`)으로 받는다. 앱이 백그라운드로 가도 이어 간다.
    public func download(_ request: URLRequest, key: String, context: Data?, progress: @escaping FileDownloader.Progress) async throws -> (URL, HTTPURLResponse) {
        try await FileDownloader.shared.download(request, key: key, context: context, progress: progress)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let limit = min(max(request.timeoutInterval, 1), maximumTimeout)
        let session = self.session
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.unknown) }
            return first
        }
    }
}

/// 다른 주소로 요청이 넘어가지 않게 리다이렉트를 막는다(3xx 응답을 그대로 돌려준다).
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
