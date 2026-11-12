import Foundation

/// iPhone 앱이 Mac에 보내는 로그 한 줄(docs/protocol-addenda.md G).
public struct DeviceLogEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Level: String, Codable, Sendable, Hashable, CaseIterable {
        case debug, info, warning, error
    }

    /// 같은 기기 안에서 줄을 가리는 값. JSON에는 없고 읽을 때 새로 만든다.
    public var id = UUID()
    public var at: Date
    public var level: Level
    /// 로그를 남긴 부분(`app`, `vpn`, `pairing`, `builds`, `install`, `update` 등).
    public var source: String
    public var message: String

    public init(at: Date, level: Level, source: String, message: String) {
        self.at = at
        self.level = level
        self.source = source
        self.message = message
    }

    enum CodingKeys: String, CodingKey { case at, level, source, message }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeRDDate(forKey: .at)
        level = (try? c.decode(Level.self, forKey: .level)) ?? .info
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        message = try c.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // 같은 초 안의 순서를 남기려고 소수 초까지 쓴다.
        try c.encode(at.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), forKey: .at)
        try c.encode(level, forKey: .level)
        try c.encode(source, forKey: .source)
        try c.encode(message, forKey: .message)
    }

    /// 한 줄 텍스트(복사·파일용).
    public var line: String {
        "\(at.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) [\(level.rawValue)] \(source): \(message)"
    }
}

/// `POST /v1/logs`의 본문.
public struct DeviceLogBatch: Codable, Sendable, Hashable {
    public var entries: [DeviceLogEntry]

    public init(entries: [DeviceLogEntry]) {
        self.entries = entries
    }

    /// 코어가 받는 한도.
    public static let maxEntries = 200
    public static let maxMessageBytes = 4096
}

/// 코어 이벤트 `device-log`: 허용 목록의 기기가 보낸 로그.
public struct DeviceLogEvent: Codable, Sendable, Hashable {
    public var deviceId: String
    public var deviceName: String
    public var nodeName: String
    public var entries: [DeviceLogEntry]

    public init(deviceId: String, deviceName: String, nodeName: String, entries: [DeviceLogEntry]) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.nodeName = nodeName
        self.entries = entries
    }
}
