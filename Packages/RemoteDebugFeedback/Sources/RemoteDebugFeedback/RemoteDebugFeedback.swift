import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// RemoteDebug로 설치한 Debug 빌드가 자기 크래시 기록과 피드백을 Mac에 보내게 한다.
///
/// ```swift
/// #if DEBUG
/// RemoteDebugFeedback.start(host: "rd-mac-….ts.net")   // Mac 앱의 프로젝트 화면이 알려 주는 주소
/// #endif
/// ```
///
/// 보내려면 이 iPhone에서 RemoteDebug 앱의 VPN이 켜져 있고 Mac과 페어링돼 있어야 한다.
/// 보내지 못한 기록은 앱 데이터 폴더에 남겨 두었다가 다음 실행이나 다음 보내기 때 다시 보낸다.
public enum RemoteDebugFeedback {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var client: FeedbackClient?
    nonisolated(unsafe) private static var collector: AnyObject?

    /// 앱을 시작할 때 한 번 부른다. 크래시 기록을 모으기 시작하고, 쌓여 있던 기록을 보낸다.
    /// `host`가 주소 형식이 아니면 아무것도 하지 않고 `false`를 돌려준다.
    @discardableResult
    public static func start(host: String) -> Bool {
        guard let endpoint = FeedbackClient.endpoint(host: host),
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let made = FeedbackClient(endpoint: endpoint, directory: base.appendingPathComponent("RemoteDebugFeedback", isDirectory: true))
        lock.lock()
        client = made
        lock.unlock()
        #if canImport(MetricKit) && os(iOS)
        let subscriber = CrashCollector(client: made)
        MXMetricManager.shared.add(subscriber)
        subscriber.handle(MXMetricManager.shared.pastDiagnosticPayloads)
        lock.lock()
        collector = subscriber
        lock.unlock()
        #endif
        Task { await made.flush() }
        return true
    }

    /// `start(host:)`를 불렀는가.
    public static var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return client != nil
    }

    /// 피드백을 보낸다. 이번에 Mac이 받았으면 `true`, 쌓아 두기만 했으면 `false`.
    @discardableResult
    public static func send(_ message: String, details: String = "") async -> Bool {
        let current = currentClient()
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current, !trimmed.isEmpty else { return false }
        return await current.submit(report(message: trimmed, details: details, date: Date()))
    }

    private static func currentClient() -> FeedbackClient? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }

    static func report(message: String, details: String, date: Date) -> FeedbackReport {
        let stamp = ISO8601DateFormatter.fractional.string(from: date)
        var text = "\(message)\n\n---\n앱: \(bundleID) \(appVersion)\n기기: \(deviceSummary)\n보낸 시각: \(stamp)\n"
        if !details.isEmpty { text += details + "\n" }
        return FeedbackReport(kind: "feedback", name: "feedback-\(stamp.replacingOccurrences(of: ":", with: "")).txt",
                              bundleId: bundleID, appVersion: appVersion, crashedAt: stamp, text: text)
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    static var deviceSummary: String {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(model), \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
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
                let name = (Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App")
                    + "-\(stamp.replacingOccurrences(of: ":", with: "")).json"
                reports.append(FeedbackReport(
                    kind: "metrickit", name: name, bundleId: RemoteDebugFeedback.bundleID,
                    appVersion: "\(crash.applicationVersion) (\(crash.metaData.applicationBuildVersion))",
                    crashedAt: stamp, text: String(decoding: crash.jsonRepresentation(), as: UTF8.self)))
            }
        }
        guard !reports.isEmpty else { return }
        let client = self.client
        Task { for report in reports { await client.submit(report) } }
    }
}
#endif
