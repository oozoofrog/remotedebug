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

    /// 이 빌드를 처음 실행한 시각(설치 시각 대신 쓴다).
    ///
    /// iOS의 번들 폴더 생성 시각은 1970년으로 나오고, IPA 안 파일의 수정 시각은 시간대가 빠져 있어 믿을 수 없다.
    /// 그래서 버전·빌드 번호·실행 파일 크기·수정 시각으로 빌드를 가려, 처음 본 빌드면 지금 시각을 저장한다.
    /// 게시된 뒤에 설치하고 실행하므로 이 값은 그 빌드의 게시 시각보다 늦다.
    public static func installDate(of bundle: Bundle, defaults: UserDefaults = .standard, now: Date = Date()) -> Date? {
        guard let fingerprint = fingerprint(of: bundle) else { return nil }
        if defaults.string(forKey: fingerprintKey) == fingerprint, let saved = defaults.object(forKey: dateKey) as? Date {
            return saved
        }
        defaults.set(fingerprint, forKey: fingerprintKey)
        defaults.set(now, forKey: dateKey)
        return now
    }

    static let fingerprintKey = "rd.selfUpdate.fingerprint"
    static let dateKey = "rd.selfUpdate.firstLaunch"

    static func fingerprint(of bundle: Bundle) -> String? {
        guard let executable = bundle.executableURL,
              let values = try? executable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return "\(version)|\(build)|\(size)|\(Int(modified.timeIntervalSince1970))"
    }
}
