import Foundation
import RDModels

/// 이 iPhone 앱 자신의 새 빌드가 Mac에 게시되어 있는지 판정한다.
///
/// Debug 빌드는 버전과 빌드 번호가 늘 같아서 번호로는 새 빌드를 가릴 수 없다.
/// 그래서 Mac이 빌드를 게시한 시각과 이 앱이 iPhone에 설치된 시각을 비교한다.
/// 설치된 뒤에 게시된 빌드만 갱신으로 본다. 두 기기의 시계가 어긋난 만큼 판정이 틀릴 수 있다.
public enum SelfUpdate {
    /// 같은 번들 ID의 빌드 가운데 가장 늦게 게시된 것이 `installedAt` 뒤에 게시되었으면 그 빌드.
    /// 번들 ID나 설치 시각을 모르면 `nil`.
    public static func candidate(in builds: [BuildDescriptor], bundleID: String?, installedAt: Date?) -> BuildDescriptor? {
        guard let bundleID, let installedAt else { return nil }
        guard let latest = builds.filter({ $0.bundleId == bundleID }).max(by: { $0.publishedAt < $1.publishedAt }) else { return nil }
        return latest.publishedAt > installedAt ? latest : nil
    }

    /// 앱 번들이 iPhone에 놓인 시각. iOS는 설치할 때마다 번들 컨테이너 폴더를 새로 만든다.
    public static func installDate(of bundle: Bundle) -> Date? {
        let app = bundle.bundleURL
        for url in [app.deletingLastPathComponent(), app] {
            if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate { return date }
        }
        return nil
    }
}
