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
        let dir = base.appendingPathComponent("RemoteDebug", isDirectory: true).appendingPathComponent("tailscale", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    static func prepareStateDirectory(in base: URL) throws -> URL {
        let parent = base.appendingPathComponent("RemoteDebug", isDirectory: true)
        let dir = parent.appendingPathComponent("tailscale", isDirectory: true)
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
