import Foundation
import RDModels

/// 호스트 앱의 저장 위치. 기본 루트는 `Application Support/RemoteDebug`(샌드박스에서는 컨테이너 안).
public struct HostPaths: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `~/Library/Application Support/<name>`(샌드박스면 컨테이너의 같은 위치). 기본 이름은 `RemoteDebug`.
    public static func applicationSupport(name: String = LaunchOptions.defaultStateRootName) throws -> HostPaths {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return HostPaths(root: base.appendingPathComponent(name, isDirectory: true))
    }

    /// 코어 `stateDir`(tailnet 노드 상태).
    public var stateDir: URL { root.appendingPathComponent("state", isDirectory: true) }
    /// 코어 `publishDir`. 게시본 IPA가 `<buildId>.ipa`로 놓인다. 코어가 `.rd-snapshots`를 만든다.
    public var publishedDir: URL { root.appendingPathComponent("Published", isDirectory: true) }
    /// IPA 풀기·묶기용 작업 폴더(게시 폴더와 같은 볼륨이라 이름 바꾸기로 원자적 교체가 된다).
    public var workDir: URL { root.appendingPathComponent("Work", isDirectory: true) }
    public var devicesFile: URL { root.appendingPathComponent("devices.json") }
    public var buildsFile: URL { root.appendingPathComponent("builds.json") }
    /// 감시 폴더에서 이미 처리한 빌드의 지문(경로 → 지문). 다시 시작해도 같은 빌드를 또 가져오지 않는다.
    public var watchStateFile: URL { root.appendingPathComponent("watched.json") }
    public var identityFile: URL { root.appendingPathComponent("identity.json") }
    public var coreLogFile: URL { root.appendingPathComponent("core.log") }

    public func ipaURL(forBuildID id: String) -> URL {
        publishedDir.appendingPathComponent("\(id).ipa")
    }

    /// 필요한 폴더를 만들고, 노드 키가 든 `state`와 `identity.json`을 백업에서 뺀다(부를 때마다 다시 적용한다).
    /// 폴더를 만들지 못했을 때만 던진다. 백업에서 빼지 못한 항목은 돌려준다(공유·가져오기를 막지 않는다).
    @discardableResult
    public func prepare() throws -> [URL] {
        let fm = FileManager.default
        for dir in [root, stateDir, publishedDir, workDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return applyBackupExclusion()
    }

    /// Time Machine·마이그레이션 지원이 tailnet 노드 신원(노드·머신 개인 키, `id8`)을 다른 Mac으로 복제하지 않게 한다.
    /// 복원된 사본은 새 노드로 로그인한다. 백업에서 빼지 못한 항목을 돌려준다.
    @discardableResult
    public func applyBackupExclusion() -> [URL] {
        let fm = FileManager.default
        return [stateDir, identityFile].filter { url in
            guard fm.fileExists(atPath: url.path) else { return false }
            return (try? Self.excludeFromBackup(url)) == nil
        }
    }

    public static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }
}

/// JSON 파일 한 개. 저장은 임시 파일에 쓴 뒤 이름 바꾸기(원자적)로 한다.
public struct JSONFile<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// 파일이 없으면 nil. 내용이 깨졌으면 던진다.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try RDJSON.decoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try RDJSON.encoder(pretty: true).encode(value)
        try data.write(to: url, options: [.atomic])
    }
}

/// 노드 이름(`rd-mac-<id8>`)에 쓰는 무작위 식별자. 첫 실행 때 만들어 저장한다.
public enum HostIdentity {
    struct Stored: Codable, Sendable {
        var id8: String
    }

    public static func loadOrCreate(at url: URL) throws -> String {
        let file = JSONFile<Stored>(url: url)
        if let stored = try? file.load(), isValid(stored.id8) { return stored.id8 }
        let id8 = random()
        try file.save(Stored(id8: id8))
        try? HostPaths.excludeFromBackup(url)
        return id8
    }

    /// 무작위 4바이트의 소문자 16진수 8자.
    public static func random() -> String {
        var g = SystemRandomNumberGenerator()
        return String(format: "%08x", UInt32.random(in: .min ... .max, using: &g))
    }

    public static func nodeName(id8: String) -> String { "rd-mac-\(id8)" }

    static func isValid(_ s: String) -> Bool {
        s.count == 8 && s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}
