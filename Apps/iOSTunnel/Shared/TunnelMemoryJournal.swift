import Foundation

/// 터널 확장이 앱이 꺼져 있거나 뒤에 있는 동안의 메모리 사용량을 남기는 곳(App Group 설정).
/// 확장이 5분마다 한 줄을 쌓고, 앱이 앞에 올 때 읽어 기기 로그로 옮긴 뒤 비운다.
enum TunnelMemoryJournal {
    static let key = "RemoteDebug.tunnel.memoryJournal"
    static let limit = 60

    /// 확장: 한 줄을 더한다. 오래된 줄부터 버린다.
    static func append(_ line: String, at date: Date = Date(), defaults: UserDefaults = SharedContainer.defaults) {
        var lines = defaults.stringArray(forKey: key) ?? []
        lines.append("\(ISO8601DateFormatter().string(from: date)) \(line)")
        defaults.set(Array(lines.suffix(limit)), forKey: key)
    }

    /// 앱: 쌓인 줄을 가져가고 비운다.
    static func drain(defaults: UserDefaults = SharedContainer.defaults) -> [String] {
        let lines = defaults.stringArray(forKey: key) ?? []
        if !lines.isEmpty { defaults.removeObject(forKey: key) }
        return lines
    }
}
