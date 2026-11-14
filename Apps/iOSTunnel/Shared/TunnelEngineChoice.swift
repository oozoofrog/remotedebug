import Foundation

/// 어떤 구현으로 터널을 띄울지. Swiftail은 시험 빌드(`RD_SWIFTAIL_TUNNEL`)에서 설정 스위치를 켰을 때만 쓴다.
enum TunnelEngineChoice {
    static let swiftailKey = "RemoteDebug.tunnel.swiftail"

    static var isSwiftailAvailable: Bool {
        #if RD_SWIFTAIL_TUNNEL
        true
        #else
        false
        #endif
    }

    static var usesSwiftail: Bool {
        isSwiftailAvailable && SharedContainer.defaults.bool(forKey: swiftailKey)
    }
}
