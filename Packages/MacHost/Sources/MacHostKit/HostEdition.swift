import Foundation

/// 이 앱이 App Sandbox 안에서 도는가(Mac App Store판). 샌드박스에서는 `xcodebuild`·`xcrun`을 실행할 수 없어
/// 프로젝트 빌드와 iPhone 앱 빌드·설치를 화면에서 뺀다.
public enum HostEdition {
    public static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
}

/// 샌드박스판에서 iPhone 앱을 설치하는 방법: 사용자가 터미널에서 저장소의 스크립트를 실행한다.
public enum PhoneAppGuide {
    public static let repository = URL(string: "https://github.com/oozoofrog/remotedebug")!
    /// 저장소를 홈 폴더에 받고(이미 있으면 그대로) 설치 스크립트를 실행한다.
    public static let command =
        "cd ~ && { [ -d remotedebug ] || git clone \(repository.absoluteString).git; } && remotedebug/scripts/install-phone.sh"
}
