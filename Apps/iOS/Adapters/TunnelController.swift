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

        var errorDescription: String? {
            switch self {
            case .unavailable: TunnelStateMapping.simulatorUnavailableMessage
            case .notPrepared: "VPN 구성이 없습니다."
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

    /// VPN이 켜져 있거나 켜지거나 꺼지는 중이면 `true`. 다시 켜려면 먼저 끄고 `waitUntilStopped()`를 기다린다.
    var isTunnelActive: Bool { TunnelStateMapping.isActive(vpnStatus) }

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

    init(settings: TunnelSettingsStore) {
        self.settings = settings
        #if targetEnvironment(simulator)
        isAvailable = false
        state = .failed(message: TunnelStateMapping.simulatorUnavailableMessage)
        #else
        isAvailable = true
        state = .off
        #endif
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

    func connect() async throws {
        guard isAvailable else { throw ControllerError.unavailable }
        if manager?.connection.status == .disconnecting {
            // 끄는 중에 켜면 시작이 끄기에 묻힌다. 다 꺼진 뒤에 켠다.
            await waitUntilStopped()
        }
        if manager == nil || manager?.isEnabled == false {
            // 켜기 바로 앞에서 구성이 있고 켜져 있게 한다(다른 VPN을 고른 뒤일 수 있다).
            try await prepare()
        }
        guard let manager else { throw ControllerError.notPrepared }
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
        if Self.needsSave(existing: saved, desired: desired) {
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
        if status == .connecting || status == .connected, previous == .disconnected || previous == .invalid {
            // 앱 밖(설정 앱, 다른 실행)에서 켠 VPN도 끊기면 알린다.
            userStopped = false
        }

        if status == .disconnected, previous != .disconnected, previous != .invalid, !userStopped {
            // 이 앱에서 끄지 않았다. 확장이 오류로 끝났을 때만 다시 연결을 제안한다.
            // 설정 앱·제어 센터에서 끈 경우는 오류가 없으므로 꺼짐으로 둔다.
            let connection = manager.connection
            Task { [weak self] in
                let message = await Self.lastDisconnectMessage(connection)
                guard let self, self.vpnStatus == .disconnected else { return }
                self.disconnectMessage = message
                self.recompute()
            }
        }
        if status == .disconnected || status == .invalid {
            lastReply = nil
        }
        recompute()
        updatePolling(status)
    }

    private static func lastDisconnectMessage(_ connection: NEVPNConnection) async -> String? {
        do {
            try await connection.fetchLastDisconnectError()
            return TunnelStateMapping.disconnectMessage(for: nil)
        } catch {
            return TunnelStateMapping.disconnectMessage(for: error)
        }
    }

    private func recompute() {
        guard isAvailable else { return }
        publish(TunnelStateMapping.state(status: vpnStatus, reply: lastReply, disconnectMessage: disconnectMessage))
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
              let request = try? TunnelAppRequest.status.encoded()
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
