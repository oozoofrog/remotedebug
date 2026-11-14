import Foundation
import Network
import os
import RDCoreBridge
import RDModels

/// 터널 확장이 tailnet 노드 구현에게 바라는 것. Go 코어와 Swiftail이 같은 호출 지점 뒤에 놓인다.
protocol TunnelEngine: AnyObject, Sendable {
    /// 상태·설정·로그 사건. 구독자는 하나다.
    func events() -> AsyncStream<CoreEvent>
    func status() async -> CoreStatus?
    /// 만족된 경로를 받을 때마다 부른다. 같은 인터페이스를 거를지는 구현이 정한다.
    func setDefaultInterface(_ interface: NWInterface) throws
    func setPathPeer(_ fqdn: String) throws
    /// 노드를 멈추고 끝날 때까지 기다린다. 몇 초 걸릴 수 있어 직렬 큐에서 부른다.
    func stop()
}

/// Go 코어(`rd_*` C API).
final class GoTunnelEngine: TunnelEngine, @unchecked Sendable {
    private let node: RDNode
    private let logger: Logger
    private let lock = NSLock()
    private var interfaceName: String?

    init(config: CoreConfig, logger: Logger) throws {
        node = try RDNode.start(config: RDJSON.encoder().encode(config))
        self.logger = logger
    }

    func events() -> AsyncStream<CoreEvent> {
        // RDNode.events()는 rd_next_event를 전용 스레드에서 돈다.
        let raw = node.events()
        let logger = logger
        return AsyncStream { continuation in
            let task = Task.detached {
                for await data in raw {
                    if let event = try? RDJSON.decoder().decode(CoreEvent.self, from: data) {
                        continuation.yield(event)
                    } else {
                        logger.error("이벤트를 읽지 못했습니다")
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func status() async -> CoreStatus? {
        guard let data = try? node.status() else { return nil }
        return try? RDJSON.decoder().decode(CoreStatus.self, from: data)
    }

    /// 코어는 이름이 바뀔 때만 알면 된다(주소 변화는 코어의 경로 감시가 본다).
    func setDefaultInterface(_ interface: NWInterface) throws {
        let name = interface.name
        let changed = lock.withLock {
            guard interfaceName != name else { return false }
            interfaceName = name
            return true
        }
        guard changed else { return }
        do {
            try node.setDefaultInterface(name)
            logger.log("기본 인터페이스: \(name, privacy: .public)")
        } catch {
            lock.withLock { interfaceName = nil }
            throw error
        }
    }

    func setPathPeer(_ fqdn: String) throws {
        try node.setPathPeer(fqdn)
    }

    func stop() {
        do { try node.stop() } catch { logger.error("rd_stop 실패: \(String(describing: error), privacy: .public)") }
    }
}
