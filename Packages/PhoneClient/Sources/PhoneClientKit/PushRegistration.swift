import CryptoKit
import Foundation

// 새 빌드·파일 알림(docs/protocol-addenda.md P): 기기 토큰 등록 기록, 등록 판단, 알림을 눌렀을 때 갈 곳.

/// 마지막으로 Mac에 등록하는 데 성공한 값. 지금 토큰이 등록한 것과 같은지 비교만 하므로 토큰 대신 SHA-256을 둔다.
public struct PushRecord: Codable, Hashable, Sendable {
    public var hostId: String
    /// 기기 토큰의 SHA-256(소문자 16진수).
    public var tokenHash: String
    public var bundleId: String

    public init(hostId: String, token: String, bundleId: String) {
        self.hostId = hostId
        self.tokenHash = Self.hash(token)
        self.bundleId = bundleId
    }

    /// 이 기록이 `token`을 등록한 것인가.
    public func matches(token: String) -> Bool {
        tokenHash == Self.hash(token)
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 알림 스위치와 등록 기록을 둔다. RemoteDebug 앱 전용이다(업데이트 앱과 함께 쓰는 공용 설정에 두지 않는다).
@MainActor
public protocol PushSettingsStoring: AnyObject {
    var enabled: Bool { get set }
    var record: PushRecord? { get set }
    /// 이 Mac(hostId)에 등록을 보낸 적이 있어, 스위치를 끄면 Mac이 지웠다고 확인할 때까지 지우기를 보내야 한다.
    /// 등록 응답을 잃어 `record`가 없어도 Mac에는 토큰이 있을 수 있다.
    var pendingRemoval: String? { get set }
}

/// `UserDefaults`에 둔다. 기기 토큰은 저장하지 않는다(기록에는 SHA-256만 둔다).
/// 예전 형식(토큰을 그대로 둔 기록)은 읽지 않는다. 다음 연결에서 다시 등록한다.
@MainActor
public final class UserDefaultsPushSettingsStore: PushSettingsStoring {
    public static let enabledKey = "RemoteDebug.push.enabled"
    public static let recordKey = "RemoteDebug.push.record"
    public static let pendingRemovalKey = "RemoteDebug.push.pendingRemoval"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    public var record: PushRecord? {
        get { defaults.data(forKey: Self.recordKey).flatMap { try? JSONDecoder().decode(PushRecord.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.recordKey)
            } else {
                defaults.removeObject(forKey: Self.recordKey)
            }
        }
    }

    public var pendingRemoval: String? {
        get { defaults.string(forKey: Self.pendingRemovalKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.pendingRemovalKey) } else { defaults.removeObject(forKey: Self.pendingRemovalKey) }
        }
    }
}

@MainActor
public final class InMemoryPushSettingsStore: PushSettingsStoring {
    public var enabled: Bool
    public var record: PushRecord?
    public var pendingRemoval: String?

    public init(enabled: Bool = false, record: PushRecord? = nil, pendingRemoval: String? = nil) {
        self.enabled = enabled
        self.record = record
        self.pendingRemoval = pendingRemoval ?? record?.hostId
    }
}

/// `ClientModel`에 알림 등록을 켤 때 넘긴다. 넘기지 않으면(업데이트 앱) 등록하지 않는다.
public struct PushSetup {
    public var store: any PushSettingsStoring
    /// APNs 주제(이 앱의 번들 ID).
    public var bundleId: String

    public init(store: any PushSettingsStoring, bundleId: String) {
        self.store = store
        self.bundleId = bundleId
    }
}

/// 설정 화면에 보이는 등록 상태.
public enum PushStatus: Equatable, Sendable {
    /// 스위치가 꺼져 있다.
    case off
    /// 지금 Mac에 이 토큰이 등록돼 있다.
    case registered
    /// 아직 등록하지 못했다. 다음에 Mac에 연결되면 등록한다.
    case pending
    /// Mac 앱이 알림 등록을 모른다(이전 버전).
    case unsupported

    public var label: String {
        switch self {
        case .off: "꺼짐"
        case .registered: "Mac에 등록됨"
        case .pending: "연결되면 등록"
        case .unsupported: "이 Mac은 알림을 지원하지 않음"
        }
    }
}

/// 지금 Mac에 등록하거나 지워야 하는지 정한다. 부작용이 없다.
public enum PushRegistrationPolicy {
    public enum Action: Equatable, Sendable {
        case none
        /// 이 값으로 등록한다.
        case register(PushRecord)
        /// 지금 Mac에서 지운다(스위치를 껐다).
        case remove
        /// 기록만 지운다(다른 Mac의 기록이거나 이 Mac이 알림을 모른다).
        case forget
    }

    /// - `enabled`: 알림 스위치.
    /// - `token`: 이번 실행에서 iOS에게 받은 기기 토큰. 아직 없으면 `nil`.
    /// - `hostId`: 페어링한 Mac. 없으면 아무것도 하지 않는다.
    /// - `record`: 마지막으로 등록에 성공한 값.
    /// - `pendingRemoval`: 등록을 보낸 적이 있어(결과를 모를 수 있다) 끄면 지워야 하는 Mac.
    /// - `confirmedThisRun`: 이번 앱 실행에서 지금 값으로 등록을 확인했는가.
    /// - `unsupported`: 이번 실행에서 이 Mac이 `404 not_found`를 주었다.
    public static func action(
        enabled: Bool, token: String?, bundleId: String, hostId: String?,
        record: PushRecord?, pendingRemoval: String? = nil, confirmedThisRun: Bool, unsupported: Bool
    ) -> Action {
        guard let hostId else { return .none }
        guard enabled else {
            // 기록과 지울 표시가 서로 다른 Mac을 가리킬 수 있다(Mac을 바꾼 뒤 등록 응답을 잃었다). 어느 쪽이든 지금 Mac이면 지운다.
            guard record != nil || pendingRemoval != nil else { return .none }
            let onThisHost = record?.hostId == hostId || pendingRemoval == hostId
            return onThisHost && !unsupported ? .remove : .forget
        }
        guard !unsupported, let token, !token.isEmpty, !bundleId.isEmpty else { return .none }
        let wanted = PushRecord(hostId: hostId, token: token, bundleId: bundleId)
        return record != wanted || !confirmedThisRun ? .register(wanted) : .none
    }
}

/// 알림을 눌렀을 때 갈 탭. 페이로드의 `rd.kind`로 정한다(docs/protocol-addenda.md P).
public enum PushTarget: Equatable, Sendable {
    case builds
    case files
    /// 탭을 바꾸지 않는다(시험 알림, 모르는 종류, `rd` 없음).
    case unchanged

    public init(kind: String?) {
        switch kind {
        case "build": self = .builds
        case "resource": self = .files
        default: self = .unchanged
        }
    }

    /// 알림의 `userInfo`에서 읽는다. 모양이 틀려도 `.unchanged`.
    public init(userInfo: [AnyHashable: Any]) {
        let rd = userInfo["rd"] as? [AnyHashable: Any]
        self.init(kind: rd?["kind"] as? String)
    }
}

extension String {
    /// 진단 로그에 남기는 토큰 앞부분(8자).
    var pushTokenPrefix: String { String(prefix(8)) + "…" }
}
