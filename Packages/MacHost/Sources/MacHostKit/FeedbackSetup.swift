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

    /// 앱 시작 코드에 넣을 줄. `host`를 모르면 자리표시를 넣고, 메일 주소와 공개키는 있을 때만 넣는다.
    public static func snippet(host: String, email: String = "", publicKey: String = "") -> String {
        var arguments = ["macHost: \"\(host.isEmpty ? "<이 Mac의 주소>" : host)\""]
        if !email.isEmpty { arguments.append("email: \"\(email)\"") }
        if !publicKey.isEmpty { arguments.append("publicKeyBase64: \"\(publicKey)\"") }
        let debugStart = """
        RemoteDebugFeedback.start(.init(
            \(arguments.joined(separator: ",\n    "))
        ))
        """
        // 배포판(App Store)에는 Mac 주소를 넣지 않는다. 사용자가 메일로 보내고, 로그는 사용자가 켰을 때만 암호화해 붙인다. 사용자가 고른 사진과 파일은 메일에 그대로 붙는다.
        let start = email.isEmpty ? debugStart : """
        #if DEBUG
        \(debugStart)
        #else
        // 배포판: Mac 주소를 넣지 않는다. 사용자가 쓴 글을 메일 앱으로 보낸다.
        RemoteDebugFeedback.start(.init(email: "\(email)"\(publicKey.isEmpty ? "" : ", publicKeyBase64: \"\(publicKey)\"")))
        #endif
        """
        return """
        import RemoteDebugFeedback

        // 앱을 시작할 때 한 번(App의 init이나 application(_:didFinishLaunchingWithOptions:))
        \(start)

        // 피드백 화면을 띄울 곳(디버그 메뉴, 설정 화면 등). 화면은 저절로 찍지 않고, 사용자가 사진과 파일을 골라 붙인다(5개, 합쳐 1.5MB까지).
        .remoteDebugFeedback(isPresented: $showsFeedback)

        // 피드백에 함께 갈 로그(선택). os.Logger로 남긴 이 앱의 최근 로그는 자동으로 모은다.
        RemoteDebugFeedback.log("결제 화면 열림")
        """
    }
}
