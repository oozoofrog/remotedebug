import Foundation

// 호스트 로직(경로·페어링·세션·게시)과 전송(Swiftail 노드·다리·TLS·직접 연결 리스너) 사이의 접점.
// 로직은 Tailscale도 소켓도 모른다: 전송이 요청 하나를 `HostRequest`로 넘기고 `HostResponse`를 받아 보낸다.
// Go 코어의 `host.Handler()`·`host.DirectHandler()`와 `WhoIsFunc`가 하던 일을 이 타입들이 나눠 맡는다.

/// tailnet으로 들어온 요청의 상대. 전송이 연결마다 한 번 알아내 그 연결의 모든 요청에 붙인다.
public struct HostPeer: Sendable, Hashable {
    public var stableID: String
    public var nodeName: String
    public var loginName: String

    public init(stableID: String, nodeName: String, loginName: String) {
        (self.stableID, self.nodeName, self.loginName) = (stableID, nodeName, loginName)
    }
}

/// 요청이 들어온 길.
public enum HostOrigin: Sendable, Hashable {
    /// tailnet 443. 상대는 Swiftail이 확인한 노드다.
    case tailnet(HostPeer)
    /// 같은 네트워크 직접 연결 리스너(protocol-addenda O). 상대의 IP만 안다. 누구인지는 로직이 토큰으로 가린다.
    case direct(remoteIP: String)
}

/// 요청 본문을 조각으로 읽는다. 전송이 구현한다. 끝이면 nil. `Content-Length`를 넘겨 읽지 않는다.
public protocol HostBodyReader: Sendable {
    func read(upTo count: Int) async throws -> [UInt8]?
}

public struct HostRequest: Sendable {
    /// 대문자 메서드(`GET`, `POST`, `PUT`, `DELETE`, `HEAD`).
    public var method: String
    /// 요청 대상 그대로(`/v1/builds?x=1`). 퍼센트 디코딩과 경로 정규화는 로직이 한다. 신뢰할 수 없는 입력이다.
    public var target: String
    /// 받은 순서의 머리. 이름은 전송이 소문자로 바꿔 넘긴다.
    public var headers: [(name: String, value: String)]
    /// 본문이 없으면 nil. 전송은 `Content-Length`가 있는 본문만 넘긴다(chunked 요청은 전송이 411로 거절).
    public var body: (any HostBodyReader)?
    public var contentLength: UInt64
    public var origin: HostOrigin

    public init(method: String, target: String, headers: [(name: String, value: String)], body: (any HostBodyReader)?,
                contentLength: UInt64, origin: HostOrigin) {
        (self.method, self.target, self.headers) = (method, target, headers)
        (self.body, self.contentLength, self.origin) = (body, contentLength, origin)
    }

    /// 소문자 이름으로 첫 값을 찾는다.
    public func header(_ name: String) -> String? {
        headers.first { $0.name == name }?.value
    }
}

public enum HostResponseBody: Sendable {
    case none
    case bytes([UInt8])
    /// 파일의 한 구간. 전송이 조각으로 읽어 보낸다(4GiB 넘는 파일도 메모리에 올리지 않는다).
    case file(path: String, offset: UInt64, count: UInt64)
}

public struct HostResponse: Sendable {
    public var status: Int
    /// `Content-Length`·`Connection`·`Date`는 전송이 붙인다. 로직은 넣지 않는다.
    public var headers: [(name: String, value: String)]
    public var body: HostResponseBody
    /// 응답을 다 보냈거나 중간에 끊긴 뒤 전송이 한 번 부른다(보낸 본문 바이트, 다 보냈는지). 세션 진행률·완료 사건에 쓴다.
    public var onFinished: (@Sendable (_ sentBodyBytes: UInt64, _ completed: Bool) -> Void)?

    public init(status: Int, headers: [(name: String, value: String)] = [], body: HostResponseBody = .none,
                onFinished: (@Sendable (UInt64, Bool) -> Void)? = nil) {
        (self.status, self.headers, self.body, self.onFinished) = (status, headers, body, onFinished)
    }
}

/// 전송이 부르는 로직의 입구. tailnet 리스너와 직접 연결 리스너가 같은 것을 부르고 `origin`으로 가른다.
/// 메서드가 `HEAD`여도 로직은 `GET`과 같은 응답을 만들고 전송이 본문을 뺀다.
public protocol HostRequestHandling: Sendable {
    func handle(_ request: HostRequest) async -> HostResponse
}
