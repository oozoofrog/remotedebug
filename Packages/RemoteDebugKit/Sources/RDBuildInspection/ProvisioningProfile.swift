#if os(macOS)
import Foundation
import Security

/// `embedded.mobileprovision`(CMS로 감싼 plist)을 읽은 결과. 인증서 체인은 검증하지 않는다.
public struct ProvisioningProfile: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case development
        case adHoc = "ad_hoc"
        case enterprise
        case appStore = "app_store"
        /// 기기 목록도 없고 `get-task-allow`도 true인, 분류 규칙에 없는 조합.
        case unknown
    }

    public var name: String
    public var uuid: String?
    public var teamIdentifiers: [String]
    public var teamName: String?
    public var creationDate: Date?
    public var expirationDate: Date
    /// 프로필에 `ProvisionedDevices` 키가 없으면 nil.
    public var provisionedDevices: [String]?
    public var provisionsAllDevices: Bool
    public var entitlements: [String: PlistValue]
    public var getTaskAllow: Bool?
    public var apsEnvironment: String?
    public var betaReportsActive: Bool?

    public var teamIdentifier: String? { teamIdentifiers.first }

    public var kind: Kind {
        if provisionsAllDevices { return .enterprise }
        let hasDevices = !(provisionedDevices ?? []).isEmpty
        if hasDevices { return getTaskAllow == true ? .development : .adHoc }
        return getTaskAllow == nil || getTaskAllow == false ? .appStore : .unknown
    }

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case cms(Int32)
        case notAPlist
        case missing(String)

        public var description: String {
            switch self {
            case .cms(let s): String(localized: "CMS 해독 실패(\(String(s)))")
            case .notAPlist: String(localized: "프로필 내용이 plist가 아닙니다")
            case .missing(let k): String(localized: "프로필에 \(k) 키가 없습니다")
            }
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(cmsData: Data(contentsOf: url))
    }

    /// CMS(DER) 데이터를 풀어 plist를 읽는다. 서명자 신원·인증서 체인은 검증하지 않는다.
    public init(cmsData: Data) throws {
        var decoder: CMSDecoder?
        var status = CMSDecoderCreate(&decoder)
        guard status == errSecSuccess, let decoder else { throw ParseError.cms(status) }
        status = cmsData.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard status == errSecSuccess else { throw ParseError.cms(status) }
        status = CMSDecoderFinalizeMessage(decoder)
        guard status == errSecSuccess else { throw ParseError.cms(status) }
        var content: CFData?
        status = CMSDecoderCopyContent(decoder, &content)
        guard status == errSecSuccess, let content else { throw ParseError.cms(status) }
        try self.init(plistData: content as Data)
    }

    public init(plistData: Data) throws {
        guard let root = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw ParseError.notAPlist
        }
        guard let name = root["Name"] as? String else { throw ParseError.missing("Name") }
        guard let expiration = root["ExpirationDate"] as? Date else { throw ParseError.missing("ExpirationDate") }
        self.name = name
        uuid = root["UUID"] as? String
        teamIdentifiers = root["TeamIdentifier"] as? [String] ?? []
        teamName = root["TeamName"] as? String
        creationDate = root["CreationDate"] as? Date
        expirationDate = expiration
        provisionedDevices = root["ProvisionedDevices"] as? [String]
        provisionsAllDevices = (root["ProvisionsAllDevices"] as? Bool) ?? false
        let ents = (root["Entitlements"] as? [String: Any]) ?? [:]
        entitlements = ents.plistDictionary()
        getTaskAllow = entitlements["get-task-allow"]?.boolValue
        apsEnvironment = entitlements["aps-environment"]?.stringValue
        betaReportsActive = entitlements["beta-reports-active"]?.boolValue
    }
}
#endif
