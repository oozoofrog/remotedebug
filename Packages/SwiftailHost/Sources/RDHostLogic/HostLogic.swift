import Foundation
import RDModels

// 공개 접점: HostLogic(options:), handle(_:), publish(_:), unpublish(buildID:), publishResource(_:),
// unpublishResource(id:), setAgentBoard(_:), setDevices(_:), openPairing(ttlSeconds:),
// decidePairing(requestID:allow:), counts(), deviceStableIDs(), sweep(), close().
// JSON 입력 접점: publish(json:), publishResource(json:), setDevices(json:).
// 전송 중 취소·진행률·읽기 오류는 HostFileTransferMonitoring의 추가 접점으로 알린다.
// Options의 사건 콜백은 순서대로 동기 호출된다. 콜백에서는 오래 기다리거나 다른 스레드의 호스트 호출을 기다리지 않는다.
public final class HostLogic: HostRequestHandling, @unchecked Sendable {
    public struct Info: Sendable {
        public var hostID: String
        public var hostName: String
        public var fqDN: String
        public var appVersion: String
        public init(hostID: String, hostName: String, fqDN: String, appVersion: String) {
            (self.hostID, self.hostName, self.fqDN, self.appVersion) = (hostID, hostName, fqDN, appVersion)
        }
    }

    public struct DirectInfo: Sendable {
        public var id: String
        public var port: Int
        public var spki: String
        public init(id: String, port: Int, spki: String) { (self.id, self.port, self.spki) = (id, port, spki) }
    }

    public struct Limits: Sendable {
        public var pairRequestTTL: TimeInterval
        public var pairMaxFailures: Int
        public var sessionTTL: TimeInterval
        public var sessionMaxTTL: TimeInterval
        public var manifestMaxFetches: Int
        public init(pairRequestTTL: TimeInterval = 120, pairMaxFailures: Int = 5,
                    sessionTTL: TimeInterval = 180, sessionMaxTTL: TimeInterval = 600, manifestMaxFetches: Int = 5) {
            self.pairRequestTTL = pairRequestTTL == 0 ? 120 : pairRequestTTL
            self.pairMaxFailures = pairMaxFailures == 0 ? 5 : pairMaxFailures
            self.sessionTTL = sessionTTL == 0 ? 180 : sessionTTL
            self.sessionMaxTTL = sessionMaxTTL == 0 ? 600 : sessionMaxTTL
            self.manifestMaxFetches = manifestMaxFetches == 0 ? 5 : manifestMaxFetches
        }
    }

    public struct Options: Sendable {
        public var now: @Sendable () -> Date
        public var publishDirectory: String
        public var info: @Sendable () -> Info
        public var baseURL: @Sendable () -> String
        public var limits: Limits
        public var direct: @Sendable () -> DirectInfo?
        public var events: @Sendable (CoreEvent) -> Void
        public var updatePageURL: @Sendable () -> String
        public var eventDetails: (@Sendable (EmittedEvent) -> Void)?
        /// USB 케이블 설치(protocol-addenda Q). nil이면 그 경로는 `404 not_found`다.
        public var cableInstaller: (any HostCableInstalling)?
        public init(publishDirectory: String, info: @escaping @Sendable () -> Info,
                    baseURL: @escaping @Sendable () -> String, now: @escaping @Sendable () -> Date = { Date() },
                    limits: Limits = Limits(), direct: @escaping @Sendable () -> DirectInfo? = { nil },
                    events: @escaping @Sendable (CoreEvent) -> Void,
                    updatePageURL: @escaping @Sendable () -> String = { "" },
                    eventDetails: (@Sendable (EmittedEvent) -> Void)? = nil,
                    cableInstaller: (any HostCableInstalling)? = nil) {
            self.publishDirectory = publishDirectory
            self.info = info
            self.baseURL = baseURL
            self.now = now
            self.limits = limits
            self.direct = direct
            self.events = events
            self.updatePageURL = updatePageURL
            self.eventDetails = eventDetails
            self.cableInstaller = cableInstaller
        }
    }

    public struct PairingCode: Sendable {
        public var code: String
        public var expiresAt: Date
        public var displayCode: String { HostIDs.displayPairCode(code) }
    }

    let options: Options
    let publishDirectory: String
    let snapshotDirectory: String
    // 모든 가변 상태와 사건 순서는 이 잠금으로 보호한다. 본문 읽기 동안은 잠그지 않는다.
    let lock = NSRecursiveLock()
    var closed = false
    var devices: [String: DeviceEntry] = [:]
    var deviceWireDates: [String: String] = [:]
    var pairCode: PairCode?
    var pairRequests: [String: PairRequest] = [:]
    var builds: [String: Build] = [:]
    var resources: [String: Resource] = [:]
    var sessions: [String: Session] = [:]
    var tokens: [String: Session] = [:]
    var fileTransfers: [String: FileTransfer] = [:]
    var denials: [String: Denial] = [:]
    var directFailures: [String: DirectFailure] = [:]
    var agentBoard = Data(#"{"enabled":false,"projects":[],"agents":[],"requests":[]}"#.utf8)
    var agentEnabled = false

    public init(options: Options) throws {
        self.options = options
        let fm = FileManager.default
        guard !options.publishDirectory.isEmpty else { throw HostErrors.make("invalid_config", "publishDir가 필요합니다.") }
        let directory = URL(fileURLWithPath: options.publishDirectory).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw HostErrors.make("invalid_config", "publishDir를 찾을 수 없습니다.")
        }
        guard isDirectory.boolValue else { throw HostErrors.make("invalid_config", "publishDir가 폴더가 아닙니다.") }
        publishDirectory = directory.path
        snapshotDirectory = directory.appendingPathComponent(".rd-snapshots").path
        do {
            if (try? fm.attributesOfItem(atPath: snapshotDirectory)) != nil { try fm.removeItem(atPath: snapshotDirectory) }
        } catch { throw HostErrors.make("invalid_config", "게시 폴더의 .rd-snapshots를 비울 수 없습니다.") }
        do { try fm.createDirectory(atPath: snapshotDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw HostErrors.make("invalid_config", "게시 폴더에 .rd-snapshots를 만들 수 없습니다.") }
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func emit(_ event: CoreEvent, receivedAt: Date? = nil, nodeName: String? = nil, deviceID: String? = nil) {
        options.events(event)
        let wireDate: String?
        switch event {
        case .deviceAdded(let device), .deviceUpdated(let device):
            wireDate = deviceWireDates[device.nodeStableId].flatMap { $0 == hostTimestamp(device.pairedAt) ? nil : $0 }
        default: wireDate = nil
        }
        options.eventDetails?(EmittedEvent(event: event, receivedAt: receivedAt, nodeName: nodeName, deviceID: deviceID, devicePairedAt: wireDate))
    }

    public func counts() -> (builds: Int, devices: Int) { locked { (builds.count, devices.count) } }
    public func deviceStableIDs() -> [String] { locked { Array(devices.keys) } }

    public func setDevices(_ entries: [DeviceEntry]) throws {
        var next: [String: DeviceEntry] = [:]
        for entry in entries {
            guard !entry.nodeStableId.isEmpty else { throw HostErrors.make("bad_request", "nodeStableId가 비어 있습니다.") }
            next[entry.nodeStableId] = entry
        }
        locked {
            devices = next
            deviceWireDates.removeAll()
            for session in sessions.values where next[session.peer.stableID] == nil { failSession(session) }
        }
    }

    public func openPairing(ttlSeconds: Int) throws -> PairingCode {
        guard ttlSeconds <= 3600 else { throw HostErrors.make("bad_request", "ttl_seconds는 3600 이하여야 합니다.") }
        return locked {
            let value = PairingCode(code: HostIDs.newPairCode(), expiresAt: options.now().addingTimeInterval(ttlSeconds <= 0 ? 300 : Double(ttlSeconds)))
            pairCode = PairCode(value: value)
            return value
        }
    }

    public func decidePairing(requestID: String, allow: Bool) throws -> DeviceEntry? {
        try locked {
            guard let request = pairRequests[requestID] else { throw HostErrors.make("bad_request", "알 수 없는 페어링 요청입니다.") }
            expirePair(request, now: options.now())
            guard request.state == .pending else {
                throw HostErrors.make("bad_request", "이미 처리되었거나 만료된 페어링 요청입니다: " + request.state.rawValue)
            }
            request.state = allow ? .approved : .denied
            var device: DeviceEntry?
            if allow {
                let entry = DeviceEntry(id: devices[request.peer.stableID]?.id ?? HostIDs.newID("d_"), name: request.name,
                                        nodeStableId: request.peer.stableID, nodeName: request.peer.nodeName,
                                        loginName: request.peer.loginName, pairedAt: options.now())
                devices[entry.nodeStableId] = entry
                deviceWireDates.removeValue(forKey: entry.nodeStableId)
                device = entry
                emit(.deviceAdded(entry))
            }
            emit(.pairDecided(.init(requestId: request.id, state: request.state)))
            return device
        }
    }

    func expirePair(_ request: PairRequest, now: Date) {
        if request.state == .pending && now >= request.expires {
            request.state = .expired
            emit(.pairDecided(.init(requestId: request.id, state: .expired)))
        }
    }

    public func setAgentBoard(_ board: Data) throws {
        guard board.count <= 2 << 20 else { throw HostErrors.make("bad_request", "에이전트 상태 JSON이 너무 큽니다(최대 2MiB).") }
        let object: HostJSON
        do { object = try HostJSON(data: board, singleValue: true) }
        catch { throw HostErrors.make("bad_request", "에이전트 상태 JSON을 읽지 못했습니다.") }
        let enabled: Bool
        do { enabled = try object.bool("enabled") }
        catch { throw HostErrors.make("bad_request", "에이전트 상태 JSON을 읽지 못했습니다.") }
        locked { agentBoard = board; agentEnabled = enabled }
    }

    public func sweep() {
        locked {
            let now = options.now()
            for (id, request) in pairRequests {
                expirePair(request, now: now)
                if request.state != .pending && now.timeIntervalSince(request.expires) > 3600 { pairRequests.removeValue(forKey: id) }
            }
            for (id, session) in sessions {
                expireSession(session, now: now)
                if session.terminal && session.inflight == 0 && now.timeIntervalSince(session.expires) > 3600 {
                    sessions.removeValue(forKey: id)
                    tokens.removeValue(forKey: session.token)
                }
            }
            denials = denials.filter { $0.value.suppressed != 0 || now.timeIntervalSince($0.value.last) < 5 }
            directFailures = directFailures.filter { now.timeIntervalSince($0.value.first) < 60 }
        }
    }

    public func close() {
        locked {
            closed = true
            for session in sessions.values { failSession(session) }
            for build in builds.values { try? FileManager.default.removeItem(atPath: build.file.path) }
            for resource in resources.values { if let file = resource.file { try? FileManager.default.removeItem(atPath: file.path) } }
            builds.removeAll()
            resources.removeAll()
        }
    }

    struct Denial { var last: Date; var suppressed = 0 }
    struct DirectFailure { var first: Date; var count: Int }
    final class PairCode {
        var value: PairingCode
        var failures = 0
        var burned = false
        init(value: PairingCode) { self.value = value }
    }
    final class PairRequest {
        let id: String
        let peer: HostPeer
        let name: String
        let expires: Date
        var state = PairState.pending
        init(id: String, peer: HostPeer, name: String, expires: Date) {
            (self.id, self.peer, self.name, self.expires) = (id, peer, name, expires)
        }
    }
}
