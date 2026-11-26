import Foundation

/// Mac에 게시된 이 앱의 빌드 정보.
public struct UpdateInfo: Equatable, Sendable {
    public var buildId: String
    public var bundleId: String
    public var displayName: String
    public var version: String
    public var buildNumber: String
    public var minOS: String
    public var publishedAt: Date
    public var releaseNotes: String?
    public var ipaSize: Int64?

    public init(
        buildId: String,
        bundleId: String,
        displayName: String,
        version: String,
        buildNumber: String,
        minOS: String,
        publishedAt: Date,
        releaseNotes: String? = nil,
        ipaSize: Int64? = nil
    ) {
        self.buildId = buildId
        self.bundleId = bundleId
        self.displayName = displayName
        self.version = version
        self.buildNumber = buildNumber
        self.minOS = minOS
        self.publishedAt = publishedAt
        self.releaseNotes = releaseNotes
        self.ipaSize = ipaSize
    }

    /// `1.2 (34)` 형식의 버전 표시.
    public var versionLabel: String {
        buildNumber.isEmpty ? version : "\(version) (\(buildNumber))"
    }
}

/// 업데이트 확인이 실패하거나 비활성화된 이유.
public enum UpdateUnavailableReason: Equatable, Sendable {
    /// Release 빌드에서는 동작하지 않는다.
    case disabledInRelease
    /// `RemoteDebugUpdate.start(macHost:)`가 호출되지 않았거나 호스트 형식이 올바르지 않다.
    case notConfigured
    /// 앱의 번들 ID를 읽을 수 없다.
    case missingBundleID
    /// 개발자의 Mac에 닿지 않는다(RemoteDebug VPN이 꺼져 있거나 Mac 공유가 꺼져 있음).
    case unreachable
    /// 서버 응답을 읽지 못했다.
    case invalidResponse
}

/// 업데이트 확인 결과.
public enum UpdateStatus: Equatable, Sendable {
    /// 아직 확인하지 않았다.
    case idle
    /// Mac에서 최신 빌드 정보를 가져오는 중이다.
    case checking
    /// 지금 설치된 빌드가 최신이다(Mac에 게시된 빌드가 있으면 함께 담는다).
    case upToDate(UpdateInfo?)
    /// 지금 설치된 빌드보다 새 빌드가 Mac에 게시돼 있다.
    case available(UpdateInfo)
    /// 확인할 수 없다.
    case unavailable(UpdateUnavailableReason)

    /// 새 빌드가 있으면 그 정보.
    public var availableUpdate: UpdateInfo? {
        if case .available(let info) = self { return info }
        return nil
    }
}

/// Debug 빌드에서 앱이 자신의 업데이트 정보를 확인하고 RemoteDebug 앱을 통해 업데이트한다.
///
/// - **Debug 빌드에서만 동작하고 화면에 표시된다.**
/// - 배포 빌드(App Store, TestFlight 등 `DEBUG`가 없는 빌드)에는 네트워크 코드, Mac 주소 처리,
///   `remotedebug://` URL 스킴, 화면 문구가 컴파일되지 않는다. 모든 뷰는 `EmptyView`를 돌려주고
///   메서드는 아무것도 하지 않는다.
///
/// ```swift
/// #if DEBUG
/// RemoteDebugUpdate.start(macHost: "rd-mac-1a2b3c4d.tail0001.ts.net")
/// #endif
/// ```
public enum RemoteDebugUpdate {
    public struct Configuration: Sendable {
        /// RemoteDebug Mac 앱의 주소. Mac 앱의 **앱 안 업데이트 추가…**가 알려 준다.
        /// 배포판에 주소 글자가 남지 않게 `#if DEBUG` 안에서만 넣는다.
        public var macHost: String?

        public init(macHost: String? = nil) {
            self.macHost = macHost
        }
    }

    #if DEBUG
    struct State {
        var configuration = Configuration()
        var client: UpdateClient?
        var storage: URL? = RemoteDebugUpdate.defaultStorageDirectory
    }

    static var defaultStorageDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RemoteDebugUpdate", isDirectory: true)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func withState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
    #endif

    /// 앱을 시작할 때 한 번 부른다. 배포 빌드에서는 아무것도 하지 않는다.
    public static func start(_ configuration: Configuration) {
        #if DEBUG
        let client = configuration.macHost.flatMap { UpdateClient(host: $0) }
        withState {
            $0.configuration = configuration
            $0.client = client
        }
        #endif
    }

    /// Mac 주소만으로 시작한다. 주소 형식이 올바르면 `true`, 배포 빌드이거나 형식이 틀리면 `false`.
    @discardableResult
    public static func start(macHost: String) -> Bool {
        #if DEBUG
        guard UpdateClient.baseURL(host: macHost) != nil else { return false }
        start(Configuration(macHost: macHost))
        return true
        #else
        return false
        #endif
    }

    /// Mac 주소가 설정되어 업데이트를 확인할 수 있는가. 배포 빌드에서는 언제나 `false`.
    public static var isConfigured: Bool {
        #if DEBUG
        withState { $0.client != nil }
        #else
        false
        #endif
    }

    /// 현재 실행 중인 앱의 버전 문자열(`1.2 (34)`).
    public static var currentVersionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    /// Mac에 게시된 이 앱의 최신 빌드를 확인한다. 배포 빌드에서는 네트워크 요청 없이 `.unavailable(.disabledInRelease)`를 돌려준다.
    public static func check() async -> UpdateStatus {
        #if DEBUG
        let (client, storage) = withState { ($0.client, $0.storage) }
        guard let client else { return .unavailable(.notConfigured) }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard !bundleID.isEmpty else { return .unavailable(.missingBundleID) }
        let current = CurrentBuild.read(bundle: .main, storage: storage)
        return await client.check(bundleID: bundleID, current: current)
        #else
        return .unavailable(.disabledInRelease)
        #endif
    }

    /// RemoteDebug 앱을 열어 이 앱의 업데이트 설치를 요청하는 URL. 배포 빌드에서는 `nil`.
    public static func updaterURL(buildId: String? = nil) -> URL? {
        #if DEBUG
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        return UpdateDeepLink.url(bundleId: bundleID, buildId: buildId)
        #else
        return nil
        #endif
    }

    /// 이 기기에 RemoteDebug 앱이 설치되어 열 수 있는지(`Info.plist`의 `LSApplicationQueriesSchemes`에 `remotedebug` 필요).
    /// 배포 빌드에서는 언제나 `false`.
    @MainActor
    public static var canOpenUpdater: Bool {
        #if DEBUG && canImport(UIKit) && !os(watchOS)
        guard let url = UpdateDeepLink.probeURL else { return false }
        return UIApplication.shared.canOpenURL(url)
        #else
        return false
        #endif
    }

    /// RemoteDebug 앱을 열어 이 앱의 업데이트 설치를 시작한다. 배포 빌드에서는 아무것도 하지 않고 `false`.
    @MainActor
    @discardableResult
    public static func openUpdater(buildId: String? = nil) async -> Bool {
        #if DEBUG && canImport(UIKit) && !os(watchOS)
        guard let url = updaterURL(buildId: buildId) else { return false }
        return await UIApplication.shared.open(url)
        #else
        return false
        #endif
    }
}

#if DEBUG && canImport(UIKit) && !os(watchOS)
import UIKit
#endif
