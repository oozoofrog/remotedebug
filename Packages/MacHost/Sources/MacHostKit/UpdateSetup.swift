import Foundation

/// 연결한 프로젝트에 `RemoteDebugUpdate` 패키지를 넣는 안내.
/// 넣으면 그 앱의 Debug 빌드가 이 Mac에서 자신의 최신 업데이트 정보를 확인하고, RemoteDebug 앱을 통해 설치한다.
/// 배포 빌드(Release)에는 표시되지 않고 네트워크·URL 스킴 코드도 컴파일되지 않는다.
public enum UpdateSetup {
    public static let packageName = "RemoteDebugUpdate"
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

    /// 앱에 넣을 코드. `host`를 모르면 자리표시를 넣는다.
    /// Mac 주소 글자가 배포판 실행 파일에 남지 않게 `#if DEBUG` 안에 둔다.
    public static func snippet(host: String) -> String {
        let address = host.isEmpty ? "<이 Mac의 주소>" : host
        return """
        import RemoteDebugUpdate

        // 앱을 시작할 때 한 번(App의 init이나 application(_:didFinishLaunchingWithOptions:))
        // Mac 주소는 Debug 빌드에만 넣는다. 배포판(App Store, TestFlight)에서는 아무것도 표시되지 않는다.
        #if DEBUG
        RemoteDebugUpdate.start(macHost: "\(address)")
        #endif

        // 1) 화면 상단에 새 업데이트 배너 표시(Debug 빌드에서 새 빌드가 있을 때만 보인다)
        .remoteDebugUpdateBanner()

        // 2) 설정 화면의 Form이나 List 안에 업데이트 확인·설치 구역 추가(Debug 빌드에서만 보인다)
        RemoteDebugUpdateSection()

        // 3) 직접 제어할 때(Debug 빌드에서만 동작)
        // let status = await RemoteDebugUpdate.check()
        // if case .available(let info) = status {
        //     await RemoteDebugUpdate.openUpdater(buildId: info.buildId)
        // }
        """
    }
}
