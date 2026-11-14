// RDCoreBridge — rdcore.h C API(docs/protocol.md §9)의 Swift 래퍼.
//
// - 모든 함수는 JSON(Data)을 주고받는다. 코어가 돌려준 {"error":{"code","message"}}는 RDCoreError로 던진다.
//   JSON의 의미는 RDModels(RemoteDebugKit)가 해석한다. 이 패키지는 C 상호운용만 맡는다.
// - rd_next_event는 최대 timeout 동안 호출한 스레드를 막는다. 메인 스레드와 Swift 협력 스레드 풀에서
//   직접 부르지 말고 `events()`(전용 스레드)를 쓴다.
// - 코어의 모든 함수는 스레드 안전하다(핸들 표는 코어 안에서 잠금으로 보호한다).
import Foundation
import RDCoreC

/// 코어가 돌려준 오류. `code`는 docs/protocol.md §8과 docs/protocol-addenda.md의 코드다.
public struct RDCoreError: Error, Sendable, Equatable, Decodable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }
}

/// 실행 중인 코어 노드의 핸들.
public struct RDNode: Sendable, Hashable {
    public let handle: Int64

    public init(handle: Int64) {
        self.handle = handle
    }

    // MARK: 수명 주기

    /// `rd_start`. `config`는 CoreConfig JSON이다.
    public static func start(config: Data) throws -> RDNode {
        let reply = try RDCall.consume(rd_start(RDCall.string(config)))
        let decoded = try JSONDecoder().decode(StartReply.self, from: reply)
        return RDNode(handle: decoded.handle)
    }

    /// `rd_status`. CoreStatus JSON을 돌려준다.
    public func status() throws -> Data {
        try RDCall.consume(rd_status(handle))
    }

    /// `rd_stop`. 이후 이 핸들은 무효다.
    public func stop() throws {
        _ = try RDCall.consume(rd_stop(handle))
    }

    // MARK: 호스트 모드

    /// `rd_host_publish`. `build`는 BuildDescriptor 필드 + `ipaPath` JSON이다. `{"ok":true,"id":"b_…"}`.
    public func publish(build: Data) throws -> Data {
        try RDCall.consume(rd_host_publish(handle, RDCall.string(build)))
    }

    public func unpublish(buildID: String) throws {
        _ = try RDCall.consume(rd_host_unpublish(handle, buildID))
    }

    /// `rd_host_publish_resource`. `resource`는 ResourceDescriptor 필드 + `path` JSON이다. `{"ok":true,"id":"r_…"}`.
    public func publishResource(_ resource: Data) throws -> Data {
        try RDCall.consume(rd_host_publish_resource(handle, RDCall.string(resource)))
    }

    public func unpublishResource(id: String) throws {
        _ = try RDCall.consume(rd_host_unpublish_resource(handle, id))
    }

    /// `rd_host_set_agent_board`. `board`는 `GET /v1/agent`가 그대로 내는 JSON이다.
    public func setAgentBoard(_ board: Data) throws {
        _ = try RDCall.consume(rd_host_set_agent_board(handle, RDCall.string(board)))
    }

    /// `rd_host_set_devices`. `devices`는 `{"devices":[DeviceEntry]}` JSON이다. 허용 목록 전체를 교체한다.
    public func setDevices(_ devices: Data) throws {
        _ = try RDCall.consume(rd_host_set_devices(handle, RDCall.string(devices)))
    }

    /// `rd_host_set_direct`(docs/protocol-addenda.md O). 같은 네트워크 직접 연결 리스너를 켜거나 끈다.
    /// `{"ok":true,"direct":{"listening","port","id"}}`.
    public func setDirect(_ on: Bool) throws -> Data {
        try RDCall.consume(rd_host_set_direct(handle, on ? 1 : 0))
    }

    /// `rd_host_pairing_open`. `ttlSeconds <= 0`이면 코어 기본값(300초). `{"code","expiresAt"}`.
    public func openPairing(ttlSeconds: Int32 = 0) throws -> Data {
        try RDCall.consume(rd_host_pairing_open(handle, ttlSeconds))
    }

    /// `rd_host_pairing_decide`. 승인하면 `{"ok":true,"device":{…}}`, 거절하면 `{"ok":true}`.
    public func decidePairing(requestID: String, allow: Bool) throws -> Data {
        try RDCall.consume(rd_host_pairing_decide(handle, requestID, allow ? 1 : 0))
    }

    // MARK: 프록시 모드(진단용)

    /// `rd_proxy_start`. `{"addr":"127.0.0.1:P"}`.
    public func startProxy(listenAddress: String = "127.0.0.1:0") throws -> Data {
        try RDCall.consume(rd_proxy_start(handle, listenAddress))
    }

    // MARK: 터널 모드(docs/tunnel.md)

    /// `rd_tunnel_set_default_interface`. 기본 경로를 가진 인터페이스 이름(예: `en0`, `pdp_ip0`)을 알린다.
    /// 터널 확장이 `NWPathMonitor`의 경로가 바뀔 때마다 부른다. 빈 문자열은 무시된다.
    public func setDefaultInterface(_ name: String) throws {
        _ = try RDCall.consume(rd_tunnel_set_default_interface(handle, name))
    }

    /// `rd_tunnel_set_path_peer`. `rd_status`의 `peerPath`로 경로를 알릴 피어의 MagicDNS 이름. 빈 문자열이면 알리지 않는다.
    public func setPathPeer(_ fqdn: String) throws {
        _ = try RDCall.consume(rd_tunnel_set_path_peer(handle, fqdn))
    }

    // MARK: 이벤트

    /// `rd_next_event`. 시간 초과면 nil, 아니면 `event` 객체의 JSON을 돌려준다. 최대 `timeoutMilliseconds` 동안 막는다.
    public func nextEvent(timeoutMilliseconds: Int32) throws -> Data? {
        let reply = try RDCall.consume(rd_next_event(handle, timeoutMilliseconds))
        guard
            let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
            let event = object["event"], !(event is NSNull)
        else { return nil }
        return try JSONSerialization.data(withJSONObject: event)
    }

    /// 전용 스레드에서 `rd_next_event`를 반복해 이벤트(JSON)를 흘려 보낸다.
    /// 노드가 멈추거나(`unknown_handle`) 스트림 소비가 끝나면 종료한다.
    public func events(pollMilliseconds: Int32 = 1000) -> AsyncStream<Data> {
        let node = self
        return AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            let worker = EventWorker()
            worker.thread = Thread {
                while !worker.isCancelled {
                    do {
                        if let event = try node.nextEvent(timeoutMilliseconds: pollMilliseconds) {
                            continuation.yield(event)
                        }
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            worker.thread?.name = "RDNode.events"
            continuation.onTermination = { _ in worker.cancel() }
            worker.thread?.start()
        }
    }
}

// MARK: - 내부

private struct StartReply: Decodable {
    let handle: Int64
}

private struct ErrorEnvelope: Decodable {
    let error: RDCoreError?
}

/// 이벤트 스레드 취소 표시. `Thread`는 Sendable이 아니므로 잠금으로 보호한 상자에 담는다.
private final class EventWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var thread: Thread?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        thread?.cancel()
    }
}

/// iPhone 앱 자체 업데이트 페이지(`rd_update_page_set`, addenda I). 노드 핸들과 무관하다.
public enum RDUpdatePage {
    /// `config`는 `{"listen","publicURL","page"}` JSON. `{"ok":true,"addr":"127.0.0.1:P"}`를 돌려준다.
    public static func set(_ config: Data) throws -> Data {
        try RDCall.consume(rd_update_page_set(RDCall.string(config)))
    }
}

private enum RDCall {
    /// Data를 NUL 종료 문자열로 바꾼다(코어는 UTF-8 JSON만 받는다).
    static func string(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// 코어가 할당한 문자열을 복사하고 해제한다. 오류 JSON이면 던진다.
    static func consume(_ pointer: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let pointer else {
            throw RDCoreError(code: "internal", message: String(localized: "코어가 응답하지 않았습니다."))
        }
        defer { rd_free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data), let error = envelope.error {
            throw error
        }
        return data
    }
}
