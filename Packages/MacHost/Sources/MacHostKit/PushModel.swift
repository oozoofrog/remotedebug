import Foundation
import Observation
import RDModels

/// 페어링한 iPhone에 새 빌드·파일 알림을 보낸다(docs/protocol-addenda.md P).
///
/// APNs 키가 없으면 목록 기준선만 따라가고 아무것도 보내지 않는다. 자동 알림은 공유 중일 때만 보낸다.
@MainActor
@Observable
public final class PushModel {
    /// 마지막 전송 결과.
    public struct Delivery: Sendable, Hashable {
        public var date: Date
        public var text: String
        public var failed: Bool
    }

    public private(set) var hasKey = false
    public private(set) var keyID = ""
    public private(set) var teamID = ""
    /// 알림에 앱·파일 이름을 넣지 않는다.
    public var hideNames: Bool {
        didSet { settings.hideNames = hideNames }
    }
    public private(set) var lastDelivery: Delivery?
    public private(set) var isSending = false
    /// 키 저장 실패 안내.
    public private(set) var setupError: String?

    /// 키·Key ID·Team ID가 모두 있다.
    public var isConfigured: Bool { client != nil }

    /// 알림을 받을 기기(지금 제어 서버에서 개발 환경 토큰을 등록한 기기).
    public var recipients: [DeviceEntry] { host.pushRecipients }

    /// 시험 알림 단추를 끈 이유. 보낼 수 있으면 nil.
    public var testUnavailableReason: String? {
        if !isConfigured { return "키를 저장해야 보낼 수 있습니다." }
        if recipients.isEmpty { return "알림을 켠 iPhone이 없습니다. iPhone 설정 화면에서 ‘새 빌드·파일 알림’을 켜세요." }
        return nil
    }

    @ObservationIgnored private let host: HostModel
    @ObservationIgnored private let keys: any APNsKeyStoring
    @ObservationIgnored private let settings: APNsSettingsStore
    @ObservationIgnored private let transport: any APNsTransport
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var client: APNsClient?
    /// 키 설정을 다시 읽을 때마다 늘어난다. 보내는 중에 바뀌면(키를 지움 등) 다음 기기부터 보내지 않는다.
    @ObservationIgnored private var clientGeneration = 0
    @ObservationIgnored private var tracker = PushTracker()
    @ObservationIgnored private var pending = PushBatch()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var deliveryTail: Task<Void, Never>?

    public init(
        host: HostModel,
        keys: any APNsKeyStoring = KeychainAPNsKeyStore(),
        defaults: UserDefaults = .standard,
        transport: any APNsTransport = URLSessionAPNsTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.host = host
        self.keys = keys
        self.settings = APNsSettingsStore(defaults: defaults)
        self.transport = transport
        self.now = now
        self.sleep = sleep
        self.hideNames = settings.hideNames
        reloadClient()
    }

    /// 키체인·설정에서 키를 다시 읽는다.
    /// 예전 클라이언트(서명 키와 JWT 캐시를 가진)는 버린다.
    private func reloadClient() {
        clientGeneration += 1
        keyID = settings.keyID
        teamID = settings.teamID
        let pem = keys.load()
        hasKey = pem != nil
        if let pem, let key = try? APNsKey.parse(pem), !keyID.isEmpty, !teamID.isEmpty {
            client = APNsClient(keyID: keyID, teamID: teamID, privateKey: key, transport: transport, now: now)
        } else {
            client = nil
        }
    }

    // MARK: 설정

    /// 키를 저장한다. `pem`이 nil이면 저장된 키를 그대로 두고 Key ID·Team ID만 바꾼다. 성공하면 true.
    @discardableResult
    public func save(pem: String?, keyID rawKeyID: String, teamID rawTeamID: String) -> Bool {
        setupError = nil
        do throws(APNsKeyFailure) {
            if let pem { _ = try APNsKey.parse(pem) } else if !hasKey { throw .missingKey }
            guard let keyID = APNsKey.normalizedID(rawKeyID) else { throw .badKeyID }
            guard let teamID = APNsKey.normalizedID(rawTeamID) else { throw .badTeamID }
            if let pem {
                do {
                    try keys.save(pem.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    setupError = "키를 키체인에 저장하지 못했습니다: \(HostErrorText.message(for: error))"
                    return false
                }
            }
            settings.keyID = keyID
            settings.teamID = teamID
        } catch {
            setupError = error.message
            return false
        }
        reloadClient()
        return isConfigured
    }

    /// 키와 Key ID·Team ID를 지운다. 이후 알림을 보내지 않는다.
    public func clearKey() {
        keys.clear()
        settings.keyID = ""
        settings.teamID = ""
        setupError = nil
        lastDelivery = nil
        pending = PushBatch()
        timer?.cancel()
        timer = nil
        reloadClient()
    }

    // MARK: 보내기

    /// HostModel이 빌드·보낸 파일 목록을 새로 읽었다.
    public func libraryChanged(builds: [LibraryBuild], resources: [ResourceDescriptor]) {
        let changes = tracker.observe(builds: builds.map(\.descriptor), resources: resources)
        guard !changes.isEmpty, isConfigured, host.isRunning else { return }
        pending.add(changes)
        timer?.cancel()
        timer = Task { [weak self, sleep] in
            do { try await sleep(PushPlanner.quietPeriod) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 쌓인 항목을 지금 보낸다.
    private func flush() {
        timer = nil
        let batch = pending
        pending = PushBatch()
        guard !batch.isEmpty, host.isRunning else { return }
        let notifications = PushPlanner.notifications(for: batch, hideNames: hideNames)
        enqueue { [weak self] in await self?.deliver(notifications) }
    }

    /// 시험 알림을 보낸다. 결과는 `lastDelivery`에 남는다.
    public func sendTest() async {
        guard testUnavailableReason == nil else {
            lastDelivery = Delivery(date: now(), text: testUnavailableReason ?? "", failed: true)
            return
        }
        let task = enqueue { [weak self] in await self?.deliver([PushPlanner.test]) }
        await task.value
    }

    /// 묶는 중이거나 보내는 중인 알림이 끝날 때까지 기다린다(시험용).
    public func waitForDelivery() async {
        while timer != nil || deliveryTail != nil {
            if let timer { await timer.value; if self.timer == timer { self.timer = nil } }
            if let tail = deliveryTail { await tail.value; if deliveryTail == tail { deliveryTail = nil } }
        }
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = deliveryTail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        deliveryTail = task
        return task
    }

    private func deliver(_ notifications: [APNsNotification]) async {
        guard let client, !notifications.isEmpty else { return }
        let generation = clientGeneration
        let targets = recipients
        guard !targets.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        var sent = 0
        var failures: [String] = []
        var removed = 0
        var stopped = false
        for device in targets {
            // 보내는 사이 키 설정이 바뀌었으면 들고 있던 클라이언트(예전 키)로 남은 기기에 보내지 않는다.
            guard generation == clientGeneration else {
                stopped = true
                break
            }
            guard let registration = device.push else { continue }
            var deviceFailed = false
            for notification in notifications {
                // 한 기기에 여러 개를 보내는 사이에도 키 설정이 바뀌었으면 멈춘다.
                guard generation == clientGeneration else {
                    stopped = true
                    deviceFailed = true
                    break
                }
                switch await client.send(notification, to: registration) {
                case .sent:
                    continue
                case .invalidToken:
                    await host.removePush(deviceID: device.id, token: registration.token)
                    removed += 1
                    deviceFailed = true
                case .rejected(let status, let reason):
                    failures.append("\(device.name): APNs가 거절했습니다(\(status)\(reason.isEmpty ? "" : " \(reason)"))")
                    deviceFailed = true
                case .networkFailure(let message):
                    failures.append("\(device.name): APNs에 닿지 못했습니다(\(message))")
                    deviceFailed = true
                }
                if deviceFailed { break }
            }
            if !deviceFailed { sent += 1 }
        }
        let title = notifications.count == 1 ? "‘\(notifications[0].body)’ 알림" : "알림 \(notifications.count)개"
        var parts: [String] = []
        if sent > 0 { parts.append("\(title)을 \(sent)대에 보냈습니다.") }
        if removed > 0 { parts.append("토큰이 더는 유효하지 않은 기기 \(removed)대의 알림 등록을 지웠습니다. 그 iPhone에서 알림을 다시 켜세요.") }
        parts += failures
        if stopped { parts.append("보내는 중에 키 설정이 바뀌어 나머지 기기에는 보내지 않았습니다.") }
        lastDelivery = Delivery(date: now(), text: parts.joined(separator: " "), failed: sent < targets.count)
    }
}
