// RDCoreHost — 실제 Go 코어(RDCoreBridge의 RDNode)를 MacHostKit의 `HostCore`로 감싼다.
//
// - 모든 `rd_*` 호출은 전용 직렬 큐에서 한다. Swift 협력 스레드 풀을 막지 않고, 호출 순서(setDevices 등)가 보장된다.
// - 이벤트는 `RDNode.events()`의 전용 스레드가 `rd_next_event`를 돈다. `stop()`은 `rd_stop` 뒤 각 펌프가 원시 스트림에
//   남은 이벤트(rd_stop이 보낸 세션 `failed` 등, addenda C.3)를 다 넘길 때까지(최대 `eventPollMilliseconds` + 여유) 기다린 뒤
//   스트림을 끝낸다(`HostCore` 계약).
// - JSON은 RDModels(`RDJSON`)로 인코드·디코드한다.
// - 코어 오류(`RDCoreError`)는 코드와 메시지를 그대로 `APIErrorBody`로 옮겨 던진다(`HostCore` 계약).
import Foundation
import MacHostKit
import RDCoreBridge
import RDModels

public final class RDCoreHost: HostCore, @unchecked Sendable {
    /// 노드의 원시 이벤트(JSON) 스트림. 테스트가 바꿔 끼운다.
    typealias RawEvents = @Sendable (RDNode, Int32) -> AsyncStream<Data>

    /// `rd_next_event` 한 번이 막는 최대 시간. `stop` 뒤 이벤트 스레드가 이만큼 안에 끝난다.
    public let eventPollMilliseconds: Int32
    /// `stop`이 펌프를 기다리는 여유 시간(`eventPollMilliseconds`에 더한다).
    let drainMargin: Duration

    private let queue = DispatchQueue(label: "RDCoreHost.calls", qos: .userInitiated)
    private let lock = NSLock()
    private let rawEvents: RawEvents
    // lock으로 보호한다.
    private var node: RDNode?
    private var streams: [UUID: Subscription] = [:]

    private struct Subscription {
        let continuation: AsyncStream<CoreEvent>.Continuation
        var pump: Task<Void, Never>?
    }

    public convenience init(eventPollMilliseconds: Int32 = 250) {
        self.init(eventPollMilliseconds: eventPollMilliseconds, drainMargin: .milliseconds(750)) { node, poll in
            node.events(pollMilliseconds: poll)
        }
    }

    init(eventPollMilliseconds: Int32, drainMargin: Duration, rawEvents: @escaping RawEvents) {
        self.eventPollMilliseconds = eventPollMilliseconds
        self.drainMargin = drainMargin
        self.rawEvents = rawEvents
    }

    /// 실행 중인 노드 핸들(테스트·진단용).
    public var handle: Int64? { lock.withLock { node?.handle } }

    // MARK: HostCore

    public func start(_ config: CoreConfig) async throws {
        let data = try encode(config)
        try await onQueue { [self] in
            if lock.withLock({ node != nil }) {
                throw APIErrorBody(code: "invalid_config", message: "코어가 이미 실행 중입니다.")
            }
            let started = try RDNode.start(config: data)
            lock.withLock { node = started }
        }
    }

    /// `rd_stop`을 부르고, 펌프가 원시 스트림에 남은 이벤트를 모두 넘긴 뒤(또는 기다림 한도가 지나면) 스트림을 끝낸다.
    public func stop() async {
        let finished: [Subscription] = await (try? onQueue { [self] in
            let (current, subscriptions) = lock.withLock { () -> (RDNode?, [Subscription]) in
                defer { node = nil; streams = [:] }
                return (node, Array(streams.values))
            }
            try? current?.stop()
            return subscriptions
        }) ?? []
        // rd_stop 뒤 원시 스트림은 다음 rd_next_event가 unknown_handle을 받으면 끝난다(최대 한 번의 poll).
        let limit = Duration.milliseconds(Int(eventPollMilliseconds)) + drainMargin
        let pumps = finished.compactMap(\.pump)
        if !pumps.isEmpty {
            // 펌프가 끝나거나 한도가 지나면 바로 돌아온다(펌프를 기다리는 쪽은 취소할 수 없어 작업 그룹을 쓰지 않는다).
            let gate = ResumeOnce()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gate.set(c)
                Task.detached {
                    for pump in pumps { await pump.value }
                    gate.resume()
                }
                Task.detached {
                    try? await Task.sleep(for: limit)
                    gate.resume()
                }
            }
        }
        // 끝나지 않은 펌프는 바깥 스트림이 끝나면(onTermination) 취소된다.
        finished.forEach { $0.continuation.finish() }
    }

    public func status() async throws -> CoreStatus {
        let data = try await call { try $0.status() }
        return try decode(CoreStatus.self, data)
    }

    public func publish(_ request: PublishRequest) async throws {
        let body = try encode(request)
        _ = try await call { try $0.publish(build: body) }
    }

    public func unpublish(buildID: String) async throws {
        _ = try await call { try $0.unpublish(buildID: buildID); return Data() }
    }

    public func publishResource(_ request: ResourcePublishRequest) async throws {
        let body = try encode(request)
        _ = try await call { try $0.publishResource(body) }
    }

    public func unpublishResource(id: String) async throws {
        _ = try await call { try $0.unpublishResource(id: id); return Data() }
    }

    public func setAgentBoard(_ board: Data) async throws {
        _ = try await call { try $0.setAgentBoard(board); return Data() }
    }

    public func setDevices(_ devices: [DeviceEntry]) async throws {
        let body = try encode(DeviceList(devices: devices))
        _ = try await call { try $0.setDevices(body); return Data() }
    }

    public func setDirect(_ on: Bool) async throws {
        _ = try await call { try $0.setDirect(on) }
    }

    public func openPairing(ttlSeconds: Int) async throws -> PairingCode {
        let ttl = Int32(clamping: ttlSeconds)
        let data = try await call { try $0.openPairing(ttlSeconds: ttl) }
        return try decode(PairingCode.self, data)
    }

    public func decidePairing(requestID: String, allow: Bool) async throws -> DeviceEntry? {
        let data = try await call { try $0.decidePairing(requestID: requestID, allow: allow) }
        return try decode(DecideReply.self, data).device
    }

    /// `start` 뒤의 코어 이벤트. 노드가 없으면 바로 끝난 스트림을 돌려준다. `stop`하면 끝난다.
    public func events() -> AsyncStream<CoreEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoreEvent.self, bufferingPolicy: .unbounded)
        let id = UUID()
        let current: RDNode? = lock.withLock {
            guard let node else { return nil }
            streams[id] = Subscription(continuation: continuation, pump: nil)
            return node
        }
        guard let current else {
            continuation.finish()
            return stream
        }
        let raw = rawEvents(current, eventPollMilliseconds)
        // 원시 스트림을 기다리기만 한다(블로킹 호출은 RDNode의 전용 스레드가 한다).
        // 원시 스트림이 끝나면(rd_stop 뒤) 남은 이벤트를 모두 넘긴 다음 끝낸다.
        let pump = Task.detached { [weak self] in
            let decoder = RDJSON.decoder()
            for await data in raw {
                if let event = try? decoder.decode(CoreEvent.self, from: data) {
                    continuation.yield(event)
                } else {
                    continuation.yield(.log(LogEvent(level: "warn", message: "코어 이벤트를 읽지 못했습니다.")))
                }
            }
            continuation.finish()
            self?.forget(id)
        }
        // stop이 기다릴 수 있게 펌프를 등록한다(이미 stop했으면 등록하지 않는다: stop이 스트림을 끝냈다).
        lock.withLock { streams[id]?.pump = pump }
        continuation.onTermination = { [weak self] _ in
            pump.cancel()
            self?.forget(id)
        }
        return stream
    }

    // MARK: 내부

    /// 계속(continuation)을 한 번만 재개한다.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var resumed = false

        func set(_ c: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock { () -> Bool in
                if resumed { return true }
                continuation = c
                return false
            }
            if resumeNow { c.resume() }
        }

        func resume() {
            let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard !resumed else { return nil }
                resumed = true
                defer { continuation = nil }
                return continuation
            }
            c?.resume()
        }
    }

    private struct DecideReply: Decodable {
        let device: DeviceEntry?
    }

    private func forget(_ id: UUID) {
        _ = lock.withLock { streams.removeValue(forKey: id) }
    }

    /// 실행 중인 노드로 직렬 큐에서 부른다. 노드가 없으면 `not_running`.
    private func call(_ body: @escaping @Sendable (RDNode) throws -> Data) async throws -> Data {
        try await onQueue { [self] in
            guard let node = lock.withLock({ node }) else {
                throw APIErrorBody(code: "not_running", message: "공유가 꺼져 있습니다.")
            }
            return try body(node)
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
            queue.async {
                do {
                    c.resume(returning: try body())
                } catch let error as RDCoreError {
                    c.resume(throwing: APIErrorBody(code: error.code, message: error.message))
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try RDJSON.encoder().encode(value)
        } catch {
            throw APIErrorBody(code: "bad_request", message: "코어에 보낼 값을 만들지 못했습니다.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try RDJSON.decoder().decode(type, from: data)
        } catch {
            throw APIErrorBody(code: "internal", message: "코어 응답을 읽지 못했습니다.")
        }
    }
}
