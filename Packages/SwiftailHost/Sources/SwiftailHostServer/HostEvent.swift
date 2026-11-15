import Foundation
import Swiftail
import SwiftailCertificates
import SwiftailControl

/// 호스트가 부르는 쪽에 알리는 것. 라이브러리는 로그를 남기지 않고 모든 것을 이 사건으로 넘긴다.
///
/// 비밀이 든 값이 있다: `nodeState(.needsLogin(url))`의 URL은 그 자체로 로그인 권한이고, `tailnetLock`의
/// `signingRequest`는 공개 키 둘이다. 어디에 보일지는 부르는 쪽이 정한다(로그에 쓰지 않는다).
public enum HostEvent: Sendable {
    /// 노드의 상태가 바뀌었다.
    case nodeState(NodeState)
    /// 노드가 `.running`이 되었다. 그때의 피어 수와, 자기 이름이 cert 도메인에 있는지(관문 (나) 1).
    case running(peerCount: Int, nameInCertDomains: Bool)
    /// tailnet lock의 모습이 바뀌었다. 잠겼으면 `signingRequest`에 서명 기기로 넘길 두 공개 키가 있다.
    case tailnetLock(TailnetLockStatus)
    /// 인증서 관리자가 인증서를 냈다(저장된 것이거나 새로 받은 것). 그 인증서로 TLS 리스너를 (다시) 띄운다.
    case certificate(notBefore: Date, notAfter: Date, chainCount: Int)
    /// 인증서 관리자의 모습이 바뀌었다(마지막 실패, 다음 시도). 2초마다 보고 바뀌었을 때만 낸다.
    case certificateStatus(CertificateStatus)
    /// 받은 인증서로 루프백 TLS 리스너를 띄우지 못했다. 연관 값은 종류만 담는다.
    case serverFailed(String)
    /// 루프백 TLS 리스너가 새 인증서로 섰다. 앞 리스너는 새 연결을 받지 않고 이미 받은 연결만 끝까지 간다.
    case serverStarted
    /// 다리를 거친 연결 하나가 섰다. 상대 노드의 `StableID`(동작 B7: `.ready` 뒤 한 번 물은 값).
    case connection(peerStableID: String)
    /// 다리의 토큰이 없거나(직접 건 연결) 준비 전에 끝난 연결, 또는 상대를 얻지 못한 연결을 끊었다.
    case connectionRejected
    /// 응답 하나가 끝났다(다 보냈거나 도중에 끊겼다).
    case response(ResponseRecord)
}

/// 응답 하나의 기록. 요청의 원문(경로, 머리)은 담지 않는다.
public struct ResponseRecord: Sendable, Equatable {
    public var method: HTTPRequest.Method?
    /// 아는 경로면 그 경로, 아니면 nil(404 등).
    public var route: Route?
    public var status: Int
    /// 보낸 본문 바이트(머리 제외).
    public var bodyBytes: UInt64
    /// 머리를 보내기 시작해서 마지막 바이트를 네트워크 스택이 받아 갈 때까지.
    public var seconds: Double
    /// 약속한 본문을 다 보냈는가.
    public var completed: Bool
    /// 보낸 상대 노드. 요청을 읽기 전에 끊은 연결은 기록하지 않는다.
    public var peerStableID: String
}
