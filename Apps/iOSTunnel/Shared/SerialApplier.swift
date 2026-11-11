import Foundation

/// 비동기 적용을 한 번에 하나만 진행한다. 진행 중에 들어온 값은 최신 것 하나만 보관했다가
/// 진행 중인 적용이 끝나면 적용한다(`setTunnelNetworkSettings` 직렬화, docs/tunnel.md 2).
final class SerialApplier<Value: Sendable>: @unchecked Sendable {
    /// 값을 적용하고 끝나면 `done`을 부른다. `done`은 어느 스레드에서 불러도 된다.
    typealias Apply = @Sendable (_ value: Value, _ done: @escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private let apply: Apply
    private var inFlight = false
    private var pending: Value?

    init(apply: @escaping Apply) {
        self.apply = apply
    }

    /// 진행 중인 적용이 있으면 대기분을 교체하고, 없으면 바로 적용한다.
    func submit(_ value: Value) {
        lock.lock()
        if inFlight {
            pending = value
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        run(value)
    }

    /// 대기분을 버린다(터널을 멈출 때).
    func discardPending() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    var isApplying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    private func run(_ value: Value) {
        apply(value) { [self] in
            lock.lock()
            guard let next = pending else {
                inFlight = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            run(next)
        }
    }
}
