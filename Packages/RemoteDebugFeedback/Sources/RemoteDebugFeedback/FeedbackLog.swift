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

    /// 앱이 남긴 줄인가. 앱 실행 파일이 직접 남겼거나, Apple 것이 아닌 하위 시스템 이름이 붙은 줄만 받는다.
    /// 시스템 라이브러리가 이 프로세스 안에서 남긴 줄은 뺀다.
    static func isFromApp(subsystem: String, sender: String, process: String) -> Bool {
        if subsystem.hasPrefix("com.apple.") { return false }
        return !subsystem.isEmpty || sender == process
    }

    /// 앱이 남긴 줄과 최근 `window`초 동안 이 프로세스가 시스템 로그에 남긴 줄(시스템 라이브러리의 줄 제외)을 시각 순으로. 최근 `limit`줄까지.
    func collect(window: TimeInterval = 900, limit: Int = 300) -> [String] {
        var all = recorded
        #if canImport(OSLog)
        if let store = try? OSLogStore(scope: .currentProcessIdentifier),
           let entries = try? store.getEntries(at: store.position(date: Date().addingTimeInterval(-window))) {
            for case let entry as OSLogEntryLog in entries where Self.isFromApp(subsystem: entry.subsystem, sender: entry.sender, process: entry.process) {
                let origin = entry.subsystem.isEmpty ? "" : "[\(entry.subsystem):\(entry.category)] "
                all.append("\(ISO8601DateFormatter.fractional.string(from: entry.date)) \(origin)\(entry.composedMessage)")
            }
        }
        #endif
        return Array(all.sorted().suffix(limit))
    }
}
