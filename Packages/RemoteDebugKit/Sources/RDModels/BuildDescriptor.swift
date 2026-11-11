import CryptoKit
import Foundation

/// protocol §4.1. 호스트가 게시한 개발 서명 IPA 한 개의 메타데이터.
public struct BuildDescriptor: Codable, Sendable, Hashable, Identifiable {
    public enum ConfigurationEvidence: String, Codable, Sendable, Hashable {
        case path
        case debugDylib = "debug-dylib"
        case userConfirmed = "user-confirmed"
    }

    public struct Signing: Codable, Sendable, Hashable {
        public var teamId: String
        public var profileName: String
        public var profileExpires: Date
        public var provisionedDeviceCount: Int
        public var getTaskAllow: Bool

        public init(teamId: String, profileName: String, profileExpires: Date, provisionedDeviceCount: Int, getTaskAllow: Bool) {
            self.teamId = teamId
            self.profileName = profileName
            self.profileExpires = profileExpires
            self.provisionedDeviceCount = provisionedDeviceCount
            self.getTaskAllow = getTaskAllow
        }

        enum CodingKeys: String, CodingKey {
            case teamId, profileName, profileExpires, provisionedDeviceCount, getTaskAllow
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            teamId = try c.decode(String.self, forKey: .teamId)
            profileName = try c.decode(String.self, forKey: .profileName)
            profileExpires = try c.decodeRDDate(forKey: .profileExpires)
            provisionedDeviceCount = try c.decode(Int.self, forKey: .provisionedDeviceCount)
            getTaskAllow = try c.decode(Bool.self, forKey: .getTaskAllow)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(teamId, forKey: .teamId)
            try c.encode(profileName, forKey: .profileName)
            try c.encodeRDDate(profileExpires, forKey: .profileExpires)
            try c.encode(provisionedDeviceCount, forKey: .provisionedDeviceCount)
            try c.encode(getTaskAllow, forKey: .getTaskAllow)
        }
    }

    public struct IPAInfo: Codable, Sendable, Hashable {
        public var size: Int64
        public var sha256: String

        public init(size: Int64, sha256: String) {
            self.size = size
            self.sha256 = sha256
        }
    }

    public var id: String
    public var bundleId: String
    public var displayName: String
    public var version: String
    public var buildNumber: String
    public var minOS: String
    public var debug: Bool
    public var configuration: String
    public var configurationEvidence: ConfigurationEvidence
    public var signing: Signing
    public var ipa: IPAInfo
    public var publishedAt: Date

    public init(
        id: String,
        bundleId: String,
        displayName: String,
        version: String,
        buildNumber: String,
        minOS: String,
        debug: Bool,
        configuration: String,
        configurationEvidence: ConfigurationEvidence,
        signing: Signing,
        ipa: IPAInfo,
        publishedAt: Date
    ) {
        self.id = id
        self.bundleId = bundleId
        self.displayName = displayName
        self.version = version
        self.buildNumber = buildNumber
        self.minOS = minOS
        self.debug = debug
        self.configuration = configuration
        self.configurationEvidence = configurationEvidence
        self.signing = signing
        self.ipa = ipa
        self.publishedAt = publishedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, bundleId, displayName, version, buildNumber, minOS, debug
        case configuration, configurationEvidence, signing, ipa, publishedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        displayName = try c.decode(String.self, forKey: .displayName)
        version = try c.decode(String.self, forKey: .version)
        buildNumber = try c.decode(String.self, forKey: .buildNumber)
        minOS = try c.decode(String.self, forKey: .minOS)
        debug = try c.decode(Bool.self, forKey: .debug)
        configuration = try c.decode(String.self, forKey: .configuration)
        configurationEvidence = try c.decode(ConfigurationEvidence.self, forKey: .configurationEvidence)
        signing = try c.decode(Signing.self, forKey: .signing)
        ipa = try c.decode(IPAInfo.self, forKey: .ipa)
        publishedAt = try c.decodeRDDate(forKey: .publishedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(bundleId, forKey: .bundleId)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(version, forKey: .version)
        try c.encode(buildNumber, forKey: .buildNumber)
        try c.encode(minOS, forKey: .minOS)
        try c.encode(debug, forKey: .debug)
        try c.encode(configuration, forKey: .configuration)
        try c.encode(configurationEvidence, forKey: .configurationEvidence)
        try c.encode(signing, forKey: .signing)
        try c.encode(ipa, forKey: .ipa)
        try c.encodeRDDate(publishedAt, forKey: .publishedAt)
    }

    /// protocol §4.1: `"b_"` + `sha256(bundleId + "\n" + ipaSHA256)`의 앞 8자리 16진수.
    public static func makeID(bundleId: String, ipaSHA256: String) -> String {
        let digest = SHA256.hash(data: Data((bundleId + "\n" + ipaSHA256).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "b_" + hex.prefix(8)
    }

    /// IPA 크기·해시를 채우고 `id`를 다시 계산한 복사본.
    public func withIPA(size: Int64, sha256: String) -> BuildDescriptor {
        var copy = self
        copy.ipa = IPAInfo(size: size, sha256: sha256)
        copy.id = Self.makeID(bundleId: bundleId, ipaSHA256: sha256)
        return copy
    }
}

/// `rd_host_publish`의 입력(protocol §9): `BuildDescriptor`의 필드를 그대로 펼치고 `ipaPath`를 더한 객체.
/// 코어(Go `host.PublishRequest`)가 받는 모양과 같다. `ipaPath`는 호스트 내부 경로라서 클라이언트에 보내는 형식(§4)에는 쓰지 않는다.
public struct PublishRequest: Codable, Sendable, Hashable {
    public var build: BuildDescriptor
    /// `publishDir` 안의 일반 파일을 가리키는 절대 경로.
    public var ipaPath: String

    public init(build: BuildDescriptor, ipaPath: String) {
        self.build = build
        self.ipaPath = ipaPath
    }

    enum CodingKeys: String, CodingKey { case ipaPath }

    public init(from decoder: any Decoder) throws {
        build = try BuildDescriptor(from: decoder)
        ipaPath = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .ipaPath)
    }

    public func encode(to encoder: any Encoder) throws {
        try build.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ipaPath, forKey: .ipaPath)
    }
}
