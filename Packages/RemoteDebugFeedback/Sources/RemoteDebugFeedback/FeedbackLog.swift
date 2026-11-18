import Foundation
import MachO
#if canImport(OSLog)
import OSLog
#endif

/// 피드백에 붙일 로그. 앱이 `RemoteDebugFeedback.log`로 남긴 줄과, 이 앱이 시스템 로그에 남긴 최근 줄을 모은다.
/// 기록이 허용되지 않은 동안(배포 빌드에서 사용자가 동의하기 전)에는 남기지도 모으지도 않는다.
final class FeedbackLog: @unchecked Sendable {
    static let shared = FeedbackLog()
    static let limit = 500
    static let lineLimit = 2000

    private let lock = NSLock()
    private var lines: [String] = []
    private let isAllowed: @Sendable () -> Bool

    init(isAllowed: @escaping @Sendable () -> Bool = { RemoteDebugFeedback.isRecordingAllowed }) {
        self.isAllowed = isAllowed
    }

    func add(_ message: String, at date: Date = Date()) {
        guard isAllowed() else { return }
        let line = "\(ISO8601DateFormatter.fractional.string(from: date)) \(message)"
        lock.lock()
        defer { lock.unlock() }
        // 잠그기를 기다리는 사이에 사용자가 동의를 거두고 `clear`가 지나갔을 수 있다. 잠근 뒤에 한 번 더 본다:
        // 동의를 거둔 뒤에 남는 줄이 없어야 한다.
        guard isAllowed() else { return }
        // 한 줄이 길어도 기록 전체가 커지지 않게 자른다.
        lines.append(line.count > Self.lineLimit ? String(line.prefix(Self.lineLimit)) + "…" : line)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// 남긴 줄을 모두 지운다.
    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    /// 앱이 남긴 줄인가. 줄을 남긴 이미지(`sender`)가 앱의 실행 파일이거나 앱 번들 안에 든 이미지(앱이 넣은 프레임워크)일 때만 받는다.
    /// 하위 시스템 이름은 빼는 데만 쓴다: Apple 것이면 뺀다. 이름이 붙어 있다고 받지는 않는다
    /// (시스템 라이브러리나 다른 SDK가 이 프로세스 안에서 제 이름으로 남긴 줄에는 앱이 모르는 값이 들어 있을 수 있다).
    static func isFromApp(subsystem: String, sender: String, appImages: Set<String>) -> Bool {
        if subsystem.hasPrefix("com.apple.") { return false }
        return !sender.isEmpty && appImages.contains(sender)
    }

    /// 앱의 실행 파일과 앱 번들 안에서 읽어 들인 이미지의 이름(`OSLogEntryLog.sender`와 견줄 값).
    static func appImageNames(bundlePath: String = Bundle.main.bundlePath,
                              executable: String? = Bundle.main.executableURL?.lastPathComponent,
                              loaded: [String] = loadedImagePaths()) -> Set<String> {
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let root = resolved(bundlePath)
        var names = Set(loaded.filter { resolved($0).hasPrefix(root + "/") }.map { ($0 as NSString).lastPathComponent })
        if let executable, !executable.isEmpty { names.insert(executable) }
        return names
    }

    /// 이 프로세스가 읽어 들인 이미지의 경로.
    static func loadedImagePaths() -> [String] {
        (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
    }

    /// 앱이 남긴 줄과 최근 `window`초 동안 이 프로세스가 시스템 로그에 남긴 줄(시스템 라이브러리의 줄 제외)을 시각 순으로. 최근 `limit`줄까지.
    func collect(window: TimeInterval = 900, limit: Int = 300) -> [String] {
        guard isAllowed() else { return [] }
        var all = recorded
        #if canImport(OSLog)
        if let store = try? OSLogStore(scope: .currentProcessIdentifier),
           let entries = try? store.getEntries(at: store.position(date: Date().addingTimeInterval(-window))) {
            let appImages = Self.appImageNames()
            for case let entry as OSLogEntryLog in entries where Self.isFromApp(subsystem: entry.subsystem, sender: entry.sender, appImages: appImages) {
                let origin = entry.subsystem.isEmpty ? "" : "[\(entry.subsystem):\(entry.category)] "
                all.append("\(ISO8601DateFormatter.fractional.string(from: entry.date)) \(origin)\(entry.composedMessage)")
            }
        }
        #endif
        return Array(all.sorted().suffix(limit))
    }
}
