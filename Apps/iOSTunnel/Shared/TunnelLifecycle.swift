import Foundation

/// 터널 확장의 시작·종료 순서를 한곳에서 정한다(docs/tunnel.md "터널 확장(Swift)의 책임" 1·5).
///
/// - `startTunnel`은 `begin()`으로 세대를 받고, 단계마다 `isCurrent(_:)`를 확인한다.
/// - `rd_start`는 `startNode(generation:start:stop:)` 안에서, `coreQueue`(직렬)에서 부른다.
///   시작하는 동안 종료 요청이 왔으면 방금 만든 노드를 그 자리에서 멈추고 `stoppedDuringStart`를 던진다.
/// - `stopTunnel`은 `requestStop()`으로 노드와 정리 작업을 가져간 뒤, `coreQueue`에서 `drainOnCoreQueue(stop:)`를 부른다.
///   `rd_start`가 진행 중이었다면 그것이 끝난 뒤에 실행되므로 종료가 시작을 앞지르지 않는다.
/// - 종료 요청 뒤에는 단계가 `.stopping`에서 바뀌지 않는다(노드 저장·실패 표시가 덮어쓰지 않는다).
///
/// 이 파일은 앱 대상에도 컴파일되어 단위 테스트한다(가짜 노드).
final class TunnelLifecycle<Node: Sendable>: @unchecked Sendable {
    enum LifecycleError: Error, Equatable {
        /// 시작하는 동안 종료 요청이 왔다.
        case stoppedDuringStart
    }

    private let lock = NSLock()
    private var _phase: TunnelExtensionPhase = .starting
    private var generation = 0
    private var stopRequested = false
    private var node: Node?
    private var cleanups: [@Sendable () -> Void] = []

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var phase: TunnelExtensionPhase { locked { _phase } }
    var currentNode: Node? { locked { node } }
    var isStopRequested: Bool { locked { stopRequested } }

    /// 새 시작. 이전 시작이 아직 돌고 있으면 그 세대는 더 이상 노드를 저장하지 못한다.
    @discardableResult
    func begin() -> Int {
        locked {
            generation &+= 1
            stopRequested = false
            _phase = .starting
            return generation
        }
    }

    /// 이 세대의 시작을 계속해도 되는지(종료 요청·새 시작이 없었는지).
    func isCurrent(_ generation: Int) -> Bool {
        locked { generation == self.generation && !stopRequested }
    }

    /// `coreQueue`에서 부른다. 계속해도 되면 `start`로 노드를 만들고 저장한다.
    /// 만든 뒤 종료 요청이 와 있으면 `stop`으로 바로 멈추고 `LifecycleError.stoppedDuringStart`를 던진다.
    func startNode(generation: Int, start: () throws -> Node, stop: (Node) -> Void) throws -> Node {
        guard isCurrent(generation) else { throw LifecycleError.stoppedDuringStart }
        let started = try start()
        let adopted = locked { () -> Bool in
            guard generation == self.generation, !stopRequested, node == nil else { return false }
            node = started
            _phase = .running
            return true
        }
        guard adopted else {
            stop(started)
            throw LifecycleError.stoppedDuringStart
        }
        return started
    }

    /// 이벤트 루프·경로 감시처럼 종료 때 끊을 작업을 붙인다.
    /// 이미 종료 요청이 왔거나 다른 세대면 `false`를 돌려주며, 호출자가 바로 `cleanup`을 부른다.
    func attach(generation: Int, cleanup: @escaping @Sendable () -> Void) -> Bool {
        locked {
            guard generation == self.generation, !stopRequested else { return false }
            cleanups.append(cleanup)
            return true
        }
    }

    /// 종료 요청. 저장된 노드와 정리 작업을 넘긴다. 정리 작업은 호출자가 부른다.
    func requestStop() -> (node: Node?, cleanups: [@Sendable () -> Void]) {
        locked {
            stopRequested = true
            _phase = .stopping
            defer {
                node = nil
                cleanups = []
            }
            return (node, cleanups)
        }
    }

    /// `coreQueue`에서 부른다(진행 중인 `rd_start`가 끝난 뒤). `requestStop()` 뒤에 남은 노드가 있으면 멈춘다.
    /// `requestStop()`이 이미 가져간 노드는 `extra`로 넘긴다. 같은 노드를 두 번 멈추지 않는다.
    func drainOnCoreQueue(extra: Node?, stop: (Node) -> Void) {
        let leftover = locked { () -> Node? in
            defer { node = nil }
            return node
        }
        if let extra { stop(extra) }
        if let leftover { stop(leftover) }
    }

    /// 엔진 사망. 종료 중이면 `.stopping`을 유지한다.
    func markFailed() {
        locked {
            guard !stopRequested else { return }
            _phase = .failed
        }
    }

    /// 이 세대의 시작 실패. 종료 요청이 있었거나 새 시작(`begin()`)이 이미 들어왔으면
    /// 아무것도 바꾸지 않고 `false`를 돌려준다(늦게 끝난 이전 시작이 새 시작의 단계를 덮어쓰지 않는다).
    @discardableResult
    func markFailed(generation: Int) -> Bool {
        locked {
            guard generation == self.generation, !stopRequested else { return false }
            _phase = .failed
            return true
        }
    }
}
