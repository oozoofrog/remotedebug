import Foundation
import RDModels

/// 외부 앱이 `remotedebug://update?bundleId=<번들 ID>[&buildId=<빌드 ID>]`로 보낸 업데이트 요청.
public struct UpdateLinkRequest: Equatable, Sendable {
    public var bundleId: String
    public var buildId: String?

    public init(bundleId: String, buildId: String? = nil) {
        self.bundleId = bundleId
        self.buildId = buildId
    }
}

/// `remotedebug://update` URL 해석과 대상 빌드 선택.
public enum UpdateLink {
    /// `remotedebug://update?bundleId=…[&buildId=…]` URL을 해석한다. 다른 주소거나 번들 ID가 올바르지 않으면 `nil`.
    public static func request(from url: URL) -> UpdateLinkRequest? {
        guard let scheme = url.scheme, scheme.caseInsensitiveCompare("remotedebug") == .orderedSame,
              let host = url.host, host.caseInsensitiveCompare("update") == .orderedSame,
              url.path.isEmpty || url.path == "/",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let bundleId = items.first(where: { $0.name == "bundleId" })?.value,
              isValidBundleID(bundleId) else {
            return nil
        }
        let buildId = items.first(where: { $0.name == "buildId" })?.value
        let cleanedBuildId = buildId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateLinkRequest(bundleId: bundleId, buildId: cleanedBuildId?.isEmpty == false ? cleanedBuildId : nil)
    }

    /// 요청에 맞는 게시 빌드를 고른다.
    /// RemoteDebug 앱 자신의 번들 ID(`selfBundleId`)는 스스로 업데이트할 수 없으므로 제외한다.
    /// `buildId`가 지정돼 있으면 그 빌드를 먼저 찾고, 없거나 지정하지 않았으면 그 앱의 가장 최근 게시 빌드를 돌려준다.
    public static func selectBuild(
        for request: UpdateLinkRequest,
        in builds: [BuildDescriptor],
        excluding selfBundleId: String?
    ) -> BuildDescriptor? {
        if let selfBundleId, !selfBundleId.isEmpty, request.bundleId == selfBundleId {
            return nil
        }
        let matching = AppBuildFilter.only(request.bundleId, in: builds)
        if let buildId = request.buildId, let exact = matching.first(where: { $0.id == buildId }) {
            return exact
        }
        return matching.first
    }

    static func isValidBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && !value.hasPrefix(".") &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }
    }
}
