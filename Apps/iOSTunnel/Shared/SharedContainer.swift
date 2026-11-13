import Foundation

/// RemoteDebug 앱과 RemoteDebug VPN 앱, 두 앱의 터널 확장이 함께 쓰는 저장소(App Group).
///
/// 두 앱은 같은 tailnet 기기로 보여야 한다. 그래서 Tailscale 상태(`tailscaled.state`, 노드 키)와
/// 기기 식별자·제어 서버 주소를 App Group 컨테이너에 둔다. iOS는 VPN을 한 번에 하나만 켜므로
/// 두 확장이 같은 상태를 동시에 쓰는 일은 없다.
enum SharedContainer {
    /// Info.plist의 `RDAppGroup`(`group.<번들 ID 앞부분>.RemoteDebug`). 없으면 공용 저장소를 쓰지 않는다.
    static var groupID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "RDAppGroup") as? String, !id.isEmpty else { return nil }
        return id
    }

    /// 공용 컨테이너. App Group 권한이 없거나 시뮬레이터·시험이면 `nil`.
    static func groupURL() -> URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// 두 앱이 함께 읽고 쓰는 설정. 공용 컨테이너가 없으면 이 앱의 기본 저장소.
    static var defaults: UserDefaults {
        if groupURL() != nil, let id = groupID, let shared = UserDefaults(suiteName: id) { return shared }
        return .standard
    }

    /// 공용 컨테이너의 `Library/Application Support`. 없으면 `nil`.
    static func groupSupportDirectory() -> URL? {
        groupURL()?.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// 예전 위치(RemoteDebug 터널 확장의 컨테이너)의 Tailscale 상태를 공용 위치로 옮긴다.
    ///
    /// 예전 상태는 Mac과 페어링한 기기 정보다. 그래서 공용 위치에 다른 상태가 이미 있어도(RD VPN 앱을 먼저 켜서
    /// 새 기기가 만들어진 경우) 예전 상태가 이긴다. 밀려난 상태는 `tailscale.replaced`로 한 벌 남긴다.
    /// 옮겼으면 `true`.
    @discardableResult
    static func migrateState(from legacySupport: URL, to groupSupport: URL) -> Bool {
        let fm = FileManager.default
        let legacy = legacySupport.appendingPathComponent("RemoteDebug/tailscale", isDirectory: true)
        let target = groupSupport.appendingPathComponent("RemoteDebug/tailscale", isDirectory: true)
        guard hasState(legacy) else { return false }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                let replaced = target.deletingLastPathComponent().appendingPathComponent("tailscale.replaced", isDirectory: true)
                try? fm.removeItem(at: replaced)
                if hasState(target) { try fm.moveItem(at: target, to: replaced) } else { try fm.removeItem(at: target) }
            }
            try fm.moveItem(at: legacy, to: target)
            return true
        } catch {
            return false
        }
    }

    /// RemoteDebug 앱의 터널이 새 빌드로 한 번 켜져 예전 기기 정보를 공용 위치로 옮겼는가(옮길 것이 없었어도 참).
    static let storeMigratedKey = "RemoteDebug.storeStateMigrated"

    /// 폴더에 파일이 하나라도 있는가.
    static func hasState(_ dir: URL) -> Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty
    }
}

/// 지금 어느 앱의 터널이 VPN을 켜고 있는지. 터널 확장이 켜지고 꺼질 때 공용 설정에 적는다.
struct SharedVPNState: Codable, Equatable {
    /// VPN을 켠 앱의 번들 ID.
    var owner: String
    var connected: Bool
    var updatedAt: Date

    static let key = "RemoteDebug.sharedVPNState"

    static func read(_ defaults: UserDefaults = SharedContainer.defaults) -> SharedVPNState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SharedVPNState.self, from: data)
    }

    func write(_ defaults: UserDefaults = SharedContainer.defaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// 두 앱의 번들 ID와 서로를 여는 주소.
enum AppPair {
    static let storeSuffix = ".RemoteDebugPhone"
    static let vpnSuffix = ".RemoteDebugVPN"
    static let storeScheme = "remotedebug"
    static let vpnScheme = "remotedebug-vpn"

    /// 이 앱(또는 확장을 담은 앱)의 번들 ID.
    static var currentAppID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(".Tunnel") ? String(id.dropLast(".Tunnel".count)) : id
    }

    static var isVPNApp: Bool { currentAppID.hasSuffix(vpnSuffix) }

    /// 짝이 되는 앱의 번들 ID.
    static var otherAppID: String {
        let id = currentAppID
        if id.hasSuffix(vpnSuffix) { return String(id.dropLast(vpnSuffix.count)) + storeSuffix }
        if id.hasSuffix(storeSuffix) { return String(id.dropLast(storeSuffix.count)) + vpnSuffix }
        return ""
    }

    enum Action: String {
        /// VPN을 켠다.
        case connect
        /// VPN을 끈다.
        case disconnect
        /// 화면만 연다.
        case open
    }

    /// 짝 앱을 여는 주소. `returning`이면 일을 마친 뒤 이 앱으로 돌아온다.
    static func url(toOther action: Action, returning: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = isVPNApp ? storeScheme : vpnScheme
        components.host = "vpn"
        components.queryItems = [URLQueryItem(name: "action", value: action.rawValue)]
            + (returning ? [URLQueryItem(name: "return", value: "1")] : [])
        return components.url
    }

    /// 받은 주소에서 VPN 요청을 읽는다. VPN 요청이 아니면 `nil`.
    static func request(from url: URL) -> (action: Action, returning: Bool)? {
        guard let scheme = url.scheme?.lowercased(), scheme == storeScheme || scheme == vpnScheme, url.host == "vpn",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let action = items.first(where: { $0.name == "action" })?.value.flatMap(Action.init(rawValue:))
        else { return nil }
        return (action, items.contains { $0.name == "return" && $0.value == "1" })
    }
}

/// 이 기기에 tailnet 주소(100.64.0.0/10)를 가진 터널 인터페이스가 있는가. 어느 앱이 켰든 VPN이 켜져 있으면 참이다.
enum TailnetInterface {
    static func isUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("utun"),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if isTailnet(value) { return true }
        }
        return false
    }

    /// 100.64.0.0/10 범위인가.
    static func isTailnet(_ address: UInt32) -> Bool {
        address & 0xFFC0_0000 == 0x6440_0000
    }
}
