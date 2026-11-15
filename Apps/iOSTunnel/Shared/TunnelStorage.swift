import Foundation

/// 터널 확장이 쓰는 파일 위치(docs/tunnel.md "구성").
///
/// `swiftail/` 폴더에는 노드 개인 키(신원 파일)와 tailnet lock 상태가 들어 있다. 그래서 준비할 때마다
/// - 데이터 보호 등급을 `completeUntilFirstUserAuthentication`으로 두고(첫 잠금 해제 뒤 주문형 시작 가능),
/// - 백업·기기 이전에서 빼도록 `isExcludedFromBackup`을 켠다. 복원한 기기는 tailnet 로그인과 페어링을 다시 한다.
///
/// 이 파일은 앱 대상에도 컴파일되어 임시 폴더로 단위 테스트한다.
enum TunnelStorage {
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    /// Swiftail 노드의 상태 폴더 이름(`base/RemoteDebug/swiftail`).
    static let stateName = "swiftail"
    /// 예전 Go 코어가 쓰던 상태 폴더 이름. Swiftail은 이 상태를 읽지 않는다(로그인은 다시 한다).
    static let legacyGoStateName = "tailscale"
    /// 예전 상태를 옮기다 밀려난 상태를 남기던 폴더 이름(예전 Go 코어 시절).
    static let legacyGoReplacedName = "tailscale.replaced"

    /// `base/RemoteDebug/swiftail`을 만들고(있으면 그대로) 보호 등급과 백업 제외를 적용해 돌려준다.
    /// - Parameter base: `Library/Application Support`(공용 컨테이너 또는 확장 컨테이너).
    static func prepareStateDirectory(in base: URL) throws -> URL {
        let parent = base.appendingPathComponent("RemoteDebug", isDirectory: true)
        let dir = parent.appendingPathComponent(stateName, isDirectory: true)
        try prepareDirectory(dir, protecting: [parent, dir])
        return dir
    }

    /// 저장된 로그인(Swiftail 상태 폴더)을 지운다. 다음 시작은 새 노드로 로그인한다.
    /// 서버 쪽 로그아웃은 이 함수 앞에서 확장이 한다(`SwiftailTunnelEngine.logOut`).
    static func resetStateDirectory(in base: URL) throws {
        try removeFolder(named: stateName, in: base)
    }

    /// 예전 Go 코어의 상태 폴더를 지운다. Swiftail 노드가 처음 실행 상태가 된 뒤에 부른다.
    /// Swiftail 상태(`swiftail/`)와 그 밖의 파일은 건드리지 않는다. 지운 것이 있으면 `true`.
    @discardableResult
    static func removeLegacyGoState(in base: URL) -> Bool {
        var removed = false
        for name in [legacyGoStateName, legacyGoReplacedName] {
            if (try? removeFolder(named: name, in: base)) == true { removed = true }
        }
        return removed
    }

    /// `base/RemoteDebug/<name>`을 지운다. 없으면 `false`.
    @discardableResult
    private static func removeFolder(named name: String, in base: URL) throws -> Bool {
        let dir = base.appendingPathComponent("RemoteDebug", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        try FileManager.default.removeItem(at: dir)
        return true
    }

    private static func prepareDirectory(_ dir: URL, protecting urls: [URL]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
        for url in urls {
            try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
            try excludeFromBackup(url)
        }
    }

    static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }
}
