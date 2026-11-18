import Foundation
import RDModels

/// 게시한 빌드를 보고, 에이전트가 사용자에게 옮기거나 스스로 고칠 점검 사항을 만든다.
///
/// 빌드 ID는 IPA 내용으로 정해지므로 실행 파일이 바뀌면 버전이 같아도 새 빌드로 게시된다.
/// iPhone은 설치된 앱을 버전과 빌드 번호로만 알아보므로, 그 둘이 그대로면 새 빌드가 깔렸는지 알 수 없다.
enum PublishAdvice {
    /// 프로필 만료가 이보다 가까우면 알린다.
    static let profileWarning: TimeInterval = 3 * 86_400

    /// `others`는 지금 게시돼 있는 다른 빌드다(번들 ID가 달라도 된다. 같은 앱만 본다).
    static func notes(for build: BuildDescriptor, others: [BuildDescriptor], now: Date) -> [String] {
        let label = "\(build.displayName) \(build.version) (\(build.buildNumber))"
        let earlier = others.filter { $0.bundleId == build.bundleId && $0.id != build.id }
        var notes: [String] = []
        if earlier.contains(where: { $0.version == build.version && $0.buildNumber == build.buildNumber }) {
            notes.append("\(label): 실행 파일이 바뀌었는데 버전과 빌드 번호가 앞서 게시한 빌드와 같습니다. iPhone은 설치된 앱을 버전과 빌드 번호로 알아보므로 새 빌드가 설치됐는지 구분할 수 없습니다. 빌드 번호(CFBundleVersion, Xcode 설정 CURRENT_PROJECT_VERSION)를 올려 다시 게시하세요.")
        } else if let newest = earlier.filter({ $0.version == build.version }).map(\.buildNumber).max(by: { isLower($0, than: $1) }),
                  isLower(build.buildNumber, than: newest) {
            notes.append("\(label): 빌드 번호가 앞서 게시한 같은 버전의 빌드(\(newest))보다 낮습니다. 의도한 것이 아니면 빌드 번호를 \(newest)보다 높여 다시 게시하세요.")
        }
        let left = build.signing.profileExpires.timeIntervalSince(now)
        if left < profileWarning {
            let days = max(0, Int(left / 86_400))
            notes.append("\(label): 프로비저닝 프로필이 \(days == 0 ? "하루 안에" : "\(days)일 뒤") 만료됩니다. 만료되면 설치한 앱이 열리지 않습니다. Xcode에서 기기용으로 다시 빌드해 프로필을 새로 받으세요.")
        }
        return notes
    }

    /// 빌드 번호는 숫자로 견준다("9" < "10").
    static func isLower(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }
}
