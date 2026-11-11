import Foundation

/// VPN 구성에 넣을 값(기기 식별자, 제어 서버 URL). 비밀이 아니므로 UserDefaults에 둔다.
@MainActor
final class TunnelSettingsStore {
    private let defaults: UserDefaults
    static let nodeIDKey = "RemoteDebug.tunnelNodeID"
    static let controlURLKey = "RemoteDebug.controlURL"
    static let loggingKey = "RemoteDebug.tunnelLogging"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
