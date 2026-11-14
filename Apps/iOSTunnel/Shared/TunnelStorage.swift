import Foundation

/// 터널 확장이 쓰는 파일 위치(docs/tunnel.md "구성").
///
/// `tailscale/` 폴더의 `tailscaled.state`에는 노드 개인 키가 들어 있다. 그래서 준비할 때마다
/// - 데이터 보호 등급을 `completeUntilFirstUserAuthentication`으로 두고(첫 잠금 해제 뒤 주문형 시작 가능),
/// - 백업·기기 이전에서 빼도록 `isExcludedFromBackup`을 켠다. 복원한 기기는 tailnet 로그인과 페어링을 다시 한다.
///
/// 이 파일은 앱 대상에도 컴파일되어 임시 폴더로 단위 테스트한다.
enum TunnelStorage {
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    /// `base/RemoteDebug/tailscale`을 만들고(있으면 그대로) 보호 등급과 백업 제외를 적용해 돌려준다.
    /// - Parameter base: 확장 컨테이너의 `Library/Application Support`.
    /// 저장된 Tailscale 상태(로그인)를 지운다. 다음 시작은 새 노드로 로그인한다.
    static func resetStateDirectory(in base: URL) throws {
        // Go 코어의 상태와, 시험 빌드에서 Swiftail이 따로 쓰는 상태를 함께 지운다.
        for name in [goStateName, swiftailStateName] {
            let dir = base.appendingPathComponent("RemoteDebug", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        }
    }

    static let goStateName = "tailscale"
    /// Swiftail은 Go의 상태 파일을 읽지 않는다. 폴더를 나눠 두면 Go 터널로 되돌렸을 때 기존 로그인이 그대로다.
    static let swiftailStateName = "swiftail"

    static func prepareStateDirectory(in base: URL, name: String = goStateName) throws -> URL {
        let parent = base.appendingPathComponent("RemoteDebug", isDirectory: true)
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        try prepareDirectory(dir, protecting: [parent, dir])
        return dir
    }

    /// `base/RemoteDebug/core.log`의 위치. 폴더를 만들고 폴더와 기존 로그 파일을 백업에서 뺀다.
    /// - Parameter base: 확장 컨테이너의 `Library/Caches`.
    static func prepareLogFile(in base: URL) throws -> URL {
        let dir = base.appendingPathComponent("RemoteDebug", isDirectory: true)
        try prepareDirectory(dir, protecting: [dir])
        let file = dir.appendingPathComponent("core.log")
        if FileManager.default.fileExists(atPath: file.path) {
            try excludeFromBackup(file)
        }
        return file
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
