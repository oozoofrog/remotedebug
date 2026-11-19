import Foundation
#if DEBUG && canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// 앱의 문제와 피드백을 개발자에게 보낸다.
///
/// - Debug 빌드는 개발자의 Mac으로 바로 보낸다(이 iPhone에서 RemoteDebug 앱의 VPN이 켜져 있을 때).
/// - Mac에 닿지 않는 Debug 빌드와 모든 배포 빌드는 메일로 보낸다. 사용자가 고른 사진과 파일은 메일에 그대로 붙고, 로그는 사용자가 켰을 때 암호화해 붙인다.
/// - 배포 빌드에는 Mac으로 보내는 코드, 크래시 수집, 확인 목록이 들어가지 않는다. 네트워크 요청을 하지 않고,
///   사용자가 로그 기록에 동의하기 전에는 로그를 남기지도 모으지도 않는다(`setRecordingConsent`).
///
/// ```swift
/// RemoteDebugFeedback.start(.init(macHost: "rd-mac-….ts.net", email: "dev@example.com", publicKeyBase64: "…"))
/// ```
public enum RemoteDebugFeedback {
    public struct Configuration: Sendable {
        /// RemoteDebug Mac 앱의 주소. Mac 앱의 프로젝트 화면이 알려 준다. 없으면 Mac으로 보내지 않는다.
        /// 배포 빌드는 이 값을 쓰지 않는다. 주소 글자가 배포판에 들어가지 않게 `#if DEBUG` 안에서만 넣는다.
        public var macHost: String?
        /// 피드백 메일을 받을 주소. 없으면 메일 경로를 쓰지 않는다.
        public var email: String?
        /// 메일에 붙는 진단을 암호화할 공개키(Mac 앱이 만든다). 사용자가 로그를 붙이기로 했을 때만 쓴다.
        public var publicKeyBase64: String?
        /// Debug 빌드에서도 배포 빌드처럼 동의가 있어야 로그를 남기게 한다. 동의 화면을 개발 빌드에서 확인할 때 켠다.
        /// 배포 빌드는 이 값과 상관없이 언제나 동의가 필요하다.
        public var requiresConsentInDebug: Bool

        public init(macHost: String? = nil, email: String? = nil, publicKeyBase64: String? = nil,
                    requiresConsentInDebug: Bool = false) {
            self.macHost = macHost
            self.email = email
            self.publicKeyBase64 = publicKeyBase64
            self.requiresConsentInDebug = requiresConsentInDebug
        }
    }

    struct State {
        var configuration = Configuration()
        /// 로그 기록에 동의가 필요한가. 배포 빌드는 언제나 참이다.
        var requiresConsent = FeedbackConsent.requiredByBuild
        /// 동의 표시 파일과 보내지 못한 기록을 두는 폴더. 시험에서 바꿔 넣는다.
        var storage = RemoteDebugFeedback.storageDirectory
        var consent = FeedbackConsent(directory: RemoteDebugFeedback.storageDirectory)
        /// 피드백을 보낼 때 다른 기기에 로그 묶음을 요청하는 방법(`setPeerRequest`).
        var peerRequest: PeerRequest?
        #if DEBUG
        var client: FeedbackClient?
        var collector: AnyObject?
        var checklist: [FeedbackCheckItem] = []
        #endif
    }

    /// 이 패키지가 앱 데이터 폴더에 쓰는 곳: 동의 표시 파일과, Debug 빌드에서 Mac에 보내지 못한 기록.
    static var storageDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RemoteDebugFeedback", isDirectory: true)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    /// 앱을 시작할 때 한 번 부른다. Debug 빌드는 Mac 주소가 있으면 크래시 기록을 모으기 시작하고 쌓여 있던 기록을 보낸다.
    /// 배포 빌드는 설정을 기억하고 앞서 남은 진단 파일을 지울 뿐, 어디에도 연결하지 않는다.
    public static func start(_ configuration: Configuration) {
        withState {
            $0.configuration = configuration
            $0.requiresConsent = FeedbackConsent.requiredByBuild || configuration.requiresConsentInDebug
        }
        FeedbackSession.removeLeftovers()
        // 동의가 없는데 앞서 남긴 것이 있으면(동의를 거둔 뒤 지우지 못한 경우) 지금 지운다.
        if !isRecordingAllowed { deleteRecorded() }
        #if DEBUG
        var client: FeedbackClient?
        if let host = configuration.macHost, let endpoint = FeedbackClient.endpoint(host: host), let directory = withState({ $0.storage }) {
            client = FeedbackClient(endpoint: endpoint, directory: directory)
        }
        withState { $0.client = client }
        guard let client else { return }
        #if canImport(MetricKit) && os(iOS)
        let subscriber = CrashCollector(client: client)
        MXMetricManager.shared.add(subscriber)
        subscriber.handle(MXMetricManager.shared.pastDiagnosticPayloads)
        withState { $0.collector = subscriber }
        #endif
        Task { await client.flush() }
        #endif
    }

    /// Mac 주소만으로 시작한다. 주소 형식이 아니면 `false`. 배포 빌드에서는 아무것도 하지 않고 `false`.
    @discardableResult
    public static func start(host: String) -> Bool {
        #if DEBUG
        guard FeedbackClient.endpoint(host: host) != nil else { return false }
        start(Configuration(macHost: host))
        return true
        #else
        return false
        #endif
    }

    /// 보낼 곳(Mac이나 메일)이 하나라도 설정됐는가.
    public static var isStarted: Bool {
        #if DEBUG
        withState { $0.client != nil || !($0.configuration.email ?? "").isEmpty }
        #else
        withState { !($0.configuration.email ?? "").isEmpty }
        #endif
    }

    static var configuration: Configuration { withState { $0.configuration } }

    /// 피드백에 함께 갈 로그 한 줄을 남긴다. 최근 500줄만 메모리에 둔다.
    /// 배포 빌드에서는 사용자가 로그 기록에 동의하기 전에는 아무것도 남기지 않는다.
    public static func log(_ message: String) {
        FeedbackLog.shared.add(message)
    }

    /// 화면 없이 피드백을 Mac으로 보낸다(Debug 빌드 전용). 이번에 Mac이 받았으면 `true`, 쌓아 두기만 했거나 Mac 주소가 없으면 `false`.
    /// 글이 비어도 `details`, 첨부, 확인 목록의 답 가운데 하나가 있으면 보낸다.
    /// `attachments`는 `FeedbackFiles`의 한도까지만 붙고 넘는 것은 빠진다. 배포 빌드에서는 아무것도 보내지 않고 `false`.
    @discardableResult
    public static func send(_ message: String, details: String = "", image: Data? = nil,
                            attachments: [FeedbackFile] = []) async -> Bool {
        #if DEBUG
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client else { return false }
        var files = FeedbackFiles()
        for file in attachments { try? files.add(file) }
        let checks = await MainActor.run { FeedbackCheckStore().reportChecks }
        guard hasContent(message: trimmed, details: details, hasFiles: image != nil || !files.items.isEmpty, checks: checks) else { return false }
        var report = report(message: trimmed, details: details, image: image, attachments: files.items, date: Date())
        if !checks.isEmpty { report.checks = checks }
        return await client.submit(report)
        #else
        return false
        #endif
    }

    #if DEBUG
    static var client: FeedbackClient? { withState { $0.client } }

    /// 글 없이 보낸 피드백의 첫 줄. 받는 쪽이 빈 글과 잘린 글을 헷갈리지 않게 한다.
    /// Mac 앱이 이 글자 그대로 찾으므로(`FeedbackIssue.directFacts`) 기기 언어로 바꾸지 않는다.
    static let emptyMessageMark = "(글 없이 보냄)"

    /// 보낼 것이 있는가. 글이 비어도 참고 정보(로그), 첨부, 확인 목록의 답 가운데 하나가 있으면 보낸다. 메모만 적은 항목은 답이 아니다.
    static func hasContent(message: String, details: String, hasFiles: Bool, checks: [FeedbackReport.Check]) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasFiles || checks.contains { !$0.answer.isEmpty }
    }

    /// Mac으로 보내는 기록을 만든다(Debug 빌드 전용).
    ///
    /// 기록의 글에 적는 `(글 없이 보냄)`, `앱:`, `기기:`, `보낸 시각:`, `첨부:`와 로그 앞의 `최근 로그`는 기기 언어와 상관없이
    /// 이 한국어 글자 그대로 둔다. Mac 앱이 이 줄들을 글자 그대로 읽어 글·기기 정보·로그를 가르고(`FeedbackIssue.directFacts`),
    /// 에이전트도 같은 원문을 읽는다. 사용자의 화면에는 보이지 않는 글이다.
    static func report(message: String, details: String, image: Data? = nil, attachments: [FeedbackFile] = [],
                       date: Date) -> FeedbackReport {
        let stamp = ISO8601DateFormatter.fractional.string(from: date)
        var text = "\(message.isEmpty ? emptyMessageMark : message)\n\n---\n앱: \(bundleID) \(appVersion)\n기기: \(deviceSummary)\n보낸 시각: \(stamp)\n"
        if !attachments.isEmpty { text += "첨부: " + attachments.map(\.name).joined(separator: ", ") + "\n" }
        if !details.isEmpty {
            // 글이 코어의 한도를 넘지 않게, 참고 정보는 뒤쪽(최근 것)만 남긴다.
            var kept = Substring(details)
            let room = max(0, FeedbackClient.maxTextBytes - text.utf8.count - 1)
            if kept.utf8.count > room {
                var start = kept.utf8.index(kept.utf8.endIndex, offsetBy: -room)
                while start < kept.endIndex, String.Index(start, within: kept) == nil { start = kept.utf8.index(after: start) }
                kept = kept[start...]
            }
            text += kept + "\n"
        }
        return FeedbackReport(kind: "feedback", name: "feedback-\(stamp.replacingOccurrences(of: ":", with: "")).txt",
                              bundleId: bundleID, appVersion: appVersion, crashedAt: stamp, text: text,
                              image: image?.base64EncodedString(),
                              attachments: attachments.isEmpty ? nil : attachments.map {
                                  .init(name: $0.name, type: $0.type, base64: $0.data.base64EncodedString())
                              },
                              message: clipped(message, bytes: FeedbackClient.maxMessageBytes))
    }

    /// UTF-8로 `bytes`바이트를 넘지 않게 글자 경계에서 자른다.
    static func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var kept = String.UnicodeScalarView(), count = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            guard count + width <= bytes else { break }
            count += width
            kept.append(scalar)
        }
        return String(kept)
    }
    #endif

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    static var appName: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "App"
    }

    static var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    static var appVersion: String { buildNumber.isEmpty ? shortVersion : "\(shortVersion) (\(buildNumber))" }

    /// 기기 종류(`iPhone16,2` 같은 모델 식별자). 사용자가 붙인 기기 이름은 읽지 않는다.
    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// 운영체제 이름과 버전(`iOS 18.1`). 기기 언어에 따라 바뀌지 않는다.
    static var systemSummary: String {
        #if os(iOS)
        let name = "iOS"
        #elseif os(macOS)
        let name = "macOS"
        #elseif os(watchOS)
        let name = "watchOS"
        #elseif os(tvOS)
        let name = "tvOS"
        #elseif os(visionOS)
        let name = "visionOS"
        #else
        let name = "OS"
        #endif
        return systemSummary(name: name, version: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func systemSummary(name: String, version: OperatingSystemVersion) -> String {
        "\(name) \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion == 0 ? "" : ".\(version.patchVersion)")
    }

    static var deviceSummary: String { "\(deviceModel), \(systemSummary)" }

    /// 메일 본문과 진단 파일에 적는 앱·기기 정보. 개인을 가리키는 값은 없다.
    static var appInfo: FeedbackAppInfo {
        FeedbackAppInfo(name: appName, version: shortVersion, build: buildNumber, system: systemSummary,
                        device: deviceModel, bundleID: bundleID)
    }
}

extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

#if DEBUG && canImport(MetricKit) && os(iOS)
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
                    crashedAt: stamp, text: String(decoding: crash.jsonRepresentation(), as: UTF8.self), image: nil, attachments: nil))
            }
        }
        guard !reports.isEmpty else { return }
        let client = self.client
        Task { for report in reports { await client.submit(report) } }
    }
}
#endif
