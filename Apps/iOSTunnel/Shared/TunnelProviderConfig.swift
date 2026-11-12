import Foundation

/// 앱이 VPN 구성(`NETunnelProviderProtocol.providerConfiguration`)에 저장하고 터널 확장이 읽는 설정.
///
/// VPN 구성은 디스크에 남으므로 인증 키를 넣지 않는다. 인증 키는 `TunnelStartOptions`로
/// `startVPNTunnel(options:)`에만 실어 보낸다.
/// 이 파일은 앱(RemoteDebugPhone)과 확장(RemoteDebugTunnel) 양쪽 대상에 함께 컴파일된다.
struct TunnelProviderConfig: Codable, Equatable, Sendable {
    /// tailnet에 등록할 기기 이름(`rd-phone-<id8>`).
    var hostname: String
    /// 제어 서버 URL. 비면 Tailscale 기본 서버.
    var controlURL: String
    /// Go 런타임 메모리 한도(MiB). docs/tunnel.md 권장 28.
    var goMemLimitMiB: Int
    /// 코어 로그 파일을 남길지.
    var logging: Bool

    static let defaultGoMemLimitMiB = 28
    /// `providerConfiguration` 사전에서 이 설정(JSON)을 담는 키.
    static let providerConfigurationKey = "config"

    init(hostname: String, controlURL: String = "", goMemLimitMiB: Int = defaultGoMemLimitMiB, logging: Bool = false) {
        self.hostname = hostname
        self.controlURL = controlURL
        self.goMemLimitMiB = goMemLimitMiB
        self.logging = logging
    }

    enum CodingKeys: String, CodingKey { case hostname, controlURL, goMemLimitMiB, logging }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try c.decode(String.self, forKey: .hostname)
        controlURL = try c.decodeIfPresent(String.self, forKey: .controlURL) ?? ""
        goMemLimitMiB = try c.decodeIfPresent(Int.self, forKey: .goMemLimitMiB) ?? Self.defaultGoMemLimitMiB
        logging = try c.decodeIfPresent(Bool.self, forKey: .logging) ?? false
    }

    /// `rd-phone-` + 기기 식별자의 앞 8자(소문자 16진수). 16진수가 8자보다 적으면 0으로 채운다.
    static func hostname(nodeID: String) -> String {
        let hex = nodeID.lowercased().filter { $0.isHexDigit && $0.isASCII }
        let id8 = String((hex + "00000000").prefix(8))
        return "rd-phone-" + id8
    }

    /// `NETunnelProviderProtocol.providerConfiguration`에 넣을 사전.
    func providerConfiguration() throws -> [String: Any] {
        [Self.providerConfigurationKey: try JSONEncoder().encode(self)]
    }

    /// `providerConfiguration`에서 읽는다. 없거나 깨졌으면 `nil`.
    init?(providerConfiguration: [String: Any]?) {
        guard let data = providerConfiguration?[Self.providerConfigurationKey] as? Data,
              let config = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        self = config
    }
}

/// `startVPNTunnel(options:)`의 키. 확장은 처음 로그인에만 쓰고 보관하지 않는다.
enum TunnelStartOptions {
    static let authKey = "authKey"
    /// 저장된 Tailscale 로그인을 지우고 새로 로그인한다(다른 계정·tailnet으로 바꿀 때).
    static let resetLogin = "resetLogin"

    /// 인증 키나 로그인 초기화가 있으면 옵션 사전을, 없으면 `nil`.
    static func options(authKey: String?, resetLogin: Bool = false) -> [String: NSObject]? {
        var options: [String: NSObject] = [:]
        if let key = authKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            options[Self.authKey] = key as NSString
        }
        if resetLogin { options[Self.resetLogin] = NSNumber(value: true) }
        return options.isEmpty ? nil : options
    }

    static func resetsLogin(_ options: [String: NSObject]?) -> Bool {
        (options?[Self.resetLogin] as? NSNumber)?.boolValue ?? false
    }

    static func authKey(from options: [String: NSObject]?) -> String? {
        guard let key = (options?[Self.authKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }
}
