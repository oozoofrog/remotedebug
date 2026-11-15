import Foundation
import Swiftail
import SwiftailCertificates
import SwiftailLoopback

/// 호스트 하나의 설정.
public struct HostConfiguration: Sendable {
    /// 노드 설정. 상태 디렉터리는 이미 있어야 한다(인증서 관리자는 그 아래 `certs/`만 만든다).
    public var node: NodeConfiguration
    /// ACME 디렉터리. 기본은 Let's Encrypt 운영이므로 부르는 쪽이 정해서 넘긴다.
    public var certificates: CertificateConfiguration
    public var content: ServedContent

    public init(node: NodeConfiguration, certificates: CertificateConfiguration, content: ServedContent) {
        (self.node, self.certificates, self.content) = (node, certificates, content)
    }
}

/// Swiftail 노드 위의 HTTPS 파일 서버. Swiftail 계약 `docs/contracts/SwiftailHost.md` 2절 "쓰는 모양(Mac 호스트)"을 따른다:
///
/// ```
/// tailnet :443 ── TailnetListener ── LoopbackBridge ── 127.0.0.1:<시스템 포트> ── NWListener(TLS) ── HTTP
/// ```
public enum SwiftailHost {
    /// 노드·인증서 관리자·tailnet 443 리스너·루프백 TLS 서버를 띄우고, 부른 Task가 취소될 때까지 돈다.
    ///
    /// 취소되면 노드의 `run()`과 `CertificateManager.run()`이 끝나기를 기다린 뒤 돌아온다. 상태 디렉터리는 지우지 않는다.
    ///
    /// - Throws: 노드나 인증서 관리자의 다시 켜도 소용없는 실패(`NodeError`, `CertificateError`), 443을 듣지 못함
    ///   (`ConnectionError`).
    public static func run(_ configuration: HostConfiguration, events: @escaping @Sendable (HostEvent) -> Void) async throws {
        let node = try TailnetNode(configuration: configuration.node, device: .inProcess)
        let certificates = try CertificateManager(node: node, configuration: configuration.certificates)
        let servers = ServerSlot(node: node, content: configuration.content, events: events)
        let listener = try await node.listen(port: 443)

        do {
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask { try await node.run() }
                group.addTask { try await certificates.run() }
                group.addTask {
                    // 인증서가 오거나 바뀔 때마다 TLS 리스너를 (다시) 띄운다.
                    for await certificate in certificates.certificates {
                        events(.certificate(notBefore: certificate.notBefore, notAfter: certificate.notAfter,
                                            chainCount: certificate.chain.count))
                        await servers.restart(with: certificate)
                    }
                }
                group.addTask {
                    for await event in node.events {
                        switch event {
                        case .stateChanged(let state):
                            events(.nodeState(state))
                            if state == .running {
                                let status = await node.status
                                let inDomains = status.fqdn.map { status.certDomains.contains($0) } ?? false
                                events(.running(peerCount: status.peerCount, nameInCertDomains: inDomains))
                            }
                        case .tailnetLockChanged(let lock):
                            events(.tailnetLock(lock))
                        case .peerPathChanged:
                            break
                        }
                    }
                }
                group.addTask {
                    var last: CertificateStatus?
                    while !Task.isCancelled {
                        let status = await certificates.status
                        if status != last {
                            last = status
                            events(.certificateStatus(status))
                        }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                // 이 흐름은 노드의 `run()`이 끝나거나 이 Task가 취소되면 끝난다.
                for await connection in listener {
                    group.addTask {
                        guard let target = await servers.target else {
                            // 아직 인증서가 없다.
                            await connection.abort()
                            return
                        }
                        try? await target.bridge.forward(connection, toLoopbackPort: target.port)
                    }
                }
                group.cancelAll()
            }
        } catch {
            await listener.close()
            await servers.close()
            throw error
        }
        await listener.close()
        await servers.close()
    }
}

/// 지금 쓰는 TLS 리스너와 그 다리. 인증서가 바뀌면 새 리스너를 세운 뒤 옛 리스너는 새 연결만 그만 받는다.
actor ServerSlot {
    struct Target: Sendable {
        let bridge: LoopbackBridge
        let port: UInt16
    }

    private let node: TailnetNode
    private let content: ServedContent
    private let events: @Sendable (HostEvent) -> Void
    private var current: (server: LoopbackHTTPSServer, bridge: LoopbackBridge)?
    /// 새 연결은 받지 않고 받은 연결이 끝나기를 기다리는 옛 리스너.
    private var retired: [LoopbackHTTPSServer] = []

    init(node: TailnetNode, content: ServedContent, events: @escaping @Sendable (HostEvent) -> Void) {
        (self.node, self.content, self.events) = (node, content, events)
    }

    var target: Target? { current.map { Target(bridge: $0.bridge, port: $0.server.port) } }

    func restart(with certificate: TailnetCertificate) async {
        // 리스너 하나에 다리 하나(동작 B7).
        let bridge = LoopbackBridge(node: node)
        do {
            let server = try await LoopbackHTTPSServer.start(certificate: certificate, bridge: bridge, content: content, events: events)
            if let old = current {
                old.server.stopAccepting()
                retired.append(old.server)
            }
            retired.removeAll { $0.activeConnectionCount == 0 }
            current = (server, bridge)
            events(.serverStarted)
        } catch let error as TLSIdentity.Failure {
            events(.serverFailed("TLS 신원(\(error))"))
        } catch {
            events(.serverFailed("리스너"))
        }
    }

    func close() {
        current?.server.close()
        for server in retired { server.close() }
        current = nil
        retired = []
    }
}
