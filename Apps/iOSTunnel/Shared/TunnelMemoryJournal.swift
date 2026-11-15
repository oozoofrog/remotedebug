import Foundation

/// 터널 확장이 앱이 꺼져 있거나 뒤에 있는 동안의 사건(메모리 사용량, tailnet 상태, 네트워크 경로, Swiftail 로거 줄,
/// 종료 사유)을 남기는 곳(App Group 설정). 앱이 앞에 올 때 읽어 기기 로그로 옮긴 뒤 비운다.
enum TunnelMemoryJournal {
    static let key = "RemoteDebug.tunnel.memoryJournal"
    /// 쌓아 둘 줄 수. 넘으면 오래된 줄부터 버린다.
    static let limit = 200
    /// 확장 안의 여러 스레드(메모리 기록, 경로 알림, 상태 사건)가 동시에 쌓아도 줄을 잃지 않게 한다.
    private static let lock = NSLock()

    /// 확장: 한 줄을 더한다. 오래된 줄부터 버린다.
    static func append(_ line: String, at date: Date = Date(), defaults: UserDefaults = SharedContainer.defaults) {
        lock.withLock {
            var lines = defaults.stringArray(forKey: key) ?? []
            lines.append("\(ISO8601DateFormatter().string(from: date)) \(line)")
            defaults.set(Array(lines.suffix(limit)), forKey: key)
        }
    }

    /// 앱: 쌓인 줄을 가져가고 비운다.
    static func drain(defaults: UserDefaults = SharedContainer.defaults) -> [String] {
        let lines = defaults.stringArray(forKey: key) ?? []
        if !lines.isEmpty { defaults.removeObject(forKey: key) }
        return lines
    }
}
