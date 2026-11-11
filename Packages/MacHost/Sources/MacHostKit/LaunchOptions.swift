import Foundation

/// 실행 인자(UserDefaults 인자 도메인)와 저장된 고급 설정.
///
/// - `-RDControlURL <url>`: 제어 서버 URL(Headscale 등). 고급 설정에서 저장한 값보다 우선한다.
/// - `-RDNodeId8 <8자리 소문자 16진수>`: 노드 이름 `rd-mac-<id8>`을 고정한다.
/// - `-RDStartSharing YES`: 예전 인자. 지금은 앱이 실행하면 항상 공유를 시작하므로 효과가 없다.
/// - `-RDStateRootName <이름>`: 저장 폴더를 `Application Support/<이름>`으로 바꾼다(스모크 테스트용, 영문·숫자·`-`만).
///   저장하는 값(감시 폴더 북마크, 고급 설정의 제어 서버)도 이 이름으로 나눠, 기본 폴더의 값을 읽거나 바꾸지 않는다.
/// - `-RDTesting YES` 또는 XCTest 호스트: 실제 저장 폴더를 건드리지 않는다(임시 폴더, 불러오기·공유 시작 없음).
public struct LaunchOptions: Sendable {
    public static let controlURLKey = "RDControlURL"
    public static let nodeID8Key = "RDNodeId8"
    public static let startSharingKey = "RDStartSharing"
    public static let stateRootNameKey = "RDStateRootName"
    public static let testingKey = "RDTesting"
    public static let defaultStateRootName = "RemoteDebug"

    public var controlURL: String
    public var nodeID8: String?
    public var startSharing: Bool
    public var stateRootName: String
    public var isTesting: Bool

    /// `arguments`는 명령줄 인자(UserDefaults 인자 도메인)다. 저장 폴더를 바꾸면 기본 폴더의 저장값 대신 이 값을 먼저 본다.
    public init(defaults: UserDefaults, environment: [String: String] = ProcessInfo.processInfo.environment,
                arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)) {
        let id = defaults.string(forKey: Self.nodeID8Key) ?? ""
        nodeID8 = Self.isValidID8(id) ? id : nil
        startSharing = defaults.bool(forKey: Self.startSharingKey)
        let name = defaults.string(forKey: Self.stateRootNameKey) ?? ""
        stateRootName = Self.isValidRootName(name) ? name : Self.defaultStateRootName
        let savedControlURL = defaults.string(forKey: Self.scopedKey(Self.controlURLKey, root: stateRootName))
        controlURL = ((arguments[Self.controlURLKey] as? String) ?? savedControlURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        isTesting = defaults.bool(forKey: Self.testingKey) || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil || environment["XCTestSessionIdentifier"] != nil
    }

    /// 고급 설정에서 바꾼 제어 서버를 저장하는 키.
    public var savedControlURLKey: String { Self.scopedKey(Self.controlURLKey, root: stateRootName) }

    /// 감시 폴더 북마크를 저장하는 키.
    public var folderBookmarkKey: String { Self.scopedKey(UserDefaultsFolderBookmarks.defaultKey, root: stateRootName) }

    /// 기본 폴더는 원래 키를, 다른 폴더는 `<키>.<폴더 이름>`을 쓴다.
    static func scopedKey(_ key: String, root: String) -> String {
        root == defaultStateRootName ? key : "\(key).\(root)"
    }

    public static func isValidID8(_ s: String) -> Bool {
        s.count == 8 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// 1~64자의 영문·숫자·`-`. 경로 구분자나 `..`가 들어갈 수 없다.
    public static func isValidRootName(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
