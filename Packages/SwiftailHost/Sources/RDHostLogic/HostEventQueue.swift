import Foundation
import RDModels

/// 사건 수 256개와 인코딩한 페이로드 8MiB를 함께 제한하는 FIFO.
/// Options.eventDetails에 push를 넘기면 수신 시각도 보존한다. nextEvent는 전용 소비 스레드에서 기다린다.
public final class HostEventQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private let byteCapacity: Int
    private var items: [(event: HostLogic.EmittedEvent, bytes: Int)] = []
    private var payloadBytes = 0
    private var dropped = 0
    private var closed = false
    public init(capacity: Int = 256, byteCapacity: Int = 8 << 20) {
        self.capacity = max(1, capacity)
        self.byteCapacity = max(1, byteCapacity)
    }
    public func push(_ event: CoreEvent) { push(HostLogic.EmittedEvent(event: event)) }
    public func push(_ event: HostLogic.EmittedEvent) {
        condition.lock()
        defer { condition.unlock() }
        pushLocked(event)
    }
    public func replace(_ event: CoreEvent) { replace(HostLogic.EmittedEvent(event: event)) }
    public func replace(_ event: HostLogic.EmittedEvent) {
        condition.lock()
        defer { condition.unlock() }
        for index in items.indices.reversed() where items[index].event.event.type == event.event.type { remove(at: index) }
        pushLocked(event)
    }
    private func remove(at index: Int) { payloadBytes -= items.remove(at: index).bytes }
    private func pushLocked(_ event: HostLogic.EmittedEvent) {
        guard !closed else { return }
        let bytes = (try? JSONEncoder().encode(event).count) ?? (byteCapacity + 1)
        guard bytes <= byteCapacity else { dropped += 1; condition.broadcast(); return }
        while items.count >= capacity || payloadBytes > byteCapacity - bytes {
            dropped += 1
            if let index = items.firstIndex(where: { Self.lowPriority($0.event.event) }) { remove(at: index) }
            else if Self.lowPriority(event.event) { condition.broadcast(); return }
            else { remove(at: 0) }
        }
        items.append((event, bytes))
        payloadBytes += bytes
        condition.broadcast()
    }
    public func next(timeoutMilliseconds: Int = 0) -> CoreEvent? { nextEvent(timeoutMilliseconds: timeoutMilliseconds)?.event }
    public func nextEvent(timeoutMilliseconds: Int = 0) -> HostLogic.EmittedEvent? {
        let deadline = Date().addingTimeInterval(Double(max(0, timeoutMilliseconds)) / 1000)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if dropped > 0 {
                let count = dropped
                dropped = 0
                return .init(event: .log(.init(level: "warn", message: "event queue full: dropped \(count) events")))
            }
            if !items.isEmpty {
                let first = items.removeFirst()
                payloadBytes -= first.bytes
                return first.event
            }
            if closed || timeoutMilliseconds <= 0 || !condition.wait(until: deadline) { return nil }
        }
    }
    public var bufferedPayloadBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return payloadBytes
    }
    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
    private static func lowPriority(_ event: CoreEvent) -> Bool {
        ["denied", "log", "state", "device-log", "device-crash"].contains(event.type)
    }
}
