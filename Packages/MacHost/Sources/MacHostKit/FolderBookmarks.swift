import Foundation

/// 저장된 감시 폴더를 푼 결과.
public enum SavedFolder: Sendable, Hashable {
    /// 저장된 폴더가 없다.
    case none
    case folder(URL)
    /// 저장된 북마크를 풀 수 없다(폴더가 지워졌거나 옮겨졌거나 권한이 사라졌다). 알 수 있으면 마지막 경로.
    case unresolvable(path: String?)
}

/// 감시 폴더의 보안 범위 북마크 저장소.
public protocol FolderBookmarking: Sendable {
    func save(_ url: URL) throws
    /// 저장된 폴더. 북마크가 오래됐으면 새로 저장한다. 없거나 풀 수 없으면 nil.
    func resolve() -> URL?
    func clear()
    /// 저장된 폴더와, 저장은 됐지만 풀 수 없는 경우를 구별한다.
    func savedFolder() -> SavedFolder
}

extension FolderBookmarking {
    public func savedFolder() -> SavedFolder {
        resolve().map { .folder($0) } ?? .none
    }
}

/// 아무것도 저장하지 않는 북마크 저장소(미리보기·테스트 호스트).
public struct NoFolderBookmarks: FolderBookmarking {
    public init() {}
    public func save(_ url: URL) throws {}
    public func resolve() -> URL? { nil }
    public func clear() {}
}

/// 보안 범위 북마크를 `UserDefaults`에 저장한다.
public final class UserDefaultsFolderBookmarks: FolderBookmarking, @unchecked Sendable {
    public static let defaultKey = "RemoteDebug.watchedFolderBookmark"

    private let defaults: UserDefaults
    private let key: String
    private let creationOptions: URL.BookmarkCreationOptions
    private let resolutionOptions: URL.BookmarkResolutionOptions

    /// 샌드박스 앱은 기본값(읽기 전용 보안 범위: `withSecurityScope` + `securityScopeAllowOnlyReadAccess`)을 쓴다.
    /// 앱은 고른 폴더를 읽기만 한다(쓰기는 컨테이너 안에서만).
    public init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsFolderBookmarks.defaultKey,
        securityScoped: Bool = true
    ) {
        self.defaults = defaults
        self.key = key
        self.creationOptions = securityScoped ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : []
        self.resolutionOptions = securityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
    }

    public func save(_ url: URL) throws {
        // 파일 고르기 창이 준 URL은 접근을 시작해야 북마크를 만들 수 있다(샌드박스).
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key)
    }

    public func resolve() -> URL? {
        if case .folder(let url) = savedFolder() { return url }
        return nil
    }

    public func savedFolder() -> SavedFolder {
        guard let data = defaults.data(forKey: key) else { return .none }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
            return .unresolvable(path: path)
        }
        if stale { try? save(url) }
        return .folder(url)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// 보안 범위 접근의 시작·종료를 짝지어 관리한다. `stop()`이나 해제 시 접근을 끝낸다.
public final class SecurityScopedAccess: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var active: Bool

    public init(_ url: URL) {
        self.url = url
        self.active = url.startAccessingSecurityScopedResource()
    }

    /// 접근을 시작했는지(샌드박스 밖이나 이미 권한이 있는 경로면 false일 수 있다).
    public var isAccessing: Bool { lock.withLock { active } }

    public func stop() {
        let wasActive = lock.withLock {
            defer { active = false }
            return active
        }
        if wasActive { url.stopAccessingSecurityScopedResource() }
    }

    deinit { stop() }
}
