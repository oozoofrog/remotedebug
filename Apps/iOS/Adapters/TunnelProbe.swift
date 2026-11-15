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
#endif
