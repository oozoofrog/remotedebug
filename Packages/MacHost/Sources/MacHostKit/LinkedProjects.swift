import Foundation
import Observation

/// 등록한 프로젝트 폴더의 최근 빌드를 찾아 게시한다(샌드박스판). 빌드는 사용자가 Xcode에서 한다.
///
/// 폴더 접근은 보안 범위 북마크로 저장한다. DerivedData는 프로젝트 폴더 밖이라 한 번 따로 허용받는다.
@MainActor
@Observable
public final class LinkedProjectsModel {
    public struct Project: Identifiable, Sendable, Hashable {
        public var id: String { folder.path }
        public var folder: URL
        public var name: String { folder.lastPathComponent }
        /// 폴더 안에 Xcode 프로젝트·워크스페이스가 있는가.
        public var hasContainer = true
        public var builds: [XcodeBuildLocator.Found] = []
    }

    public private(set) var projects: [Project] = []
    /// 허용받은 Xcode 빌드 폴더(DerivedData).
    public private(set) var derivedData: URL?
    public private(set) var lastError: String?

    /// Xcode의 기본 빌드 폴더. 샌드박스에서도 컨테이너가 아닌 실제 홈을 가리킨다.
    public static var defaultDerivedData: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    static let projectsKey = "RemoteDebug.linkedProjects"
    static let derivedDataKey = "RemoteDebug.derivedDataBookmark"
    static let publishedKey = "RemoteDebug.linkedProjects.published"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let importer: @MainActor (URL) async -> Void
    @ObservationIgnored private var access: [SecurityScopedAccess] = []
    /// 이미 게시한 빌드(앱 경로 → 수정 시각). 같은 빌드를 다시 가져오지 않는다.
    @ObservationIgnored private var published: [String: Date]
    @ObservationIgnored private var polling: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, importer: @escaping @MainActor (URL) async -> Void) {
        self.defaults = defaults
        self.importer = importer
        self.published = (defaults.dictionary(forKey: Self.publishedKey) as? [String: Date]) ?? [:]
        for data in defaults.array(forKey: Self.projectsKey) as? [Data] ?? [] {
            if let url = Self.resolve(data) { open(url); projects.append(Project(folder: url)) }
        }
        if let data = defaults.data(forKey: Self.derivedDataKey), let url = Self.resolve(data) {
            open(url)
            derivedData = url
        }
    }

    /// 주기적으로 최근 빌드를 확인한다.
    public func start(every interval: Duration = .seconds(5)) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func add(_ folder: URL) async {
        lastError = nil
        guard !projects.contains(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) else { return }
        open(folder)
        guard !XcodeBuildLocator.containers(in: folder).isEmpty else {
            lastError = "\(folder.lastPathComponent)에 Xcode 프로젝트(.xcodeproj)나 워크스페이스(.xcworkspace)가 없습니다. 프로젝트 파일이 있는 폴더를 고르세요."
            return
        }
        projects.append(Project(folder: folder))
        save()
        await scan()
    }

    public func remove(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    public func allowDerivedData(_ folder: URL) async {
        open(folder)
        derivedData = folder
        if let data = Self.bookmark(folder) { defaults.set(data, forKey: Self.derivedDataKey) }
        await scan()
    }

    /// 프로젝트마다 최근 빌드를 찾고, 새 빌드는 게시한다.
    public func scan() async {
        let derived = derivedData
        for index in projects.indices {
            let folder = projects[index].folder
            let (hasContainer, builds) = await Task.detached {
                (!XcodeBuildLocator.containers(in: folder).isEmpty, XcodeBuildLocator.latestBuilds(for: folder, derivedData: derived))
            }.value
            guard index < projects.count, projects[index].folder == folder else { return }
            projects[index].hasContainer = hasContainer
            projects[index].builds = builds
            for build in builds where published[build.app.path] != build.modified {
                published[build.app.path] = build.modified
                defaults.set(published, forKey: Self.publishedKey)
                await importer(build.app)
            }
        }
    }

    private func open(_ url: URL) {
        access.append(SecurityScopedAccess(url))
    }

    private func save() {
        defaults.set(projects.compactMap { Self.bookmark($0.folder) }, forKey: Self.projectsKey)
    }

    private static func bookmark(_ url: URL) -> Data? {
        let options: URL.BookmarkCreationOptions = HostEdition.isSandboxed ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : []
        return try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        let options: URL.BookmarkResolutionOptions = HostEdition.isSandboxed ? [.withSecurityScope, .withoutUI] : [.withoutUI]
        return try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
