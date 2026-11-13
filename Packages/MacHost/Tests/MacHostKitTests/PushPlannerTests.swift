import Foundation
import RDModels
import Testing
@testable import MacHostKit

func pushBuild(_ id: String, bundleId: String = "com.example.app", name: String = "Sample", version: String = "1.0", build: String = "1",
               at seconds: TimeInterval = 0) -> BuildDescriptor {
    var d = sampleDescriptor(bundleId: bundleId, name: name, now: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
    d.id = id
    d.version = version
    d.buildNumber = build
    return d
}

func pushFile(_ id: String, name: String, link: String? = nil) -> ResourceDescriptor {
    ResourceDescriptor(id: id, name: name, size: link == nil ? 10 : 0, sha256: String(repeating: "0", count: 64),
                       publishedAt: Date(timeIntervalSince1970: 1_800_000_000), link: link)
}

@Suite("알림 판단 규칙")
struct PushPlannerTests {
    @Test func firstObservationIsOnlyABaseline() {
        var tracker = PushTracker()
        #expect(tracker.observe(builds: [pushBuild("b_1")], resources: [pushFile("r_1", name: "a.txt")]).isEmpty)
    }

    @Test func rereadingOrShrinkingSendsNothing() {
        var tracker = PushTracker()
        let builds = [pushBuild("b_1"), pushBuild("b_2")]
        let files = [pushFile("r_1", name: "a.txt"), pushFile("r_2", name: "b.txt")]
        _ = tracker.observe(builds: builds, resources: files)
        #expect(tracker.observe(builds: builds, resources: files).isEmpty)
        #expect(tracker.observe(builds: [builds[0]], resources: [files[1]]).isEmpty)
        #expect(tracker.observe(builds: [], resources: []).isEmpty)
    }

    @Test func newBuildBecomesOneNotification() {
        var tracker = PushTracker()
        _ = tracker.observe(builds: [pushBuild("b_1")], resources: [])
        let changes = tracker.observe(builds: [pushBuild("b_2", name: "데모", version: "2.1", build: "7"), pushBuild("b_1")], resources: [])
        #expect(changes.builds.map(\.id) == ["b_2"])
        var batch = PushBatch()
        batch.add(changes)
        let list = PushPlanner.notifications(for: batch, hideNames: false)
        #expect(list == [APNsNotification(title: "새 빌드", body: "데모 2.1 (7)", kind: .build, id: "b_2")])
    }

    @Test func consecutiveBuildsOfOneAppKeepTheLatest() {
        var batch = PushBatch()
        batch.add(.init(builds: [pushBuild("b_2", build: "2", at: 10)]))
        batch.add(.init(builds: [pushBuild("b_3", build: "3", at: 20)]))
        batch.add(.init(builds: [pushBuild("b_x", bundleId: "com.example.other", name: "Other", at: 15)]))
        let list = PushPlanner.notifications(for: batch, hideNames: false)
        #expect(list.map(\.id) == ["b_x", "b_3"])
        #expect(list.last?.body == "Sample 1.0 (3)")
    }

    @Test func severalFilesBecomeOneNotificationWithoutID() {
        var tracker = PushTracker()
        _ = tracker.observe(builds: [], resources: [])
        let changes = tracker.observe(builds: [], resources: [pushFile("r_1", name: "a.txt"), pushFile("r_2", name: "b.txt"), pushFile("r_3", name: "c.txt")])
        var batch = PushBatch()
        batch.add(changes)
        #expect(PushPlanner.notifications(for: batch, hideNames: false) == [APNsNotification(title: "새 파일", body: "파일 3개", kind: .resource)])
    }

    @Test func fileAndLinkWording() {
        let file = pushFile("r_1", name: "a.txt")
        let link = pushFile("r_2", name: "문서", link: "https://example.com/doc")
        #expect(PushPlanner.resourceNotification([file], hideNames: false) == APNsNotification(title: "새 파일", body: "a.txt", kind: .resource, id: "r_1"))
        #expect(PushPlanner.resourceNotification([link], hideNames: false) == APNsNotification(title: "새 링크", body: "문서", kind: .resource, id: "r_2"))
        #expect(PushPlanner.resourceNotification([link, pushFile("r_3", name: "b", link: "https://example.com/b")], hideNames: false)
            == APNsNotification(title: "새 링크", body: "링크 2개", kind: .resource))
        #expect(PushPlanner.resourceNotification([file, link], hideNames: false) == APNsNotification(title: "새 파일", body: "파일 2개", kind: .resource))
        #expect(PushPlanner.resourceNotification([], hideNames: false) == nil)
    }

    @Test func hiddenNamesUseGenericWordingWithoutID() {
        var batch = PushBatch()
        batch.add(.init(builds: [pushBuild("b_1"), pushBuild("b_2", bundleId: "com.example.other")], resources: [pushFile("r_1", name: "secret.txt")]))
        let list = PushPlanner.notifications(for: batch, hideNames: true)
        #expect(list == [
            APNsNotification(title: "RemoteDebug", body: "새 빌드가 있습니다", kind: .build),
            APNsNotification(title: "RemoteDebug", body: "새 파일이 있습니다", kind: .resource),
        ])
    }

    @Test func resentSameFileIsNotNewButChangedContentIs() {
        // 리소스 id는 이름과 내용 해시로 정해진다: 같은 파일은 같은 id, 내용을 바꾸면 다른 id.
        let same = ResourceDescriptor.makeID(name: "a.txt", sha256: String(repeating: "1", count: 64))
        let changed = ResourceDescriptor.makeID(name: "a.txt", sha256: String(repeating: "2", count: 64))
        var tracker = PushTracker()
        _ = tracker.observe(builds: [], resources: [pushFile(same, name: "a.txt")])
        #expect(tracker.observe(builds: [], resources: [pushFile(same, name: "a.txt")]).isEmpty)
        #expect(tracker.observe(builds: [], resources: [pushFile(changed, name: "a.txt")]).resources.map(\.id) == [changed])
    }

    @Test func testNotificationWording() {
        #expect(PushPlanner.test == APNsNotification(title: "RemoteDebug", body: "시험 알림입니다", kind: .test))
    }
}
