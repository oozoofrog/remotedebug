import Foundation
import PhoneClientKit
import Synchronization

/// 요청 하나와 그 결과. 응답 본문은 호스트가 보낸 그대로다(주소를 바꾸기 전).
struct Exchange: Sendable {
    var method: String
    var path: String
    var requestHeaders: [String: String]
    var requestBody: Data?
    var status: Int?
    var responseHeaders: [String: String]
    var rawBody: Data
    var failure: String?

    /// HTTP 헤더 이름은 대소문자를 가리지 않는다.
    func header(_ name: String) -> String? {
        responseHeaders.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: [String: Any]? { try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] }
    var requestJSON: [String: Any]? { requestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    var errorCode: String? { (json?["error"] as? [String: Any])?["code"] as? String }

    var summary: String {
        let head = "\(method) \(redacted(path))"
        if let failure { return "\(head) → 실패 \(failure)" }
        return "\(head) → \(status.map(String.init) ?? "?") \(errorCode ?? "")"
    }
}

/// `/i/<토큰>/…` 경로의 토큰을 가린다(addenda A.6과 같은 꼴).
func redacted(_ path: String) -> String {
    guard path.hasPrefix("/i/") else { return path }
    let parts = path.dropFirst(3).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    return parts.count == 2 ? "/i/…/\(parts[1])" : "/i/…"
}

/// iPhone의 네트워크 경로를 대신한다. 실제 전송(`URLSessionTransport`)은 그대로 쓴다.
///
/// 우회 1(요청 주소): iPhone은 제품과 똑같이 `https://<fqdn>/…`로 요청한다. 실제 앱은 터널을 거쳐 tailnet 443에 닿지만
/// 시험은 그 경로가 없으므로 스킴·호스트·포트만 `http://127.0.0.1:<forward 포트>`로 바꾼다. 메서드·경로·헤더·본문은 그대로다.
/// `Host` 헤더는 루프백 값이 되지만 코어는 읽지 않는다(주소는 설정의 `BaseURL`로 만든다).
///
/// 우회 2(응답 주소): 평문 시험 모드의 호스트는 `http://<fqdn>:8080/i/…`를 돌려준다(protocol §11). TLS로 실제 배포한 호스트는
/// `https://<fqdn>/i/…`를 돌려주고(`host.BaseURL`) iPhone의 출하 검사(`isTrustedInstallURL`)는 이 꼴만 받는다.
/// 그래서 세션 생성 응답과 매니페스트 본문의 이 접두어만 TLS 때의 값으로 바꾼다. 나머지 본문·상태 코드·헤더·오류 본문은 그대로이고,
/// 바꾸기 전 원본은 `Exchange.rawBody`에 남는다.
///
/// 이 우회 덕분에 iPhone은 출하 정책(`HostPolicy.tailnetOnly`)과 출하 검사를 그대로 쓴다.
final class TailnetTransport: HTTPTransport {
    let fqdn: String
    let forwarderPort: UInt16
    let macPort: Int
    private let inner = URLSessionTransport()
    private let state = Mutex<(exchanges: [Exchange], offRoute: [String])>(([], []))

    init(fqdn: String, forwarderPort: UInt16, macPort: Int) {
        self.fqdn = fqdn
        self.forwarderPort = forwarderPort
        self.macPort = macPort
    }

    var exchanges: [Exchange] { state.withLock { $0.exchanges } }
    /// 페어링한 Mac의 `https://<fqdn>`이 아닌 곳으로 보내려 한 요청.
    var offRouteRequests: [String] { state.withLock { $0.offRoute } }

    func exchanges(_ method: String, _ matches: (String) -> Bool) -> [Exchange] {
        exchanges.filter { $0.method == method && matches($0.path) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let original = request.url,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == fqdn, components.port == nil || components.port == 443,
              components.user == nil, components.password == nil
        else {
            let target = request.url?.absoluteString ?? "(no url)"
            state.withLock { $0.offRoute.append(target) }
            throw E2EError("페어링한 Mac이 아닌 주소입니다: \(target)")
        }
        let path = components.percentEncodedPath
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(forwarderPort)
        var routed = request
        routed.url = components.url

        var record = Exchange(method: request.httpMethod ?? "GET", path: path,
                              requestHeaders: request.allHTTPHeaderFields ?? [:], requestBody: request.httpBody,
                              status: nil, responseHeaders: [:], rawBody: Data(), failure: nil)
        do {
            let (data, response) = try await inner.send(routed)
            record.status = response.statusCode
            record.rawBody = data
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { record.responseHeaders[key] = value }
            }
            let finished = record
            state.withLock { $0.exchanges.append(finished) }
            return (publicAddresses(in: data, for: finished), response)
        } catch {
            record.failure = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? String(describing: error)
            let finished = record
            state.withLock { $0.exchanges.append(finished) }
            throw error
        }
    }

    /// 평문 시험 호스트의 주소.
    var plainBase: String { "http://\(fqdn):\(macPort)" }
    /// TLS 호스트가 내는 주소(호스트 주소는 `https://<fqdn>`, protocol §1).
    var tlsBase: String { "https://\(fqdn)" }

    private func publicAddresses(in data: Data, for exchange: Exchange) -> Data {
        let isCreatedSession = exchange.method == "POST" && exchange.path.hasSuffix("/sessions") && exchange.status == 201
        let isManifest = exchange.path.hasPrefix("/i/") && exchange.path.hasSuffix("/manifest.plist") && exchange.status == 200
        guard isCreatedSession || isManifest else { return data }
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: plainBase, with: tlsBase)
        text = text.replacingOccurrences(of: "http%3A%2F%2F\(fqdn)%3A\(macPort)", with: "https%3A%2F%2F\(fqdn)")
        return Data(text.utf8)
    }
}
