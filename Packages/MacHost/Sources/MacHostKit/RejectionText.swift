import Foundation
import RDBuildInspection

/// 거부 사유 코드(protocol §7)를 사용자에게 보여 줄 한국어 문장으로 바꾼다.
public enum RejectionText {
    public static func sentence(for rejection: Rejection) -> String {
        switch rejection.code {
        case .notIOSApp:
            return "iPhone용 앱이 아닙니다. iOS 기기(-iphoneos)용으로 빌드한 .app이나 .ipa를 고르세요."
        case .unsigned:
            return "코드 서명이 없습니다. Xcode에서 개발 인증서로 서명해 다시 빌드하세요."
        case .invalidSignature:
            return "코드 서명 검증에 실패했습니다. 빌드 뒤 번들이 바뀌지 않았는지 확인하고 다시 빌드하세요."
        case .getTaskAllowMissing:
            return "디버그 서명(get-task-allow)이 없습니다. Debug 구성의 개발 서명 빌드만 올릴 수 있습니다."
        case .noProvisioningProfile:
            return "프로비저닝 프로필이 없습니다. 기기용 개발 프로필로 서명해 다시 빌드하세요."
        case .notDevelopmentProfile:
            return "개발용 프로필이 아닙니다\(profileKind(rejection.detail)). Development 프로필로 서명해 다시 빌드하세요."
        case .profileExpired:
            return "프로비저닝 프로필이 만료됐습니다. Xcode에서 프로필을 갱신하고 다시 빌드하세요."
        case .configurationNotDebug:
            return "Debug 구성 빌드가 아닙니다. Debug 구성으로 빌드하세요."
        case .configurationUnverified:
            return "Debug 구성인지 확인할 수 없습니다. Xcode의 Debug-iphoneos 폴더에서 가져오거나, Debug 빌드임을 확인하고 다시 가져오세요."
        case .deviceNotProvisioned:
            return "대상 iPhone이 프로필에 등록돼 있지 않습니다. Xcode에서 기기를 등록하고 다시 빌드하세요."
        case .unreadable:
            return "빌드를 읽을 수 없습니다. 빌드가 끝났는지 확인하고 다시 가져오세요."
        }
    }

    private static func profileKind(_ detail: String) -> String {
        switch detail {
        case "enterprise": "(엔터프라이즈 배포 프로필)"
        case "ad_hoc": "(Ad Hoc 배포 프로필)"
        case "app_store": "(App Store 배포 프로필)"
        default: ""
        }
    }
}
