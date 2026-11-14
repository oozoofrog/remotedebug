import Foundation
import NetworkExtension
import Observation
import os
import PhoneClientKit
import RDModels

/// `TunnelControlling`의 `NETunnelProviderManager` 구현.
///
/// - `reload()`: 앱 시작·복귀 때 저장된 구성을 읽기만 한다. 저장하거나 켜지 않는다(시스템에서 고른 다른 VPN을 바꾸지 않는다).
/// - `prepare()`: 사용자가 VPN을 켤 때만 불린다. 구성이 없거나 다르거나 꺼져 있으면 저장하고 켠다(`needsSave`).
/// - 상태: `NEVPNStatusDidChange` + 연결 중·연결됨에서 2초마다 확장에 `{"cmd":"status"}`를 물어
///   tailnet 상태(NeedsLogin·authURL·오류)를 `TunnelState`로 올린다.
/// - 앱 밖에서 꺼졌을 때는 `fetchLastDisconnectError()`로 이유를 읽는다. 확장 오류(엔진 사망 등)면 `failed`로 올려
///   다시 연결을 제안하고, 오류가 없으면(설정 앱·제어 센터에서 끔) 꺼짐으로 둔다.
///   On Demand 규칙이 없으면 iOS는 다시 시작하지 않는다(docs/tunnel.md 4).
/// - 넘겨받기(`connectOwn()`을 다른 앱의 VPN이 켜진 채 부름): iOS가 상대 터널을 내리면서 이 앱의 연결을 곧바로 끊으면
///   상대 터널이 내려가기를 기다려 다시 켠다(`VPNTakeover`, docs/protocol-addenda.md M.4). 그동안은 "연결 중"으로 보인다.
/// - `connectAutomatically()`: Mac이 필요한 동작 때문에 모델이 부른다. 저장된 구성이 있고 선택돼 있을 때만 켠다.
/// - 주문형 연결(선택, 기본 꺼짐): `syncOnDemand()`가 페어링한 Mac 이름으로 규칙을 저장하거나 지운다.
@MainActor
@Observable
final class TunnelController: TunnelControlling {
    /// 터널 확장의 번들 ID는 앱의 번들 ID + `.Tunnel`이다(번들 ID 앞부분은 팀마다 다를 수 있다).
    nonisolated static let providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "com.oozoofrog.app.RemoteDebugPhone") + ".Tunnel"
    nonisolated static let serverAddress = "RemoteDebug"
    static let pollInterval: Duration = .seconds(2)

    enum ControllerError: LocalizedError {
        case unavailable
        case notPrepared
        case notSelected

        var errorDescription: String? {
            switch self {
            case .unavailable: TunnelStateMapping.simulatorUnavailableMessage
            case .notPrepared: String(localized: "VPN 구성이 없습니다.")
            case .notSelected: String(localized: "iOS 설정에서 다른 VPN이 선택돼 있습니다.")
            }
        }
    }

    // MARK: 관찰 대상

    private(set) var state: TunnelState
    /// `false`면 VPN 컨트롤을 비활성화한다(시뮬레이터).
    private(set) var isAvailable: Bool
    private(set) var vpnStatus: NEVPNStatus = .invalid
    /// 확장이 마지막으로 돌려준 상태(진단용).
    private(set) var lastReply: TunnelStatusReply?
    /// 확장이 오류로 끝난 이유(`fetchLastDisconnectError`).
    private(set) var disconnectMessage: String?
    /// 마지막 넘겨받기에서 연결되기 전에 끊겨 다시 켠 횟수와 마지막 끊김의 오류(도메인·코드). 설치 기록에 남긴다.
    @ObservationIgnored private(set) var takeoverRestartsUsed = 0
    @ObservationIgnored private(set) var lastTakeoverDrop: String?

    /// VPN이 켜져 있거나 켜지거나 꺼지는 중이면 `true`. 다시 켜려면 먼저 끄고 `waitUntilStopped()`를 기다린다.
    var isTunnelActive: Bool { TunnelStateMapping.isActive(vpnStatus) || externalVPNActive }
    /// 이 앱의 VPN은 꺼져 있는데 기기에 tailnet 터널이 있다. 짝 앱(또는 다른 Tailscale 앱)이 VPN을 켜 둔 것이다.
    private(set) var externalVPNActive = false
    /// 공용 설정에 적힌, VPN을 켠 앱. 짝 앱이 켰는지 알릴 때 쓴다.
    private(set) var sharedState: SharedVPNState?
    /// 짝 앱이 VPN을 켜 두었는가.
    var pairedAppOwnsVPN: Bool {
        externalVPNActive && sharedState?.connected == true && sharedState?.owner == AppPair.otherAppID
    }

    /// 지금 VPN을 켜고 있는 쪽.
    var vpnHolder: VPNHolder {
        if TunnelStateMapping.isActive(vpnStatus) { return .thisApp }
        return pairedAppOwnsVPN ? .pairedApp : (externalVPNActive ? .other : .none)
    }

    /// 이 앱의 VPN 구성이 저장돼 있고 선택돼 있는지(마지막으로 읽은 값). `ready`일 때만 앱이 VPN을 자동으로 켠다.
    var autoStartConfiguration: VPNConfigurationState {
        guard isAvailable, let manager else { return .missing }
        return manager.isEnabled ? .ready : .disabled
    }

    /// 경로(직접·중계)를 알아볼 피어: 페어링한 Mac의 MagicDNS 이름. 앱이 넣는다.
    /// 주문형 연결이 켜져 있으면 그 규칙의 도메인도 이 이름이다.
    var pathPeer: String? {
        didSet {
            guard pathPeer != oldValue, settings.onDemand || onDemandActive else { return }
            Task { try? await syncOnDemand() }
        }
    }

    /// 이 앱의 터널에서 페어링한 Mac까지 가는 경로. 다른 앱의 VPN이거나 아직 모르면 `nil`.
    var peerPath: PeerPath? {
        guard vpnStatus == .connected, state == .connected else { return nil }
        return lastReply?.status?.peerPath
    }

    /// 저장된 구성에 주문형 연결 규칙이 켜져 있는가.
    private(set) var onDemandActive = false

    let settings: TunnelSettingsStore

    // MARK: 내부

    @ObservationIgnored private let logger = Logger(subsystem: "com.oozoofrog.app.RemoteDebugPhone", category: "vpn")
    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<TunnelState>.Continuation] = [:]
    @ObservationIgnored private var pendingAuthKey: String?
    @ObservationIgnored private var pendingResetLogin = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var prepareTask: Task<Void, any Error>?
    @ObservationIgnored private var statusObserver: (any NSObjectProtocol)?
    /// 사용자가 끄거나 다시 켜는 중이면 끊김을 오류로 보지 않는다.
    @ObservationIgnored private var userStopped = true
    /// 넘겨받는 중이면 다시 켠 횟수. 이 앱의 터널이 연결되거나, 그만두거나, 사용자가 끄면 `nil`.
    @ObservationIgnored private var takeoverRestarts: Int?
    @ObservationIgnored private var externalTask: Task<Void, Never>?

    init(settings: TunnelSettingsStore) {
        self.settings = settings
        #if targetEnvironment(simulator)
        isAvailable = false
        state = .failed(message: TunnelStateMapping.simulatorUnavailableMessage)
        #else
        isAvailable = true
        state = .off
        #endif
        externalTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshExternal()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            let connection = note.object as AnyObject?
            let identifier = connection.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                self?.statusDidChange(connectionID: identifier)
            }
        }
    }

    // MARK: TunnelControlling

    func currentState() -> TunnelState { state }

    func stateUpdates() -> AsyncStream<TunnelState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func prepare() async throws {
        guard isAvailable else { throw ControllerError.unavailable }
        if let running = prepareTask {
            try await running.value
            return
        }
        let task = Task { try await self.performPrepare() }
        prepareTask = task
        defer { prepareTask = nil }
        try await task.value
    }

    /// 다른 앱이 켠 VPN이 이미 있으면 그대로 쓴다. 이 앱의 터널로 옮기려면 `connectOwn()`을 부른다.
    func connect() async throws {
        refreshExternal()
        if externalVPNActive, pendingAuthKey == nil, !pendingResetLogin { return }
        try await connectOwn()
    }

    /// 이 앱의 터널을 켠다. 다른 앱의 VPN이 켜져 있으면 iOS가 그것을 끄고 이 앱의 것으로 바꾼다(넘겨받기).
    func connectOwn() async throws {
        guard isAvailable else { throw ControllerError.unavailable }
        refreshExternal()
        // 다른 VPN이 켜져 있을 때뿐 아니라, 이 앱의 구성이 선택돼 있지 않아 다시 저장해야 할 때도
        // iOS가 시작 직후 연결을 끊는 일이 있다(짝 앱이 VPN을 끈 직후). 같은 규칙으로 다시 켠다.
        takeoverRestarts = externalVPNActive || autoStartConfiguration != .ready ? 0 : nil
        takeoverRestartsUsed = 0
        lastTakeoverDrop = nil
        do {
            try await startOwn()
        } catch {
            takeoverRestarts = nil
            recompute()
            throw error
        }
    }

    private func startOwn() async throws {
        if manager?.connection.status == .disconnecting {
            // 끄는 중에 켜면 시작이 끄기에 묻힌다. 다 꺼진 뒤에 켠다.
            await waitUntilStopped()
        }
        // 다른 앱이 자기 구성을 켜면 이 앱의 구성은 선택이 풀린다. 메모리에 있는 값은 그 전의 것일 수 있다.
        try? await manager?.loadFromPreferences()
        if manager == nil || manager?.isEnabled == false {
            // 켜기 바로 앞에서 구성이 있고 켜져 있게 한다(다른 VPN을 고른 뒤일 수 있다).
            try await prepare()
        }
        guard let manager else { throw ControllerError.notPrepared }
        try start(manager)
    }

    /// 사용자 조작 없이 이 앱의 VPN을 켠다(Mac이 필요한 동작을 시작할 때).
    /// 구성을 만들거나 저장하지 않으므로 iOS의 "VPN 구성 추가" 동의가 뜨지 않고, 선택된 다른 VPN을 바꾸지 않는다.
    /// 다른 앱의 VPN이 켜져 있으면 그것을 그대로 쓴다.
    func connectAutomatically() async throws {
        guard isAvailable else { throw ControllerError.unavailable }
        refreshExternal()
        if externalVPNActive { return }
        guard let manager else { throw ControllerError.notPrepared }
        // 설정 앱에서 구성을 지웠거나 다른 VPN을 골랐을 수 있다. 다시 읽기만 한다.
        try await manager.loadFromPreferences()
        guard Self.isOurs(manager) else { throw ControllerError.notPrepared }
        guard manager.isEnabled else { throw ControllerError.notSelected }
        if manager.connection.status == .disconnecting { await waitUntilStopped() }
        try start(manager)
    }

    private func start(_ manager: NETunnelProviderManager) throws {
        if TunnelStateMapping.isActive(manager.connection.status) {
            // 이미 켜져 있거나 켜지는 중이다. 돌고 있는 터널에 startVPNTunnel을 다시 부르지 않는다.
            logger.log("VPN이 이미 켜져 있어 시작하지 않습니다")
            pendingAuthKey = nil
            statusDidChange(connectionID: nil)
            return
        }
        let options = TunnelStartOptions.options(authKey: pendingAuthKey, resetLogin: pendingResetLogin)
        pendingAuthKey = nil
        pendingResetLogin = false
        disconnectMessage = nil
        lastReply = nil
        userStopped = false
        do {
            try manager.connection.startVPNTunnel(options: options)
        } catch {
            userStopped = true
            logger.error("VPN 시작 실패: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        statusDidChange(connectionID: nil)
    }

    func disconnect() async {
        userStopped = true
        takeoverRestarts = nil
        disconnectMessage = nil
        manager?.connection.stopVPNTunnel()
        statusDidChange(connectionID: nil)
    }

    // MARK: 앱에서 부르는 것

    /// 앱 시작·포그라운드 복귀 때 저장된 구성과 현재 상태를 읽는다. 구성을 만들거나 저장하지 않는다.
    func reload() async {
        guard isAvailable else { return }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            if let found = managers.first(where: Self.isOurs) { adopt(found) }
        } catch {
            logger.error("VPN 구성을 읽지 못했습니다: \(error.localizedDescription, privacy: .public)")
        }
        statusDidChange(connectionID: nil)
    }

    /// 다음 `connect()`에서 저장된 Tailscale 로그인을 지우고 새로 로그인하게 한다.
    func setPendingResetLogin() {
        pendingResetLogin = true
    }

    /// 다음 `connect()`에 한 번만 실어 보낼 인증 키. 저장하지 않는다.
    func setPendingAuthKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAuthKey = trimmed.isEmpty ? nil : trimmed
    }

    /// VPN이 완전히 꺼질 때까지 최대 `timeout` 기다린다(인증 키로 다시 시작할 때).
    func waitUntilStopped(timeout: Duration = .seconds(8)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let status = manager?.connection.status ?? .invalid
            if status == .disconnected || status == .invalid { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 이 앱의 터널이 연결되거나 로그인·오류로 멈출 때까지 최대 20초 기다린다. 이 앱의 터널로 연결됐으면 `true`.
    /// 넘겨받는 중 다시 켜는 동안은 "연결 중"이므로 계속 기다린다.
    @discardableResult
    func waitUntilOwnTunnelSettles() async -> Bool {
        for _ in 0..<40 {
            if let settled = VPNTakeover.settled(state, ownActive: TunnelStateMapping.isActive(vpnStatus)) { return settled }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// 넘겨받는 중: 다른 앱의 터널(tailnet 인터페이스)이 내려갈 때까지 최대 `timeout` 기다린다. 내려가 있어도 잠깐은 쉰다.
    private func waitUntilOtherTunnelGone(timeout: Duration = .seconds(8)) async {
        try? await Task.sleep(for: .milliseconds(500))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, TailnetInterface.isUp() {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 넘겨받는 중 연결되기 전에 끊긴 이 앱의 터널을 다시 켠다.
    private func restartTakeover(_ count: Int) async {
        takeoverRestarts = count
        takeoverRestartsUsed = count
        logger.log("넘겨받는 중 VPN이 곧바로 끊겨 다른 터널이 내려가기를 기다려 다시 켭니다(\(count)/\(VPNTakeover.maxRestarts))")
        await waitUntilOtherTunnelGone()
        // 그사이 사용자가 끄거나 새로 켰다.
        guard takeoverRestarts == count, !userStopped, !TunnelStateMapping.isActive(vpnStatus) else { return }
        do {
            try await startOwn()
        } catch {
            logger.error("넘겨받는 중 VPN 다시 켜기 실패: \(error.localizedDescription, privacy: .public)")
            takeoverRestarts = nil
            disconnectMessage = TunnelStateMapping.droppedMessage
            recompute()
        }
    }

    // MARK: 구성

    private static func isOurs(_ manager: NETunnelProviderManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
    }

    /// 저장된 VPN 구성에서 저장 여부를 가르는 값.
    struct SavedConfiguration: Equatable {
        var isEnabled: Bool
        var providerBundleIdentifier: String?
        var serverAddress: String?
        var config: TunnelProviderConfig?
    }

    /// 구성을 저장(만들기·바꾸기·켜기)해야 하는지. 같으면 아무것도 저장하지 않는다.
    /// 사용자가 VPN을 켤 때만 쓰므로 꺼진 구성은 켜도록 저장한다.
    nonisolated static func needsSave(existing: SavedConfiguration?, desired: TunnelProviderConfig) -> Bool {
        guard let existing else { return true }
        return !existing.isEnabled
            || existing.config != desired
            || existing.providerBundleIdentifier != providerBundleIdentifier
            || existing.serverAddress != serverAddress
    }

    private func performPrepare() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let existing = managers.first(where: Self.isOurs)
        let target = existing ?? NETunnelProviderManager()
        let desired = settings.providerConfig()
        let proto = (target.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        let saved = existing.map { _ in
            SavedConfiguration(
                isEnabled: target.isEnabled,
                providerBundleIdentifier: proto.providerBundleIdentifier,
                serverAddress: proto.serverAddress,
                config: TunnelProviderConfig(providerConfiguration: proto.providerConfiguration)
            )
        }
        let onDemandChanged = Self.setOnDemand(
            Self.onDemandDomains(enabled: settings.onDemand && !AppPair.isVPNApp, host: pathPeer), on: target)
        if Self.needsSave(existing: saved, desired: desired) || onDemandChanged {
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = Self.serverAddress
            proto.providerConfiguration = try desired.providerConfiguration()
            target.protocolConfiguration = proto
            target.localizedDescription = "RemoteDebug"
            target.isEnabled = true
            do {
                try await target.saveToPreferences()
            } catch {
                logger.error("VPN 구성 저장 실패: \(error.localizedDescription, privacy: .public)")
                #if targetEnvironment(simulator)
                markUnavailable()
                #endif
                throw error
            }
            // 저장한 구성은 다시 불러와야 바로 시작할 수 있다.
            try await target.loadFromPreferences()
        }
        adopt(target)
    }

    private func adopt(_ manager: NETunnelProviderManager) {
        self.manager = manager
        let active = manager.isOnDemandEnabled
        if active != onDemandActive { onDemandActive = active }
    }

    // MARK: 주문형 연결 (docs/protocol-addenda.md N)

    /// 주문형 연결 규칙의 도메인. 설정이 꺼져 있거나 페어링한 Mac이 없으면 `nil`(규칙을 두지 않는다).
    nonisolated static func onDemandDomains(enabled: Bool, host: String?) -> [String]? {
        guard enabled, let host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        return [host]
    }

    /// 구성의 주문형 연결 규칙을 `domains`에 맞춘다. 바뀐 것이 있으면 `true`(저장해야 한다).
    private static func setOnDemand(_ domains: [String]?, on manager: NETunnelProviderManager) -> Bool {
        let current = (manager.onDemandRules ?? []).compactMap { $0 as? NEOnDemandRuleEvaluateConnection }
            .flatMap { $0.connectionRules ?? [] }.flatMap(\.matchDomains)
        let active = manager.isOnDemandEnabled && !(manager.onDemandRules ?? []).isEmpty
        guard let domains else {
            guard manager.isOnDemandEnabled || !(manager.onDemandRules ?? []).isEmpty else { return false }
            manager.onDemandRules = nil
            manager.isOnDemandEnabled = false
            return true
        }
        guard !active || current != domains else { return false }
        let rule = NEOnDemandRuleEvaluateConnection()
        rule.interfaceTypeMatch = .any
        rule.connectionRules = [NEEvaluateConnectionRule(matchDomains: domains, andAction: .connectIfNeeded)]
        manager.onDemandRules = [rule]
        manager.isOnDemandEnabled = true
        return true
    }

    /// 저장된 구성의 주문형 연결 규칙을 설정(`settings.onDemand`)과 페어링한 Mac(`pathPeer`)에 맞춘다.
    /// 구성이 없으면 만들지 않는다(`notPrepared`). 업데이트 앱의 구성에는 규칙을 두지 않는다.
    func syncOnDemand() async throws {
        guard isAvailable else { throw ControllerError.unavailable }
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let target = managers.first(where: Self.isOurs) else {
            if settings.onDemand, !AppPair.isVPNApp { throw ControllerError.notPrepared }
            return
        }
        let domains = Self.onDemandDomains(enabled: settings.onDemand && !AppPair.isVPNApp, host: pathPeer)
        if Self.setOnDemand(domains, on: target) {
            try await target.saveToPreferences()
            try await target.loadFromPreferences()
            logger.log("주문형 연결 \(domains == nil ? "끔" : "켬", privacy: .public)")
        }
        adopt(target)
    }

    private func markUnavailable() {
        isAvailable = false
        publish(.failed(message: TunnelStateMapping.simulatorUnavailableMessage))
    }

    // MARK: 상태

    private func statusDidChange(connectionID: ObjectIdentifier?) {
        guard isAvailable, let manager else { return }
        if let connectionID, connectionID != ObjectIdentifier(manager.connection) { return }
        let previous = vpnStatus
        let status = manager.connection.status
        vpnStatus = status
        if TunnelStateMapping.isActive(status) { externalVPNActive = false }
        // 이 앱의 터널이 붙었다. 이 뒤의 끊김은 넘겨받기와 상관없다.
        if status == .connected { takeoverRestarts = nil }
        if status == .connecting || status == .connected, previous == .disconnected || previous == .invalid {
            // 앱 밖(설정 앱, 다른 실행)에서 켠 VPN도 끊기면 알린다.
            userStopped = false
        }

        if status == .disconnected, previous != .disconnected, previous != .invalid, !userStopped {
            // 이 앱에서 끄지 않았다. 확장이 오류로 끝났을 때만 다시 연결을 제안한다.
            // 설정 앱·제어 센터에서 끈 경우는 오류가 없으므로 꺼짐으로 둔다.
            // 넘겨받는 중 iOS가 끊었으면(확장 오류가 아님) 실패로 올리지 않고 다시 켠다.
            let connection = manager.connection
            Task { [weak self] in
                let error = await Self.lastDisconnectError(connection)
                guard let self, self.vpnStatus == .disconnected else { return }
                if let done = self.takeoverRestarts {
                    let drop = Self.takeoverDrop(error)
                    if let error {
                        let nsError = error as NSError
                        self.lastTakeoverDrop = "\(nsError.domain) \(nsError.code)"
                        self.logger.log("넘겨받는 중 VPN이 끊김: \(nsError.domain, privacy: .public) \(nsError.code)")
                    }
                    if VPNTakeover.restarts(after: drop, restartsDone: done, userStopped: self.userStopped) {
                        await self.restartTakeover(done + 1)
                        return
                    }
                    self.takeoverRestarts = nil
                }
                self.disconnectMessage = TunnelStateMapping.disconnectMessage(for: error)
                self.recompute()
            }
        }
        if status == .disconnected || status == .invalid {
            lastReply = nil
        }
        recompute()
        updatePolling(status)
    }

    /// 마지막으로 끊긴 이유. 오류 없이 꺼졌으면(설정 앱·제어 센터에서 끔) `nil`.
    private static func lastDisconnectError(_ connection: NEVPNConnection) async -> (any Error)? {
        do {
            try await connection.fetchLastDisconnectError()
            return nil
        } catch {
            return error
        }
    }

    private static func takeoverDrop(_ error: (any Error)?) -> VPNTakeover.Drop {
        guard let error else { return .noError }
        return TunnelProviderError.kind(of: error) == nil ? .system : .tunnel
    }

    private func recompute() {
        guard isAvailable else { return }
        let mapped = externalVPNActive
            ? TunnelState.connected
            : TunnelStateMapping.state(status: vpnStatus, reply: lastReply, disconnectMessage: disconnectMessage)
        publish(VPNTakeover.displayedState(mapped, takingOver: takeoverRestarts != nil))
    }

    /// 이 앱의 VPN이 꺼져 있을 때 기기에 다른 tailnet 터널이 있는지 본다.
    func refreshExternal() {
        guard isAvailable else { return }
        let ownActive = TunnelStateMapping.isActive(vpnStatus)
        let external = !ownActive && TailnetInterface.isUp()
        let shared = SharedVPNState.read()
        guard external != externalVPNActive || shared != sharedState else { return }
        externalVPNActive = external
        sharedState = shared
        recompute()
    }

    private func publish(_ newState: TunnelState) {
        guard newState != state else { return }
        state = newState
        for continuation in continuations.values { continuation.yield(newState) }
    }

    private func updatePolling(_ status: NEVPNStatus) {
        guard TunnelStateMapping.shouldPoll(status) else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func pollOnce() async {
        guard let session = manager?.connection as? NETunnelProviderSession,
              TunnelStateMapping.shouldPoll(session.status),
              let request = try? TunnelAppRequest(cmd: .status, peer: pathPeer).encoded()
        else { return }
        let response: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(request) { data in
                    continuation.resume(returning: data)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        guard let response, let reply = TunnelStatusReply.decode(response) else { return }
        lastReply = reply
        recompute()
    }
}
