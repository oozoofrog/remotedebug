import Foundation
import Testing
@testable import RemoteDebugFeedback

/// 로그 기록 동의: 기본은 꺼짐, 동의 전에는 남기지도 모으지도 않음, 거두면 남긴 것을 지움.
/// 전역 상태를 바꾸는 시험이 서로 섞이지 않게 차례로 돌린다.
@Suite(.serialized)
struct FeedbackConsentTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rdconsent-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func consentIsOffByDefaultPersistsAndIsRemoved() {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let consent = FeedbackConsent(directory: folder)
        #expect(!consent.isGranted, "처음에는 동의하지 않은 상태다")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "읽기만 해서는 아무 파일도 만들지 않는다")
        #expect(consent.set(true) && consent.isGranted)
        #expect(FeedbackConsent(directory: folder).isGranted, "앱을 다시 켜도 남는다")
        #expect(try! Data(contentsOf: folder.appendingPathComponent(FeedbackConsent.fileName)).isEmpty, "표시 파일에는 아무 값도 적지 않는다")
        consent.set(false)
        #expect(!consent.isGranted && !FeedbackConsent(directory: folder).isGranted)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(FeedbackConsent.fileName).path))
    }

    @Test func logRecordsAndCollectsNothingUntilAllowed() {
        let allowed = Flag()
        let log = FeedbackLog(isAllowed: { allowed.value })
        log.add("동의 전")
        #expect(log.recorded.isEmpty, "허용되기 전에는 남기지 않는다")
        #expect(log.collect(window: 900).isEmpty, "허용되기 전에는 시스템 로그도 모으지 않는다")
        allowed.value = true
        log.add("동의 뒤")
        #expect(log.recorded.count == 1 && log.collect(window: 0).contains { $0.hasSuffix("동의 뒤") })
        allowed.value = false
        #expect(log.collect(window: 0).isEmpty, "동의를 거둔 뒤에는 남아 있는 줄도 내주지 않는다")
        log.clear()
        #expect(log.recorded.isEmpty)
    }

    /// 배포 빌드의 정책(동의 필요)을 켜 놓고 공개 API 전체를 지난다.
    @Test func releasePolicyGatesThePublicAPIAndWithdrawingDeletesWhatWasStored() throws {
        let storage = directory(), temporary = directory()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: storage); try? fm.removeItem(at: temporary) }
        let before = RemoteDebugFeedback.withState { ($0.requiresConsent, $0.storage, $0.consent) }
        defer {
            RemoteDebugFeedback.withState { $0.requiresConsent = before.0; $0.storage = before.1; $0.consent = before.2 }
            FeedbackLog.shared.clear()
        }
        RemoteDebugFeedback.withState {
            $0.requiresConsent = true
            $0.storage = storage
            $0.consent = FeedbackConsent(directory: storage)
        }
        FeedbackLog.shared.clear()

        #expect(RemoteDebugFeedback.requiresRecordingConsent && !RemoteDebugFeedback.hasRecordingConsent)
        #expect(!RemoteDebugFeedback.isRecordingAllowed)
        RemoteDebugFeedback.log("동의 전에 남기려는 줄")
        #expect(FeedbackLog.shared.recorded.isEmpty)
        #expect(FeedbackLog.shared.collect().isEmpty)

        RemoteDebugFeedback.setRecordingConsent(true, temporaryRoot: temporary)
        #expect(RemoteDebugFeedback.hasRecordingConsent && RemoteDebugFeedback.isRecordingAllowed)
        RemoteDebugFeedback.log("동의 뒤에 남긴 줄")
        #expect(FeedbackLog.shared.recorded.count == 1)

        // 기기에 남아 있을 수 있는 것: 임시 폴더의 진단 파일, (개발 빌드) Mac에 보내지 못한 기록.
        let leftover = temporary.appendingPathComponent(FeedbackSession.temporaryFolderName, isDirectory: true)
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: leftover.appendingPathComponent("feedback.afdiag"))
        try Data("{}".utf8).write(to: storage.appendingPathComponent("1-queued.json"))
        // 확인 목록에 고른 답과 메모, Mac에서 받아 둔 목록(개발 빌드).
        let checks = directory().appendingPathComponent("RemoteDebugFeedbackChecks", isDirectory: true)
        defer { try? fm.removeItem(at: checks.deletingLastPathComponent()) }
        try fm.createDirectory(at: checks, withIntermediateDirectories: true)
        try Data(#"{"pay.sheet":{"choice":"실패","note":"메모"}}"#.utf8).write(to: checks.appendingPathComponent("answers.json"))
        try Data(#"{"items":[]}"#.utf8).write(to: checks.appendingPathComponent("checklist.json"))

        RemoteDebugFeedback.setRecordingConsent(false, temporaryRoot: temporary, checksDirectory: checks)
        #if DEBUG
        #expect(!fm.fileExists(atPath: checks.appendingPathComponent("answers.json").path), "확인 목록의 답과 메모를 지운다")
        #expect(!fm.fileExists(atPath: checks.path), "비운 폴더도 지운다")
        #expect(RemoteDebugFeedback.storedChecksDirectory == FeedbackCheckStore.defaultDirectory(), "공개 API는 실제 폴더를 지운다")
        #endif
        #expect(!RemoteDebugFeedback.hasRecordingConsent && !RemoteDebugFeedback.isRecordingAllowed)
        #expect(FeedbackLog.shared.recorded.isEmpty, "남긴 로그를 지운다")
        #expect(!fm.fileExists(atPath: leftover.path), "진단 파일을 지운다")
        #if DEBUG
        #expect(!fm.fileExists(atPath: storage.appendingPathComponent("1-queued.json").path), "쌓아 둔 기록을 지운다")
        #endif
        #expect(!fm.fileExists(atPath: storage.appendingPathComponent(FeedbackConsent.fileName).path))
    }

    @Test func buildDecidesWhetherConsentIsRequired() {
        #if DEBUG
        #expect(!FeedbackConsent.requiredByBuild, "개발 빌드는 동의 없이 남긴다")
        #else
        #expect(FeedbackConsent.requiredByBuild, "배포 빌드는 동의가 있어야 남긴다")
        #expect(RemoteDebugFeedback.requiresRecordingConsent)
        #expect(!RemoteDebugFeedback.start(host: "rd-mac-1a2b3c4d.tail0001.ts.net"), "배포 빌드는 Mac 주소를 쓰지 않는다")
        // 아무것도 바꿔 넣지 않은 배포 빌드: 동의가 없으면 공개 API가 아무것도 남기지 않는다.
        if !RemoteDebugFeedback.hasRecordingConsent {
            FeedbackLog.shared.clear()
            RemoteDebugFeedback.log("동의 없이 남기려는 줄")
            #expect(FeedbackLog.shared.recorded.isEmpty && FeedbackLog.shared.collect().isEmpty)
            #expect(!RemoteDebugFeedback.isRecordingAllowed)
        }
        #endif
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
