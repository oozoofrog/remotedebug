import Foundation

/// VPN 구성에 넣을 값(기기 식별자, 제어 서버 URL). 비밀이 아니므로 UserDefaults(App Group의 공용 설정)에 둔다.
@MainActor
final class TunnelSettingsStore {
    private let defaults: UserDefaults
    static let nodeIDKey = "RemoteDebug.tunnelNodeID"
    static let controlURLKey = "RemoteDebug.controlURL"
    static let loggingKey = "RemoteDebug.tunnelLogging"

    /// 두 앱이 같은 기기 식별자와 제어 서버 주소를 쓰도록 공용 설정에 둔다.
    /// `legacy`(이 앱만의 예전 저장소)에 값이 있으면 처음 한 번 공용 설정으로 옮긴다.
    init(defaults: UserDefaults = SharedContainer.defaults, legacy: UserDefaults? = .standard) {
        self.defaults = defaults
        guard let legacy, legacy !== defaults, !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)
        for key in [Self.nodeIDKey, Self.controlURLKey, Self.loggingKey] {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    static let migratedKey = "RemoteDebug.tunnelSettingsMigrated"

    /// 처음 부를 때 만든 뒤 계속 같은 값을 쓴다. tailnet 기기 이름이 바뀌지 않게 한다.
    var nodeID: String {
        if let saved = defaults.string(forKey: Self.nodeIDKey), !saved.isEmpty { return saved }
        let created = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(created, forKey: Self.nodeIDKey)
        return created
    }

    var hostname: String { TunnelProviderConfig.hostname(nodeID: nodeID) }

    var controlURL: String {
        get { defaults.string(forKey: Self.controlURLKey) ?? "" }
        set { defaults.set(newValue, forKey: Self.controlURLKey) }
    }

    var logging: Bool {
        get { defaults.bool(forKey: Self.loggingKey) }
        set { defaults.set(newValue, forKey: Self.loggingKey) }
    }

    func providerConfig() -> TunnelProviderConfig {
        TunnelProviderConfig(hostname: hostname, controlURL: controlURL, logging: logging)
    }

    /// 빈 값이나 `https://호스트` 주소면 정리한 값을, 아니면 `nil`.
    nonisolated static func normalizedControlURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return nil }
        return trimmed
    }
}
