import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// 피드백에 붙일 로그. 앱이 `RemoteDebugFeedback.log`로 남긴 줄과, 이 앱이 시스템 로그에 남긴 최근 줄을 모은다.
final class FeedbackLog: @unchecked Sendable {
    static let shared = FeedbackLog()
    static let limit = 500

    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ message: String, at date: Date = Date()) {
        let line = "\(ISO8601DateFormatter.fractional.string(from: date)) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        lock.unlock()
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// 앱이 남긴 줄과 최근 `window`초 동안 이 프로세스가 시스템 로그에 남긴 줄(Apple 하위 시스템 제외)을 시각 순으로. 최근 `limit`줄까지.
    func collect(window: TimeInterval = 900, limit: Int = 300) -> [String] {
        var all = recorded
        #if canImport(OSLog)
        if let store = try? OSLogStore(scope: .currentProcessIdentifier),
           let entries = try? store.getEntries(at: store.position(date: Date().addingTimeInterval(-window))) {
            for case let entry as OSLogEntryLog in entries where !entry.subsystem.hasPrefix("com.apple.") {
                let origin = entry.subsystem.isEmpty ? "" : "[\(entry.subsystem):\(entry.category)] "
                all.append("\(ISO8601DateFormatter.fractional.string(from: entry.date)) \(origin)\(entry.composedMessage)")
            }
        }
        #endif
        return Array(all.sorted().suffix(limit))
    }
}
