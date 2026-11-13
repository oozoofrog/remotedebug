import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// 앱의 문제와 피드백을 개발자에게 보낸다.
///
/// - RemoteDebug로 설치한 빌드는 개발자의 Mac으로 바로 보낸다(이 iPhone에서 RemoteDebug 앱의 VPN이 켜져 있을 때).
/// - Mac에 닿지 않거나 Mac 주소가 없는 빌드는 메일로 보낸다. Debug 빌드는 로그와 화면 사진을 암호화해 붙인다.
///
/// ```swift
/// RemoteDebugFeedback.start(.init(macHost: "rd-mac-….ts.net", email: "dev@example.com", publicKeyBase64: "…"))
/// ```
public enum RemoteDebugFeedback {
    public struct Configuration: Sendable {
        /// RemoteDebug Mac 앱의 주소. Mac 앱의 프로젝트 화면이 알려 준다. 없으면 Mac으로 보내지 않는다.
        public var macHost: String?
        /// 피드백 메일을 받을 주소. 없으면 메일 경로를 쓰지 않는다.
        public var email: String?
        /// 메일에 붙는 진단을 암호화할 공개키(Mac 앱이 만든다). Debug 빌드에서만 쓴다.
        public var publicKeyBase64: String?

        public init(macHost: String? = nil, email: String? = nil, publicKeyBase64: String? = nil) {
            self.macHost = macHost
            self.email = email
            self.publicKeyBase64 = publicKeyBase64
        }
    }

    struct State {
        var configuration = Configuration()
        var client: FeedbackClient?
        var collector: AnyObject?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    /// 앱을 시작할 때 한 번 부른다. Mac 주소가 있으면 크래시 기록을 모으기 시작하고 쌓여 있던 기록을 보낸다.
    public static func start(_ configuration: Configuration) {
        var client: FeedbackClient?
        if let host = configuration.macHost, let endpoint = FeedbackClient.endpoint(host: host),
           let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            client = FeedbackClient(endpoint: endpoint, directory: base.appendingPathComponent("RemoteDebugFeedback", isDirectory: true))
        }
        withState { $0.configuration = configuration; $0.client = client }
        guard let client else { return }
        #if canImport(MetricKit) && os(iOS)
        let subscriber = CrashCollector(client: client)
        MXMetricManager.shared.add(subscriber)
        subscriber.handle(MXMetricManager.shared.pastDiagnosticPayloads)
        withState { $0.collector = subscriber }
        #endif
        Task { await client.flush() }
    }

    /// Mac 주소만으로 시작한다. 주소 형식이 아니면 `false`.
    @discardableResult
    public static func start(host: String) -> Bool {
        guard FeedbackClient.endpoint(host: host) != nil else { return false }
        start(Configuration(macHost: host))
        return true
    }

    /// 보낼 곳(Mac이나 메일)이 하나라도 설정됐는가.
    public static var isStarted: Bool {
        withState { $0.client != nil || !($0.configuration.email ?? "").isEmpty }
    }

    static var client: FeedbackClient? { withState { $0.client } }
    static var configuration: Configuration { withState { $0.configuration } }

    /// 피드백에 함께 갈 로그 한 줄을 남긴다. 최근 500줄만 메모리에 둔다.
    public static func log(_ message: String) {
        FeedbackLog.shared.add(message)
    }

    /// 화면 없이 피드백을 Mac으로 보낸다. 이번에 Mac이 받았으면 `true`, 쌓아 두기만 했거나 Mac 주소가 없으면 `false`.
    @discardableResult
    public static func send(_ message: String, details: String = "", image: Data? = nil) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty else { return false }
        return await client.submit(report(message: trimmed, details: details, image: image, date: Date()))
    }

    static func report(message: String, details: String, image: Data? = nil, date: Date) -> FeedbackReport {
        let stamp = ISO8601DateFormatter.fractional.string(from: date)
        var text = "\(message)\n\n---\n앱: \(bundleID) \(appVersion)\n기기: \(deviceSummary)\n보낸 시각: \(stamp)\n"
        if !details.isEmpty { text += details + "\n" }
        return FeedbackReport(kind: "feedback", name: "feedback-\(stamp.replacingOccurrences(of: ":", with: "")).txt",
                              bundleId: bundleID, appVersion: appVersion, crashedAt: stamp, text: text,
                              image: image?.base64EncodedString())
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    static var appName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "App"
    }

    static var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    static var appVersion: String { buildNumber.isEmpty ? shortVersion : "\(shortVersion) (\(buildNumber))" }

    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var deviceSummary: String { "\(deviceModel), \(ProcessInfo.processInfo.operatingSystemVersionString)" }
}

extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

#if canImport(MetricKit) && os(iOS)
/// 이 앱의 크래시를 MetricKit에서 받아 Mac에 보낸다. iOS는 크래시 뒤 다음 실행 때 알려 준다.
final class CrashCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    let client: FeedbackClient

    init(client: FeedbackClient) { self.client = client }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { handle(payloads) }

    func handle(_ payloads: [MXDiagnosticPayload]) {
        var reports: [FeedbackReport] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let stamp = ISO8601DateFormatter.fractional.string(from: payload.timeStampEnd)
                reports.append(FeedbackReport(
                    kind: "metrickit", name: "\(RemoteDebugFeedback.appName)-\(stamp.replacingOccurrences(of: ":", with: "")).json",
                    bundleId: RemoteDebugFeedback.bundleID,
                    appVersion: "\(crash.applicationVersion) (\(crash.metaData.applicationBuildVersion))",
                    crashedAt: stamp, text: String(decoding: crash.jsonRepresentation(), as: UTF8.self), image: nil))
            }
        }
        guard !reports.isEmpty else { return }
        let client = self.client
        Task { for report in reports { await client.submit(report) } }
    }
}
#endif
