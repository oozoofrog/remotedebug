import Foundation
import Testing
@testable import RemoteDebug

/// `TunnelLifecycle`: 시작·종료가 겹칠 때 노드가 남지 않는지(PacketTunnelProvider의 순서 규칙).
@Suite("TunnelLifecycle")
struct TunnelLifecycleTests {
    struct FakeNode: Sendable, Equatable {
        var id: Int
    }

    /// 멈춘 노드와 정리 작업 호출을 기록한다.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _stopped: [Int] = []
        private var _cleanups = 0

        var stopped: [Int] { lock.withLock { _stopped } }
        var cleanups: Int { lock.withLock { _cleanups } }

        func stop(_ node: FakeNode) { lock.withLock { _stopped.append(node.id) } }
        func cleanup() { lock.withLock { _cleanups += 1 } }
    }

    typealias Lifecycle = TunnelLifecycle<FakeNode>

    @Test("노드가 생기기 전에 종료: rd_start를 부르지 않고 시작을 실패시킨다")
    func stopBeforeNode() {
        let lifecycle = Lifecycle()
        let recorder = Recorder()
        let generation = lifecycle.begin()
        let taken = lifecycle.requestStop()
        #expect(taken.node == nil && taken.cleanups.isEmpty)
        #expect(lifecycle.phase == .stopping)
        #expect(!lifecycle.isCurrent(generation))

        var startCalled = false
        #expect(throws: Lifecycle.LifecycleError.stoppedDuringStart) {
            try lifecycle.startNode(generation: generation, start: {
                startCalled = true
                return FakeNode(id: 1)
            }, stop: recorder.stop)
        }
        #expect(!startCalled)
        #expect(recorder.stopped.isEmpty)
        #expect(lifecycle.currentNode == nil)
        #expect(lifecycle.phase == .stopping)
    }

    @Test("rd_start 도중 종료: 새 노드를 같은 큐에서 멈추고 단계는 stopping으로 남는다")
    func stopDuringStart() throws {
        let lifecycle = Lifecycle()
        let recorder = Recorder()
        let coreQueue = DispatchQueue(label: "test.core")
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let outcome = Box<Result<FakeNode, Lifecycle.LifecycleError>>()
        let generation = lifecycle.begin()

        coreQueue.async {
            do {
                let node = try lifecycle.startNode(generation: generation, start: {
                    entered.signal()
                    proceed.wait()  // rd_start가 오래 걸리는 동안
                    return FakeNode(id: 7)
                }, stop: recorder.stop)
                outcome.set(.success(node))
            } catch let error as Lifecycle.LifecycleError {
                outcome.set(.failure(error))
            } catch {}
            finished.signal()
        }

        entered.wait()
        // stopTunnel: 노드가 아직 없다.
        let taken = lifecycle.requestStop()
        #expect(taken.node == nil)
        proceed.signal()
        // stopTunnel의 coreQueue 장벽: rd_start가 끝난 뒤에 실행된다.
        coreQueue.sync { lifecycle.drainOnCoreQueue(extra: taken.node, stop: recorder.stop) }
        finished.wait()

        #expect(outcome.value == .failure(.stoppedDuringStart))
        #expect(recorder.stopped == [7])
        #expect(lifecycle.currentNode == nil)
        #expect(lifecycle.phase == .stopping)
        // 종료 뒤에는 이벤트 루프·경로 감시를 붙이지 않는다.
        #expect(!lifecycle.attach(generation: generation, cleanup: recorder.cleanup))
    }

    @Test("시작이 끝난 뒤 종료: 노드와 정리 작업을 넘기고 장벽에서 한 번만 멈춘다")
    func stopAfterStart() throws {
        let lifecycle = Lifecycle()
        let recorder = Recorder()
        let generation = lifecycle.begin()
        let node = try lifecycle.startNode(generation: generation, start: { FakeNode(id: 1) }, stop: recorder.stop)
        #expect(lifecycle.phase == .running)
        #expect(lifecycle.currentNode == node)
        #expect(lifecycle.attach(generation: generation, cleanup: recorder.cleanup))
        #expect(lifecycle.attach(generation: generation, cleanup: recorder.cleanup))

        let taken = lifecycle.requestStop()
        #expect(taken.node == node)
        #expect(taken.cleanups.count == 2)
        taken.cleanups.forEach { $0() }
        lifecycle.drainOnCoreQueue(extra: taken.node, stop: recorder.stop)
        #expect(recorder.stopped == [1])
        #expect(recorder.cleanups == 2)
        #expect(lifecycle.currentNode == nil)
        #expect(lifecycle.phase == .stopping)
    }

    @Test("두 번 종료해도 노드를 다시 멈추지 않는다")
    func doubleStop() throws {
        let lifecycle = Lifecycle()
        let recorder = Recorder()
        let generation = lifecycle.begin()
        _ = try lifecycle.startNode(generation: generation, start: { FakeNode(id: 1) }, stop: recorder.stop)
        let first = lifecycle.requestStop()
        lifecycle.drainOnCoreQueue(extra: first.node, stop: recorder.stop)
        let second = lifecycle.requestStop()
        #expect(second.node == nil && second.cleanups.isEmpty)
        lifecycle.drainOnCoreQueue(extra: second.node, stop: recorder.stop)
        #expect(recorder.stopped == [1])
        #expect(lifecycle.phase == .stopping)
    }

    @Test("종료 뒤 다시 시작: 새 세대는 노드를 저장하고, 이전 세대는 저장하지 못한다")
    func startAfterStop() throws {
        let lifecycle = Lifecycle()
        let recorder = Recorder()
        let first = lifecycle.begin()
        _ = try lifecycle.startNode(generation: first, start: { FakeNode(id: 1) }, stop: recorder.stop)
        let taken = lifecycle.requestStop()
        lifecycle.drainOnCoreQueue(extra: taken.node, stop: recorder.stop)

        let second = lifecycle.begin()
        #expect(lifecycle.phase == .starting)
        #expect(lifecycle.isCurrent(second))
        #expect(!lifecycle.isCurrent(first))
        let node = try lifecycle.startNode(generation: second, start: { FakeNode(id: 2) }, stop: recorder.stop)
        #expect(node.id == 2)
        #expect(lifecycle.phase == .running)
        #expect(recorder.stopped == [1])
    }

    @Test("늦게 끝난 이전 시작의 노드는 저장하지 않고 멈춘다")
    func staleGenerationIsStopped() throws {
        let lifecycle = Lifecycle()
        let recorder = Recorder()
        let stale = lifecycle.begin()
        let current = lifecycle.begin()
        #expect(throws: Lifecycle.LifecycleError.stoppedDuringStart) {
            // 확인 뒤 rd_start 도중에 새 시작이 들어온 경우와 같다.
            try lifecycle.startNode(generation: current, start: {
                _ = lifecycle.begin()
                return FakeNode(id: 3)
            }, stop: recorder.stop)
        }
        #expect(throws: Lifecycle.LifecycleError.stoppedDuringStart) {
            try lifecycle.startNode(generation: stale, start: { FakeNode(id: 4) }, stop: recorder.stop)
        }
        #expect(recorder.stopped == [3])
        #expect(lifecycle.currentNode == nil)
    }

    @Test("실패 표시는 종료 중이면 stopping을 덮어쓰지 않는다")
    func markFailed() {
        let lifecycle = Lifecycle()
        lifecycle.begin()
        lifecycle.markFailed()
        #expect(lifecycle.phase == .failed)
        lifecycle.begin()
        _ = lifecycle.requestStop()
        lifecycle.markFailed()
        #expect(lifecycle.phase == .stopping)
    }

    @Test("세대별 실패 표시: 현재 세대만 failed로 바꾸고, 이전 세대의 늦은 실패는 새 시작을 건드리지 않는다")
    func markFailedByGeneration() {
        let lifecycle = Lifecycle()
        let stale = lifecycle.begin()
        let current = lifecycle.begin()
        #expect(!lifecycle.markFailed(generation: stale))
        #expect(lifecycle.phase == .starting)
        #expect(lifecycle.markFailed(generation: current))
        #expect(lifecycle.phase == .failed)
    }

    @Test("종료를 요청한 뒤 끝난 시작의 실패는 기록하지 않는다")
    func markFailedAfterStopRequest() {
        let lifecycle = Lifecycle()
        let generation = lifecycle.begin()
        _ = lifecycle.requestStop()
        #expect(!lifecycle.markFailed(generation: generation))
        #expect(lifecycle.phase == .stopping)
    }

    @Test("이전 시작이 실패해도 그사이 새 시작이 저장한 노드와 running 단계는 그대로다")
    func staleFailureKeepsNewNode() throws {
        let lifecycle = Lifecycle()
        let recorder = Recorder()
        let stale = lifecycle.begin()
        let current = lifecycle.begin()
        let node = try lifecycle.startNode(generation: current, start: { FakeNode(id: 2) }, stop: recorder.stop)
        #expect(!lifecycle.markFailed(generation: stale))
        #expect(lifecycle.phase == .running)
        #expect(lifecycle.currentNode == node)
        #expect(recorder.stopped.isEmpty)
    }
}

/// 다른 스레드에서 쓴 값을 읽는 상자.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value?

    var value: Value? { lock.withLock { _value } }
    func set(_ value: Value) { lock.withLock { _value = value } }
}
