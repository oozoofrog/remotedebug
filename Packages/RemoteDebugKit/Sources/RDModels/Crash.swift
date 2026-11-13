import CryptoKit
import Foundation

/// iPhone이 Mac에 보내는 크래시 기록 하나(docs/protocol-addenda.md L).
public struct CrashReport: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// iOS가 만든 크래시 파일(.ips). 사용자가 iPhone 앱으로 넘긴 것.
        case ips
        /// iPhone 앱 자신의 크래시를 MetricKit이 알려 준 JSON.
        case metrickit
        /// 사람이 앱에서 쓴 피드백. `text`가 내용이다.
        case feedback

        /// 원문을 저장할 파일의 확장자.
        public var fileExtension: String {
            switch self {
            case .ips: "ips"
            case .metrickit: "json"
            case .feedback: "txt"
            }
        }

        /// 목록에 보일 종류 이름.
        public var label: String {
            switch self {
            case .ips: "크래시"
            case .metrickit: "크래시(MetricKit)"
            case .feedback: "피드백"
            }
        }
    }

    public var kind: Kind
    /// 파일 이름.
    public var name: String
    public var bundleId: String
    public var appVersion: String
    public var crashedAt: Date
    public var text: String

    public init(kind: Kind, name: String, bundleId: String, appVersion: String, crashedAt: Date, text: String) {
        self.kind = kind
        self.name = name
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.crashedAt = crashedAt
        self.text = text
    }

    enum CodingKeys: String, CodingKey { case kind, name, bundleId, appVersion, crashedAt, text }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId) ?? ""
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        crashedAt = try c.decodeRDDate(forKey: .crashedAt)
        text = try c.decode(String.self, forKey: .text)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(bundleId, forKey: .bundleId)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(crashedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), forKey: .crashedAt)
        try c.encode(text, forKey: .text)
    }

    /// 내용으로 정한 id. 같은 기록을 두 번 받아도 하나로 남는다.
    public var id: String {
        "c_" + SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// 코어가 받는 본문 크기 한도(바이트).
    public static let maxTextBytes = 1536 << 10

    /// 사람이 쓴 피드백에서 기록을 만든다. `details`는 내용 아래에 붙일 참고 정보(기기, 최근 로그 등)다.
    public static func feedback(message: String, bundleId: String, appVersion: String, details: String = "", date: Date) -> CrashReport {
        let stamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n앱: \(bundleId) \(appVersion)\n보낸 시각: \(stamp)\n"
        if !details.isEmpty { text += details + "\n" }
        let name = "feedback-" + stamp.replacingOccurrences(of: ":", with: "") + ".txt"
        return CrashReport(kind: .feedback, name: name, bundleId: bundleId, appVersion: appVersion, crashedAt: date, text: text)
    }

    /// .ips 파일 내용에서 기록을 만든다. 첫 줄의 JSON 머리말에서 앱과 시각을 읽고, 없으면 `fallbackDate`와 파일 이름을 쓴다.
    public static func ips(name: String, text: String, fallbackDate: Date) -> CrashReport {
        var bundleId = "", version = "", crashedAt = fallbackDate
        if let first = text.split(separator: "\n", maxSplits: 1).first,
           let header = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any] {
            bundleId = header["bundleID"] as? String ?? ""
            let short = header["app_version"] as? String ?? ""
            let build = header["build_version"] as? String ?? ""
            version = build.isEmpty ? short : "\(short) (\(build))"
            if let stamp = header["timestamp"] as? String {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
                if let date = formatter.date(from: stamp) { crashedAt = date }
            }
        }
        return CrashReport(kind: .ips, name: name, bundleId: bundleId, appVersion: version, crashedAt: crashedAt, text: text)
    }
}

/// 코어 이벤트 `device-crash`: 허용 목록의 기기가 보낸 크래시 기록.
public struct DeviceCrashEvent: Codable, Sendable, Hashable {
    public var deviceId: String
    public var deviceName: String
    public var nodeName: String
    public var report: CrashReport

    public init(deviceId: String, deviceName: String, nodeName: String, report: CrashReport) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.nodeName = nodeName
        self.report = report
    }
}
