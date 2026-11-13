import Foundation
import Testing

@testable import PhoneClientKit

/// 시험용 가짜 토큰(실제 기기 토큰이 아니다).
let fakePushToken = String(repeating: "0123abcd", count: 8)
let otherPushToken = String(repeating: "4567cdef", count: 8)
let phoneBundleID = "com.oozoofrog.app.RemoteDebugPhone"

@Suite struct PushRegistrationPolicyTests {
    private let current = PushRecord(hostId: "h_4be0c7a1", token: fakePushToken, bundleId: phoneBundleID)

    private func action(
        enabled: Bool = true, token: String? = fakePushToken, hostId: String? = "h_4be0c7a1",
        record: PushRecord? = nil, pendingRemoval: String? = nil, confirmed: Bool = false, unsupported: Bool = false
    ) -> PushRegistrationPolicy.Action {
        PushRegistrationPolicy.action(enabled: enabled, token: token, bundleId: phoneBundleID, hostId: hostId,
                                      record: record, pendingRemoval: pendingRemoval, confirmedThisRun: confirmed, unsupported: unsupported)
    }

    /// 등록 응답을 잃어 기록이 없어도, 보낸 적이 있는 Mac이면 끌 때 지운다.
    @Test func switchOffRemovesAfterAnUnconfirmedRegistration() {
        #expect(action(enabled: false, record: nil, pendingRemoval: "h_4be0c7a1") == .remove)
        #expect(action(enabled: false, record: nil, pendingRemoval: "h_other000") == .forget)
        #expect(action(enabled: false, record: nil, pendingRemoval: "h_4be0c7a1", unsupported: true) == .forget)
    }

    /// 예전 Mac의 기록이 남은 채 지금 Mac에 보낸 등록의 응답을 잃었다: 끄면 지금 Mac에서 지운다.
    @Test func switchOffRemovesFromThisMacEvenWithAnotherMacsRecord() {
        let other = PushRecord(hostId: "h_other000", token: "aa", bundleId: "b")
        #expect(action(enabled: false, record: other, pendingRemoval: "h_4be0c7a1") == .remove)
        #expect(action(enabled: false, record: other, pendingRemoval: nil) == .forget)
    }

    @Test func switchOffDoesNotRegister() {
        #expect(action(enabled: false) == .none)
    }

    @Test func noTokenDoesNotRegister() {
        #expect(action(token: nil) == .none)
        #expect(action(token: "") == .none)
    }

    @Test func noHostDoesNothing() {
        #expect(action(hostId: nil) == .none)
        #expect(action(enabled: false, hostId: nil, record: current) == .none)
    }

    @Test func sameRecordConfirmedThisRunDoesNotRegister() {
        #expect(action(record: current, confirmed: true) == .none)
    }

    @Test func firstCheckThisRunRegisters() {
        #expect(action(record: current, confirmed: false) == .register(current))
        #expect(action(record: nil) == .register(current))
    }

    @Test func changedTokenRegisters() {
        let old = PushRecord(hostId: "h_4be0c7a1", token: otherPushToken, bundleId: phoneBundleID)
        #expect(action(record: old, confirmed: true) == .register(current))
    }

    @Test func changedHostRegisters() {
        var old = current
        old.hostId = "h_other000"
        #expect(action(record: old, confirmed: true) == .register(current))
    }

    @Test func unsupportedHostIsNotRetried() {
        #expect(action(unsupported: true) == .none)
    }

    @Test func switchOffRemovesFromSameHostOnly() {
        #expect(action(enabled: false, record: current) == .remove)
        var other = current
        other.hostId = "h_other000"
        #expect(action(enabled: false, record: other) == .forget)
        #expect(action(enabled: false, record: current, unsupported: true) == .forget)
        #expect(action(enabled: false, record: nil) == .none)
    }
}

@Suite struct PushOpenTests {
    let build: [AnyHashable: Any] = ["rd": ["kind": "build", "id": "b_9f3a1c2e"]]
    let file: [AnyHashable: Any] = ["rd": ["kind": "resource", "id": "r_1f334c0e"]]

    @Test func actionButtonsMapToTheirWork() {
        #expect(PushOpen(userInfo: build, actionIdentifier: "rd.install") == PushOpen(target: .builds, action: .install, id: "b_9f3a1c2e"))
        #expect(PushOpen(userInfo: file, actionIdentifier: "rd.open") == PushOpen(target: .files, action: .openLink, id: "r_1f334c0e"))
        #expect(PushOpen(userInfo: file, actionIdentifier: "rd.download") == PushOpen(target: .files, action: .download, id: "r_1f334c0e"))
    }

    /// 본문을 눌렀거나, 종류와 맞지 않거나, `id`가 없으면 목록으로만 간다.
    @Test func anythingElseOnlyShowsTheList() {
        #expect(PushOpen(userInfo: build, actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier").action == .show)
        #expect(PushOpen(userInfo: build, actionIdentifier: "rd.show").action == .show)
        #expect(PushOpen(userInfo: build, actionIdentifier: "rd.open").action == .show)
        #expect(PushOpen(userInfo: file, actionIdentifier: "rd.install").action == .show)
        #expect(PushOpen(userInfo: ["rd": ["kind": "build"]], actionIdentifier: "rd.install") == PushOpen(target: .builds))
        #expect(PushOpen(userInfo: [:], actionIdentifier: "rd.install") == PushOpen(target: .unchanged))
    }
}

@Suite struct PushTargetTests {
    @Test func kindPicksTab() {
        #expect(PushTarget(userInfo: ["rd": ["kind": "build", "id": "b_9f3a1c2e"]]) == .builds)
        #expect(PushTarget(userInfo: ["rd": ["kind": "resource"]]) == .files)
        #expect(PushTarget(userInfo: ["rd": ["kind": "test"]]) == .unchanged)
        #expect(PushTarget(userInfo: ["rd": ["kind": "something-new"]]) == .unchanged)
        #expect(PushTarget(userInfo: ["rd": ["kind": 3]]) == .unchanged)
        #expect(PushTarget(userInfo: ["rd": "build"]) == .unchanged)
        #expect(PushTarget(userInfo: ["aps": ["alert": ["title": "RemoteDebug"]]]) == .unchanged)
        #expect(PushTarget(userInfo: [:]) == .unchanged)
    }

    @Test func statusLabels() {
        #expect(PushStatus.registered.label == "Mac에 등록됨")
        #expect(PushStatus.pending.label == "연결되면 등록")
        #expect(PushStatus.unsupported.label == "이 Mac은 알림을 지원하지 않음")
    }

    @Test func logPrefixKeepsEightCharacters() {
        #expect(fakePushToken.pushTokenPrefix == "0123abcd…")
    }
}

@MainActor
@Suite struct PushSettingsStoreTests {
    @Test func userDefaultsRoundTrip() throws {
        let name = "push-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsPushSettingsStore(defaults: defaults)
        #expect(store.enabled == false)
        #expect(store.record == nil)
        let record = PushRecord(hostId: "h_4be0c7a1", token: fakePushToken, bundleId: phoneBundleID)
        store.enabled = true
        store.record = record
        let again = UserDefaultsPushSettingsStore(defaults: defaults)
        #expect(again.enabled)
        #expect(again.record == record)
        again.record = nil
        #expect(store.record == nil)
    }

    /// 기록에는 토큰 대신 SHA-256만 둔다. 예전 형식(토큰 그대로)은 읽지 않는다.
    @Test func recordKeepsOnlyTheTokenHash() throws {
        let name = "push-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsPushSettingsStore(defaults: defaults)
        let record = PushRecord(hostId: "h_4be0c7a1", token: fakePushToken, bundleId: phoneBundleID)
        store.record = record
        store.pendingRemoval = "h_4be0c7a1"
        let raw = try #require(defaults.data(forKey: UserDefaultsPushSettingsStore.recordKey))
        let text = try #require(String(data: raw, encoding: .utf8))
        #expect(!text.contains(fakePushToken))
        #expect(record.tokenHash.count == 64)
        #expect(text.contains(record.tokenHash))
        #expect(record.matches(token: fakePushToken))
        #expect(!record.matches(token: otherPushToken))
        #expect(UserDefaultsPushSettingsStore(defaults: defaults).pendingRemoval == "h_4be0c7a1")

        let old = #"{"hostId":"h_4be0c7a1","token":"\#(fakePushToken)","bundleId":"\#(phoneBundleID)"}"#
        defaults.set(Data(old.utf8), forKey: UserDefaultsPushSettingsStore.recordKey)
        #expect(store.record == nil)
    }
}
