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
            case .ips: String(localized: "크래시")
            case .metrickit: String(localized: "크래시(MetricKit)")
            case .feedback: String(localized: "피드백")
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
    /// 옛 클라이언트가 피드백에 붙이던 사진 한 장(JPEG나 PNG). 1MB까지. 새 클라이언트는 `attachments`를 쓴다.
    public var image: Data?
    /// 사용자가 피드백에 붙인 사진과 파일.
    public var attachments: [Attachment]
    /// 확인 목록에 사용자가 고른 답(개발 빌드의 피드백에만 온다).
    public var checks: [Check] = []
    /// 사용자가 쓴 글만 따로 적은 값(피드백). `text`에도 같은 글이 맨 앞에 있지만, 받는 쪽이 글과 그 아래의 로그를
    /// 가르는 데 이 값을 쓴다. 글 없이 보냈으면 빈 글자, 옛 클라이언트가 보낸 기록이면 `nil`이다.
    public var message: String?

    /// `message`의 크기 한도(바이트). 코어가 넘는 부분을 자른다.
    public static let maxMessageBytes = 64 << 10

    /// 피드백에 붙인 사진이나 파일 하나. JSON에서는 `{name, type, base64}`다.
    public struct Attachment: Codable, Sendable, Hashable {
        /// 파일 이름. 받는 쪽은 `safeName`으로 고쳐 쓴다.
        public var name: String
        /// MIME 종류. 모르면 `application/octet-stream`.
        public var type: String
        public var data: Data

        public init(name: String, type: String = "application/octet-stream", data: Data) {
            self.name = name
            self.type = type
            self.data = data
        }

        enum CodingKeys: String, CodingKey { case name, type, base64 }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "application/octet-stream"
            guard let decoded = Data(base64Encoded: try c.decode(String.self, forKey: .base64)) else {
                throw DecodingError.dataCorruptedError(forKey: .base64, in: c, debugDescription: "base64가 아닙니다.")
            }
            data = decoded
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(type, forKey: .type)
            try c.encode(data.base64EncodedString(), forKey: .base64)
        }

        /// 저장할 때 쓸 파일 이름. 경로 마디, 제어 문자, 앞의 점을 없애고 100바이트 안으로 줄인다(확장자는 남긴다).
        public static func safeName(_ raw: String) -> String {
            let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            var name = String(String.UnicodeScalarView(last.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) && $0 != ":"
            })).trimmingCharacters(in: .whitespaces)
            while name.hasPrefix(".") { name.removeFirst() }
            guard !name.isEmpty else { return "attachment" }
            guard name.utf8.count > 100 else { return name }
            var ext = ""
            if let dot = name.lastIndex(of: "."), dot != name.startIndex, name[dot...].utf8.count <= 17 {
                ext = String(name[dot...])
                name = String(name[..<dot])
            }
            while name.utf8.count + ext.utf8.count > 100 { name.removeLast() }
            return name + ext
        }
    }

    /// 코어가 받는 옛 `image` 크기 한도(바이트).
    public static let maxImageBytes = 1 << 20
    /// 기록 하나에 붙이는 첨부 수 한도.
    public static let maxAttachments = 5
    /// 첨부 하나의 크기 한도(바이트).
    public static let maxAttachmentBytes = 1 << 20
    /// 기록 하나의 첨부를 모두 합친 크기 한도(바이트). base64로 2MiB가 되어, 본문(`text` 1536KB)과 함께
    /// 코어의 `POST /v1/crashes` 본문 한도 4MiB에 들어간다.
    public static let maxAttachmentTotalBytes = 1536 << 10

    /// 사진 한 장을 줄여 맞추는 크기(바이트). 다섯 장을 붙여도 합계 한도에 들어간다.
    public static let maxAttachedImageBytes = 300 << 10

    /// 첨부를 더 붙일 수 없는 까닭.
    public enum AttachmentRefusal: Error, Equatable, Sendable {
        case tooMany, tooLarge, totalTooLarge
    }

    /// `bytes` 크기의 첨부를 `existing`에 더할 수 없으면 그 까닭. 큰 파일은 자르지 않고 받지 않는다.
    public static func attachmentRefusal(adding bytes: Int, to existing: [Attachment]) -> AttachmentRefusal? {
        if existing.count >= maxAttachments { return .tooMany }
        if bytes > maxAttachmentBytes { return .tooLarge }
        if existing.reduce(bytes, { $0 + $1.data.count }) > maxAttachmentTotalBytes { return .totalTooLarge }
        return nil
    }

    public init(kind: Kind, name: String, bundleId: String, appVersion: String, crashedAt: Date, text: String,
                image: Data? = nil, attachments: [Attachment] = []) {
        self.image = image
        self.attachments = attachments
        self.kind = kind
        self.name = name
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.crashedAt = crashedAt
        self.text = text
    }

    enum CodingKeys: String, CodingKey { case kind, name, bundleId, appVersion, crashedAt, text, image, attachments, checks, message }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId) ?? ""
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        crashedAt = try c.decodeRDDate(forKey: .crashedAt)
        text = try c.decode(String.self, forKey: .text)
        image = try c.decodeIfPresent(String.self, forKey: .image).flatMap { Data(base64Encoded: $0) }
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        checks = try c.decodeIfPresent([Check].self, forKey: .checks) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(bundleId, forKey: .bundleId)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(crashedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), forKey: .crashedAt)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(image?.base64EncodedString(), forKey: .image)
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        if !checks.isEmpty { try c.encode(checks, forKey: .checks) }
        try c.encodeIfPresent(message, forKey: .message)
    }

    /// 내용으로 정한 id. 같은 기록을 두 번 받아도 하나로 남는다.
    ///
    /// 글(`text`)과 붙인 사진·파일의 내용으로 정한다: 글이 같아도 첨부가 다르면 다른 기록이다. 첨부가 없는 기록의 id는
    /// 글만으로 정하던 예전 값과 같다. 어느 기기가 보냈는지는 받는 Mac이 따로 가린다(`CrashLogStore.recordID`).
    public var id: String {
        var hash = SHA256()
        hash.update(data: Data(text.utf8))
        // 글 뒤에 구분 바이트를 두고, 옛 사진(1)과 첨부(2)를 가려 각각의 해시를 잇는다.
        if let image {
            hash.update(data: Data([0, 1]))
            hash.update(data: Data(SHA256.hash(data: image)))
        }
        for attachment in attachments {
            hash.update(data: Data([0, 2]))
            hash.update(data: Data(SHA256.hash(data: attachment.data)))
        }
        return "c_" + hash.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// 코어가 받는 본문 크기 한도(바이트).
    public static let maxTextBytes = 1536 << 10

    /// 사람이 쓴 피드백에서 기록을 만든다. `details`는 내용 아래에 붙일 참고 정보(기기, 최근 로그 등)다.
    public static func feedback(message: String, bundleId: String, appVersion: String, details: String = "", image: Data? = nil,
                                attachments: [Attachment] = [], date: Date) -> CrashReport {
        let stamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n앱: \(bundleId) \(appVersion)\n보낸 시각: \(stamp)\n"
        if !attachments.isEmpty { text += "첨부: " + attachments.map(\.name).joined(separator: ", ") + "\n" }
        if !details.isEmpty { text += details + "\n" }
        let name = "feedback-" + stamp.replacingOccurrences(of: ":", with: "") + ".txt"
        var report = CrashReport(kind: .feedback, name: name, bundleId: bundleId, appVersion: appVersion, crashedAt: date, text: text, image: image, attachments: attachments)
        report.message = clipped(message.trimmingCharacters(in: .whitespacesAndNewlines), bytes: maxMessageBytes)
        return report
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
    /// 호스트가 기록을 받은 시각. Mac 코어 안에서만 채운다(JSON에는 없다). 없으면 받는 쪽이 지금 시각을 쓴다.
    public var receivedAt: Date?

    enum CodingKeys: String, CodingKey { case deviceId, deviceName, nodeName, report }

    public init(deviceId: String, deviceName: String, nodeName: String, report: CrashReport, receivedAt: Date? = nil) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.nodeName = nodeName
        self.report = report
        self.receivedAt = receivedAt
    }
}
