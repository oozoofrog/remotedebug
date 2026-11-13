import Foundation

/// 연결한 프로젝트에 `RemoteDebugFeedback` 패키지를 넣는 안내. 넣으면 그 앱의 Debug 빌드가 자기 크래시 기록과 피드백을 이 Mac에 보낸다.
public enum FeedbackSetup {
    public static let packageName = "RemoteDebugFeedback"
    public static let packageURL = "https://github.com/oozoofrog/remotedebug"

    /// 프로젝트가 패키지를 이미 쓰는지. 프로젝트 파일과 그 폴더의 `Package.swift`, `project.yml`에서 이름을 찾는다.
    public static func isAdded(to project: ConnectedProject) -> Bool {
        let candidates = [
            project.containerURL.appendingPathComponent("project.pbxproj"),
            project.folder.appendingPathComponent("Package.swift"),
            project.folder.appendingPathComponent("project.yml"),
        ]
        return candidates.contains { url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            return data.range(of: Data(packageName.utf8)) != nil
        }
    }

    /// 앱 시작 코드에 넣을 줄. `host`를 모르면 자리표시를 넣는다.
    public static func snippet(host: String) -> String {
        """
        import RemoteDebugFeedback

        // 앱을 시작할 때 한 번(App의 init이나 application(_:didFinishLaunchingWithOptions:))
        #if DEBUG
        RemoteDebugFeedback.start(host: "\(host.isEmpty ? "<이 Mac의 주소>" : host)")
        #endif

        // 피드백 화면을 띄울 곳(디버그 메뉴, 설정 화면 등)
        .remoteDebugFeedback(isPresented: $showsFeedback)
        """
    }
}
