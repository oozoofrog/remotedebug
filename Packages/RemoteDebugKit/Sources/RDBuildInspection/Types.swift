#if os(macOS)
import Foundation
import RDModels

public struct InspectionOptions: Sendable {
    /// 사용자가 이 빌드가 Debug임을 직접 확인했다(규칙 7의 마지막 수단).
    public var confirmedDebug: Bool
    /// 설치 대상 기기 UDID. 주어지면 프로필 기기 목록에 있어야 한다(규칙 8).
    public var targetUDID: String?
    /// `Debug` 외에 허용할 구성 이름(규칙 7).
    public var allowedConfigurations: Set<String>
    public var now: Date

    public init(confirmedDebug: Bool = false, targetUDID: String? = nil, allowedConfigurations: Set<String> = [], now: Date = Date()) {
        self.confirmedDebug = confirmedDebug
        self.targetUDID = targetUDID
        self.allowedConfigurations = allowedConfigurations
        self.now = now
    }
}

/// protocol §7 거부 사유. rawValue는 표의 snake_case.
public enum RejectionCode: String, Codable, Sendable, Hashable, CaseIterable {
    case notIOSApp = "not_ios_app"
    case unsigned
    case invalidSignature = "invalid_signature"
    case getTaskAllowMissing = "get_task_allow_missing"
    case noProvisioningProfile = "no_provisioning_profile"
    case notDevelopmentProfile = "not_development_profile"
    case profileExpired = "profile_expired"
    case configurationNotDebug = "configuration_not_debug"
    case configurationUnverified = "configuration_unverified"
    case deviceNotProvisioned = "device_not_provisioned"
    /// 킷 전용(protocol §7 표 밖): 게시에 꼭 필요한 값을 읽지 못함. 지금은 `CFBundleIdentifier`가 없거나 빈 경우로,
    /// 코어의 `rd_host_publish`가 `bad_request`로 거부하는 빌드를 미리 거부해 양쪽 수락 규칙을 맞춘다.
    case unreadable
}

public struct Rejection: Codable, Sendable, Hashable {
    public var code: RejectionCode
    /// 사람이 읽는 보충 설명. `not_development_profile`은 `enterprise`·`ad_hoc`·`app_store` 등
    /// 분류 값을 담는다. UDID·팀 ID·프로필 이름은 넣지 않는다.
    public var detail: String

    public init(code: RejectionCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

public struct InspectionResult: Codable, Sendable, Hashable {
    public var accepted: Bool
    public var reasons: [Rejection]
    public var warnings: [String]
    /// 수락됐을 때만 있다. IPA 크기·해시는 `.ipa` 입력일 때만 채워지고, 아니면 0과 빈 문자열이다.
    public var descriptor: BuildDescriptor?
    /// 거부된 경우에도 번들 ID를 알려 주기 위한 보조 필드.
    public var bundleId: String?

    public init(accepted: Bool, reasons: [Rejection], warnings: [String], descriptor: BuildDescriptor?, bundleId: String? = nil) {
        self.accepted = accepted
        self.reasons = reasons
        self.warnings = warnings
        self.descriptor = descriptor
        self.bundleId = bundleId
    }
}

/// 검사를 진행할 수 없는 경우(읽을 수 없음). 정책 위반은 오류가 아니라 `InspectionResult.reasons`다.
public enum InspectionError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)

    public var description: String {
        switch self {
        case .unreadable(let m): String(localized: "읽을 수 없음: \(m)")
        }
    }
}
#endif
