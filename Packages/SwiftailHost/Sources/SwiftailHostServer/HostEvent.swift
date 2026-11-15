import Foundation
import RDHostLogic
import Swiftail
import SwiftailCertificates
import SwiftailControl

/// 호스트가 부르는 쪽에 알리는 것. 라이브러리는 로그를 남기지 않고 모든 것을 이 사건으로 넘긴다.
///
/// 비밀이 든 값이 있다: `nodeState(.needsLogin(url))`의 URL은 그 자체로 로그인 권한이고, `tailnetLock`의
/// `signingRequest`는 공개 키 둘이다. `certificate`의 `domain`과 `connection`의 상대는 tailnet 이름·로그인 이름을 담는다.
/// 어디에 보일지는 부르는 쪽이 정한다(로그에 쓰지 않는다).
public enum HostEvent: Sendable {
    /// 노드의 상태가 바뀌었다.
    case nodeState(NodeState)
    /// 노드가 `.running`이 되었다. 그때의 피어 수와, 자기 이름이 cert 도메인에 있는지.
    case running(peerCount: Int, nameInCertDomains: Bool)
    /// tailnet lock의 모습이 바뀌었다. 잠겼으면 `signingRequest`에 서명 기기로 넘길 두 공개 키가 있다.
    case tailnetLock(TailnetLockStatus)
    /// tailnet 포트를 듣기 시작했다.
    case listening(port: UInt16)
    /// 인증서 관리자가 인증서를 냈다(저장된 것이거나 새로 받은 것). 그 인증서로 TLS 리스너를 (다시) 띄운다.
    case certificate(domain: String, notBefore: Date, notAfter: Date, chainCount: Int)
    /// 인증서 관리자의 모습이 바뀌었다(마지막 실패, 다음 시도). 2초마다 보고 바뀌었을 때만 낸다.
    case certificateStatus(CertificateStatus)
    /// 받은 인증서로 루프백 TLS 리스너를 띄우지 못했다. 연관 값은 종류만 담는다.
    case serverFailed(String)
    /// 루프백 리스너가 섰다. 앞 리스너는 새 연결을 받지 않고 이미 받은 연결만 끝까지 간다.
    case serverStarted
    /// 기본 경로의 인터페이스가 바뀌어 노드에 알렸다(이름만, 예: `en0`).
    case defaultInterface(name: String)
    /// 다리를 거친 연결 하나가 섰다(동작 B7: `.ready` 뒤 한 번 물은 상대).
    case connection(HostOrigin)
    /// 다리의 토큰이 없거나(직접 건 연결) 준비 전에 끝난 연결, 또는 상대를 얻지 못한 연결을 끊었다.
    case connectionRejected
}
