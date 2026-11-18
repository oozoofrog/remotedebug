import Foundation

/// 로그 기록 동의. 사용자가 동의했다는 표시를 앱 데이터 폴더의 빈 파일 하나로 남긴다(기본은 동의하지 않음).
/// UserDefaults를 쓰지 않아, 이 패키지 때문에 개인정보 매니페스트에 적어야 하는 API가 늘지 않는다.
final class FeedbackConsent: @unchecked Sendable {
    /// 동의 표시 파일 이름. 내용은 없고 있느냐 없느냐만 본다.
    static let fileName = "recording-consent"

    /// 이 빌드에서 동의가 있어야 로그를 남기는가. 배포 빌드는 참, 개발 빌드는 거짓이다.
    static var requiredByBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    private let lock = NSLock()
    private let directory: URL?
    private var cached: Bool?

    /// `directory`가 `nil`이면 메모리에만 둔다(시험).
    init(directory: URL?) {
        self.directory = directory
    }

    private var file: URL? { directory?.appendingPathComponent(Self.fileName) }

    var isGranted: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let granted = file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        cached = granted
        return granted
    }

    /// 동의를 남기거나 거둔다. 표시 파일을 쓰지 못하면 동의하지 않은 것으로 둔다.
    @discardableResult
    func set(_ granted: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var result = granted
        if let directory, let file {
            if granted {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                result = (try? Data().write(to: file, options: .atomic)) != nil
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        cached = result
        return result
    }
}

public extension RemoteDebugFeedback {
    /// 이 빌드에서 사용자의 동의가 있어야 로그를 남기는가. 배포 빌드는 언제나 참이고,
    /// Debug 빌드는 `Configuration.requiresConsentInDebug`를 켰을 때만 참이다.
    static var requiresRecordingConsent: Bool { withState { $0.requiresConsent } }

    /// 사용자가 로그 기록에 동의했는가. 기기에 남는 값이고 처음에는 거짓이다.
    static var hasRecordingConsent: Bool { withState { $0.consent }.isGranted }

    /// 지금 로그를 남기고 모아도 되는가. 거짓이면 `log`는 아무것도 남기지 않고, 피드백에 로그를 붙이는 스위치도 보이지 않는다.
    static var isRecordingAllowed: Bool {
        let (required, consent) = withState { ($0.requiresConsent, $0.consent) }
        return !required || consent.isGranted
    }

    /// 로그 기록 동의를 남기거나 거둔다. 사용자가 설명을 읽고 동의한 뒤에만 `true`로 부른다
    /// (`RemoteDebugFeedbackConsentToggle`이 그 화면이다).
    /// `false`로 부르면 이 패키지가 기기에 남긴 것을 모두 지운다: 메모리의 로그, 임시 폴더의 진단 파일,
    /// Debug 빌드에서 Mac에 보내지 못해 쌓아 둔 기록과 확인 목록에 고른 답·메모.
    static func setRecordingConsent(_ granted: Bool) {
        setRecordingConsent(granted, temporaryRoot: FileManager.default.temporaryDirectory, checksDirectory: storedChecksDirectory)
    }

    /// 이 패키지가 기기에 남긴 로그와 파일을 지운다. 동의 여부는 바꾸지 않는다.
    static func deleteRecorded() {
        deleteRecorded(temporaryRoot: FileManager.default.temporaryDirectory, checksDirectory: storedChecksDirectory)
    }
}

extension RemoteDebugFeedback {
    /// 확인 목록과 고른 답을 두는 폴더(Debug 빌드에만 있다). 배포 빌드에는 그 폴더도 이름도 없다.
    static var storedChecksDirectory: URL? {
        #if DEBUG
        FeedbackCheckStore.defaultDirectory()
        #else
        nil
        #endif
    }

    static func setRecordingConsent(_ granted: Bool, temporaryRoot: URL, checksDirectory: URL? = nil) {
        withState { $0.consent }.set(granted)
        if !granted { deleteRecorded(temporaryRoot: temporaryRoot, checksDirectory: checksDirectory) }
    }

    /// `temporaryRoot`: 진단 파일을 두는 임시 폴더의 부모. `checksDirectory`: 확인 목록의 답을 두는 폴더(시험에서 바꿔 넣는다).
    static func deleteRecorded(temporaryRoot: URL, checksDirectory: URL? = nil) {
        FeedbackLog.shared.clear()
        FeedbackSession.removeLeftovers(in: temporaryRoot)
        #if DEBUG
        if let directory = withState({ $0.storage }) { FeedbackClient.removeQueued(in: directory) }
        // 확인 목록에 고른 답과 메모(사용자가 적은 글)와 Mac에서 받아 둔 목록.
        if let checksDirectory { FeedbackCheckStore.removeStored(in: checksDirectory) }
        #endif
    }
}
