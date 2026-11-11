import Foundation
import RDBuildInspection
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

/// 게시하는 IPA가 검사한 그 바이트인지, 재게시가 빌드를 잃지 않는지.
@Suite("BuildLibrary 안전")
struct BuildLibrarySafetyTests {
    struct Env {
        let tmp: TempDir
        let core: FakeHostCore
        let inspector: FakeInspector
        let packager: FakePackager
        let lib: BuildLibrary
        var paths: HostPaths { HostPaths(root: tmp.path("host")) }
    }

    func make(_ label: String, keep: Int = 3, now: @escaping @Sendable () -> Date = { Date() }) throws -> Env {
        let tmp = try TempDir(label)
        let core = FakeHostCore()
        let inspector = FakeInspector()
        let packager = FakePackager()
        let lib = BuildLibrary(paths: HostPaths(root: tmp.path("host")), host: core, inspector: inspector, packager: packager,
                               keepPerBundle: keep, now: now)
        return Env(tmp: tmp, core: core, inspector: inspector, packager: packager, lib: lib)
    }

    func restarted(_ env: Env, core: FakeHostCore = FakeHostCore(), packager: FakePackager = FakePackager(),
                   now: @escaping @Sendable () -> Date = { Date() }) -> BuildLibrary {
        BuildLibrary(paths: env.paths, host: core, inspector: FakeInspector(), packager: packager, now: now)
    }

    func publishedIPAs(_ env: Env) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: env.paths.publishedDir.path).filter { $0.hasSuffix(".ipa") && !$0.hasPrefix(".") }
    }

    func workFiles(_ env: Env) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: env.paths.workDir.path)
    }

    func expectNothingPublished(_ env: Env) async throws {
        #expect(env.core.published.isEmpty)
        #expect(await env.lib.builds.isEmpty)
        #expect(try publishedIPAs(env).isEmpty)
        #expect(try workFiles(env).isEmpty)
    }

    // MARK: 검사한 바이트만 게시

    @Test func appChangedBetweenInspectionAndPackagingIsNotPublished() async throws {
        let env = try make("swap-app")
        try await env.lib.load()
        await env.lib.activate()
        let app = try makeImportableApp(in: env.tmp.path("src/Debug-iphoneos"), name: "Good")
        env.inspector.hooks.withLock {
            $0.afterApp = { url in try? Data("rebuilt-with-other-signing".utf8).write(to: url.appendingPathComponent("App")) }
        }
        await #expect(throws: BuildLibraryError.changedDuringImport("Good.app")) { try await env.lib.importBuild(at: app) }
        try await expectNothingPublished(env)
    }

    @Test func folderAndPackageInspectionsMustAgree() async throws {
        let env = try make("disagree")
        try await env.lib.load()
        await env.lib.activate()
        let app = try makeImportableApp(in: env.tmp.path("src"), name: "Good", bundleId: "com.example.good")
        env.inspector.hooks.withLock { $0.ipaBundleOverride = "com.example.other" }
        await #expect(throws: BuildLibraryError.changedDuringImport("Good.app")) { try await env.lib.importBuild(at: app) }
        try await expectNothingPublished(env)
    }

    /// 작업 폴더의 IPA(묶은 것·복사한 것)가 검사 전에 바뀌면 검사한 해시가 만든 해시와 달라 막는다.
    @Test(arguments: ["app", "ipa"])
    func packagedIPAMustBeTheInspectedIPA(kind: String) async throws {
        let env = try make("pkg-changed-\(kind)")
        try await env.lib.load()
        await env.lib.activate()
        let app: URL
        if kind == "app" {
            app = try makeImportableApp(in: env.tmp.path("src"), name: "Good")
        } else {
            app = env.tmp.path("Good.ipa")
            try Data("ipa-bytes".utf8).write(to: app)
        }
        // 묶은 뒤 검사 전에 작업 폴더의 IPA가 바뀜
        env.inspector.hooks.withLock {
            $0.beforeIPA = { url in
                guard let h = try? FileHandle(forWritingTo: url) else { return }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data("x".utf8))
                try? h.close()
            }
        }
        await #expect(throws: BuildLibraryError.changedDuringImport(app.lastPathComponent)) { try await env.lib.importBuild(at: app) }
        try await expectNothingPublished(env)
    }

    @Test func appIsRejectedWhenPackagedIPAFailsInspection() async throws {
        let env = try make("pkg-rejected")
        try await env.lib.load()
        await env.lib.activate()
        let app = try makeImportableApp(in: env.tmp.path("src"), name: "Good")
        env.inspector.hooks.withLock { $0.rejectIPAWithDescriptor = true }
        guard case .rejected(let r) = try await env.lib.importBuild(at: app) else { Issue.record("거부돼야 함"); return }
        #expect(r.codes == [.configurationNotDebug, .getTaskAllowMissing])
        try await expectNothingPublished(env)
    }

    /// 검사 뒤 게시 직전에 작업 사본이 바뀌면 다시 해시해 막는다(.app·.ipa 모두).
    @Test(arguments: ["app", "ipa"])
    func workCopyChangedAfterInspectionIsNotPublished(kind: String) async throws {
        let env = try make("late-change-\(kind)")
        try await env.lib.load()
        await env.lib.activate()
        let source: URL
        if kind == "app" {
            source = try makeImportableApp(in: env.tmp.path("src"), name: "Good")
        } else {
            source = env.tmp.path("Good.ipa")
            try Data("ipa-bytes".utf8).write(to: source)
        }
        env.inspector.hooks.withLock { $0.afterIPA = { url in try? Data("tampered".utf8).write(to: url) } }
        await #expect(throws: BuildLibraryError.changedDuringImport(source.lastPathComponent)) { try await env.lib.importBuild(at: source) }
        try await expectNothingPublished(env)
    }

    @Test func ipaSourceReplacedDuringInspectionPublishesTheInspectedCopy() async throws {
        let env = try make("ipa-swap")
        try await env.lib.load()
        await env.lib.activate()
        let source = env.tmp.path("App.ipa")
        let original = Data("dev-signed-ipa".utf8)
        try original.write(to: source)
        // 검사하는 동안 같은 경로에 다른 IPA가 내보내짐(Organizer 내보내기 등)
        env.inspector.hooks.withLock { $0.beforeIPA = { _ in try? Data("adhoc-export".utf8).write(to: source, options: .atomic) } }

        guard case .accepted(let b) = try await env.lib.importBuild(at: source) else { Issue.record("수락돼야 함"); return }
        #expect(b.descriptor.ipa.sha256 == sha256Hex(original))
        let published = try Data(contentsOf: env.paths.ipaURL(forBuildID: b.id))
        #expect(published == original)
        #expect(env.core.published.first?.build.ipa.sha256 == sha256Hex(original))
    }

    @Test func symlinkedIPAIsCopiedAsRegularFile() async throws {
        let env = try make("ipa-link")
        try await env.lib.load()
        await env.lib.activate()
        let real = env.tmp.path("real/App.ipa")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("linked-ipa".utf8).write(to: real)
        let link = env.tmp.path("latest.ipa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        guard case .accepted(let b) = try await env.lib.importBuild(at: link) else { Issue.record("수락돼야 함"); return }
        let published = env.paths.ipaURL(forBuildID: b.id)
        let type = try FileManager.default.attributesOfItem(atPath: published.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(try Data(contentsOf: published) == Data("linked-ipa".utf8))
        // 나중에 원본이 바뀌어도 게시본은 그대로다.
        try Data("changed-later".utf8).write(to: real)
        #expect(try Data(contentsOf: published) == Data("linked-ipa".utf8))
    }

    @Test(arguments: ["app", "ipa"])
    func rejectedResultIsRejectedEvenWithDescriptor(kind: String) async throws {
        let env = try make("reject-desc-\(kind)")
        try await env.lib.load()
        await env.lib.activate()
        let source: URL
        if kind == "app" {
            source = try makeImportableApp(in: env.tmp.path("src"), name: "Good")
        } else {
            source = env.tmp.path("Good.ipa")
            try Data("ipa".utf8).write(to: source)
        }
        env.inspector.hooks.withLock { $0.rejectWithDescriptor = true }
        guard case .rejected(let r) = try await env.lib.importBuild(at: source) else { Issue.record("거부돼야 함"); return }
        #expect(r.codes == [.configurationNotDebug, .getTaskAllowMissing])
        try await expectNothingPublished(env)
    }

    // MARK: 재게시는 빌드를 잃지 않는다

    func importThree(_ env: Env) async throws -> [String] {
        try await env.lib.load()
        var ids: [String] = []
        for (i, bid) in ["com.a", "com.b", "com.c"].enumerated() {
            let app = try makeImportableApp(in: env.tmp.path("src\(i)"), name: "App\(i)", bundleId: bid)
            guard case .accepted(let b) = try await env.lib.importBuild(at: app) else { throw FakeError() }
            ids.append(b.id)
        }
        return ids
    }

    @Test func cancelledActivateKeepsEveryBuild() async throws {
        let env = try make("cancel")
        let ids = try await importThree(env)
        let core = FakeHostCore()
        let lib = restarted(env, core: core)
        try await lib.load()
        let report = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await lib.activate()
        }.value
        #expect(report.interrupted)
        #expect(report.removed.isEmpty)
        #expect(await lib.builds.map(\.id) == ids.reversed())
        #expect(await lib.isActive == false)
        for id in ids { #expect(FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: id).path)) }
        #expect(try JSONFile<BuildLibrary.Index>(url: env.paths.buildsFile).load()?.builds.count == 3)
        #expect(core.published.isEmpty)
    }

    @Test func cancellationDuringDigestKeepsEveryBuild() async throws {
        let env = try make("cancel-digest")
        let ids = try await importThree(env)
        let packager = FakePackager()
        packager.hooks.withLock { $0.digestError = { _ in CancellationError() } }
        let lib = restarted(env, packager: packager)
        try await lib.load()
        let report = await lib.activate()
        #expect(report.interrupted)
        #expect(await lib.builds.count == 3)
        for id in ids { #expect(FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: id).path)) }
        #expect(try JSONFile<BuildLibrary.Index>(url: env.paths.buildsFile).load()?.builds.count == 3)
    }

    @Test func readErrorKeepsTheBuild() async throws {
        let env = try make("read-error")
        let ids = try await importThree(env)
        let broken = env.paths.ipaURL(forBuildID: ids[0]).lastPathComponent
        let packager = FakePackager()
        packager.hooks.withLock { $0.digestError = { url in url.lastPathComponent == broken ? CocoaError(.fileReadUnknown) : nil } }
        let core = FakeHostCore()
        let lib = restarted(env, core: core, packager: packager)
        try await lib.load()
        let report = await lib.activate()
        #expect(!report.interrupted)
        #expect(report.removed.isEmpty)
        #expect(report.failed.map(\.buildID) == [ids[0]])
        #expect(Set(report.restored) == [ids[1], ids[2]])
        #expect(await lib.builds.count == 3)
        #expect(FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: ids[0]).path))
        #expect(try JSONFile<BuildLibrary.Index>(url: env.paths.buildsFile).load()?.builds.count == 3)
    }

    @Test func republishFailureKeepsTheBuild() async throws {
        let env = try make("republish-fail")
        let ids = try await importThree(env)
        let core = FakeHostCore()
        core.state.withLock { $0.failPublish = true }
        let lib = restarted(env, core: core)
        try await lib.load()
        let report = await lib.activate()
        #expect(Set(report.failed.map(\.buildID)) == Set(ids))
        #expect(report.failed.allSatisfy { $0.message == "사본을 만들지 못했습니다" })  // 코어 문장 그대로, 타입 덤프 없음
        #expect(await lib.builds.count == 3)
        for id in ids { #expect(FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: id).path)) }
        #expect(try JSONFile<BuildLibrary.Index>(url: env.paths.buildsFile).load()?.builds.count == 3)

        // 코어에 없는 빌드(재게시 실패)도 게시 취소할 수 있다(build_not_found는 성공).
        try await lib.unpublish(id: ids[0])
        #expect(await lib.builds.count == 2)
        #expect(!FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: ids[0]).path))
    }

    @Test func expiredProfileIsNotRepublished() async throws {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let env = try make("expired", now: { start })
        let ids = try await importThree(env)
        let core = FakeHostCore()
        let later = start.addingTimeInterval(86_400 * 400)  // 프로필은 가져온 때부터 300일 유효
        let lib = restarted(env, core: core, now: { later })
        try await lib.load()
        let report = await lib.activate()
        #expect(Set(report.expired) == Set(ids))
        #expect(core.published.isEmpty)
        #expect(await lib.builds.isEmpty)
        let rejected = await lib.rejected
        #expect(rejected.count == 3)
        #expect(rejected.allSatisfy { $0.codes == [.profileExpired] })
        for id in ids { #expect(!FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: id).path)) }
    }

    @Test func orphanRemovalTouchesOnlyTopLevelIPAs() async throws {
        let env = try make("orphans")
        let ids = try await importThree(env)
        let fm = FileManager.default
        let pub = env.paths.publishedDir
        // 코어 소유 사본, 숨김 파일, 다른 파일, 바깥을 가리키는 링크, 폴더
        let snapshots = pub.appendingPathComponent(".rd-snapshots", isDirectory: true)
        try fm.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let snapshot = snapshots.appendingPathComponent("\(ids[0]).ipa")
        try Data("snap".utf8).write(to: snapshot)
        let strayInSnapshots = snapshots.appendingPathComponent("b_00000000.ipa")
        try Data("snap2".utf8).write(to: strayInSnapshots)
        let dsStore = pub.appendingPathComponent(".DS_Store")
        try Data("ds".utf8).write(to: dsStore)
        let hiddenIPA = pub.appendingPathComponent(".partial.ipa")
        try Data("hidden".utf8).write(to: hiddenIPA)
        let notes = pub.appendingPathComponent("notes.txt")
        try Data("n".utf8).write(to: notes)
        let outside = env.tmp.path("outside.ipa")
        try Data("outside".utf8).write(to: outside)
        let link = pub.appendingPathComponent("b_11111111.ipa")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let dir = pub.appendingPathComponent("b_22222222.ipa", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let orphan = pub.appendingPathComponent("b_deadbeef.ipa")
        try Data("orphan".utf8).write(to: orphan)

        let lib = restarted(env)
        try await lib.load()
        let report = await lib.activate()
        #expect(report.restored.count == 3)
        for url in [snapshot, strayInSnapshots, dsStore, hiddenIPA, notes, outside, dir] {
            #expect(fm.fileExists(atPath: url.path), "지우면 안 됨: \(url.lastPathComponent)")
        }
        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil, "링크를 지우면 안 됨")
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(!fm.fileExists(atPath: orphan.path))
    }

    // MARK: 저장된 목록을 읽지 못했을 때 (SBX-1)

    @Test func activateWithoutLoadTouchesNothing() async throws {
        let env = try make("no-load")
        try env.paths.prepare()
        let orphan = env.paths.ipaURL(forBuildID: "b_keepme")
        try Data("ipa".utf8).write(to: orphan)
        let report = await env.lib.activate()
        #expect(report.notLoaded)
        #expect(report.interrupted)
        #expect(await env.lib.isActive == false)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: env.paths.buildsFile.path), "읽지 못한 인덱스를 새로 쓰면 안 된다")
    }

    /// 이미 읽은 뒤의 `load`는 가져오는 중인 임시 파일을 지우지 않는다(IMP2-2).
    @Test(.timeLimit(.minutes(1)))
    func loadAfterLoadKeepsAnImportInFlight() async throws {
        let env = try make("load-again")
        try await env.lib.load()
        let gate = Gate()
        env.inspector.hooks.withLock { $0.beforeIPA = { _ in await gate.wait() } }
        let app = try makeImportableApp(in: env.tmp.path("src"), name: "Slow")
        let lib = env.lib
        let importing = Task { try await lib.importBuild(at: app) }
        try #require(await eventually { await gate.arrivals == 1 })
        let temp = try workFiles(env)
        #expect(!temp.isEmpty)

        try await env.lib.load()
        #expect(try workFiles(env) == temp, "가져오는 중인 임시 파일을 지웠다")
        await gate.open()
        guard case .accepted = try await importing.value else { Issue.record("수락돼야 함"); return }
    }

    /// 수락되면 같은 원본의 예전 거부 기록을 지운다(TQ2-5).
    @Test func acceptedImportClearsAnEarlierRejectionOfTheSameSource() async throws {
        let env = try make("accept-clears")
        try await env.lib.load()
        let app = try makeImportableApp(in: env.tmp.path("src"), name: "Rebuilt")
        env.inspector.hooks.withLock { $0.rejectWithDescriptor = true }
        guard case .rejected = try await env.lib.importBuild(at: app) else { Issue.record("거부돼야 함"); return }
        #expect(await env.lib.rejected.count == 1)

        env.inspector.hooks.withLock { $0.rejectWithDescriptor = false }
        guard case .accepted = try await env.lib.importBuild(at: app) else { Issue.record("수락돼야 함"); return }
        #expect(await env.lib.rejected.isEmpty, "게시한 빌드가 거부 목록에 남았다")
    }

    @Test func unreadableIndexIsNeverOverwritten() async throws {
        let env = try make("bad-index")
        try env.paths.prepare()
        let bad = Data("{not json".utf8)
        try bad.write(to: env.paths.buildsFile)
        let orphan = env.paths.ipaURL(forBuildID: "b_keepme")
        try Data("ipa".utf8).write(to: orphan)
        await #expect(throws: (any Error).self) { try await env.lib.load() }

        let report = await env.lib.activate()
        #expect(report.notLoaded)
        let app = try makeImportableApp(in: env.tmp.path("src"), name: "Good")
        await #expect(throws: BuildLibraryError.notLoaded) { try await env.lib.importBuild(at: app) }

        #expect(FileManager.default.fileExists(atPath: orphan.path), "읽지 못했는데 IPA를 지웠다")
        #expect(try Data(contentsOf: env.paths.buildsFile) == bad, "읽지 못한 인덱스를 덮어썼다")
        #expect(env.core.published.isEmpty)
    }

    // MARK: 활성화·비활성화 순서

    @Test func deactivateWinsOverQueuedActivate() async throws {
        let env = try make("queued-activate")
        try await env.lib.load()
        let gate = Gate()
        env.inspector.hooks.withLock { $0.gate = gate }
        let app = try makeImportableApp(in: env.tmp.path("src"), name: "Slow")
        let lib = env.lib
        let importing = Task { try await lib.importBuild(at: app) }
        #expect(await eventually { await gate.arrivals == 1 })
        let activating = Task { await lib.activate() }
        #expect(await eventually { await lib.waitingCount == 1 })
        await lib.deactivate()
        await gate.open()
        guard case .accepted(let b) = try await importing.value else { Issue.record("수락돼야 함"); return }
        let report = await activating.value
        #expect(report.interrupted)
        #expect(await lib.isActive == false)
        #expect(env.core.published.isEmpty)
        #expect(await lib.builds.map(\.id) == [b.id])

        // 다음 활성화에서 게시된다.
        let next = await lib.activate()
        #expect(next.restored == [b.id])
    }

    @Test func pruningKeepsBuildWhenUnpublishFails() async throws {
        let env = try make("prune-fail", keep: 1)
        try await env.lib.load()
        await env.lib.activate()
        func importApp(_ dir: String) async throws -> String {
            let app = try makeImportableApp(in: env.tmp.path(dir), name: "Same", bundleId: "com.same")
            guard case .accepted(let b) = try await env.lib.importBuild(at: app) else { throw FakeError() }
            return b.id
        }
        let first = try await importApp("a")
        env.core.state.withLock { $0.failUnpublish = true }
        let second = try await importApp("b")
        #expect(await env.lib.builds.map(\.id) == [second, first])
        #expect(FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: first).path))

        env.core.state.withLock { $0.failUnpublish = false }
        let third = try await importApp("c")
        #expect(await env.lib.builds.map(\.id) == [third])
        #expect(!FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: first).path))
        #expect(!FileManager.default.fileExists(atPath: env.paths.ipaURL(forBuildID: second).path))
    }
}

/// 진짜 킷으로: 폴더 검사와 묶기 사이에 번들이 다른 서명의 번들로 바뀌면 아무것도 게시하지 않는다.
@Suite("BuildLibrary + 킷: 바꿔치기")
struct BuildLibraryKitSwapTests {
    final class SwappingInspector: BuildInspecting {
        let base = KitBuildInspector()
        let replacement: URL?
        init(replacement: URL?) { self.replacement = replacement }
        let swapped = Mutex(false)

        func inspect(appAt url: URL, options: InspectionOptions) async throws -> InspectionResult {
            let result = try await base.inspect(appAt: url, options: options)
            if let replacement, !swapped.withLock({ let was = $0; $0 = true; return was }) {
                let fm = FileManager.default
                try fm.removeItem(at: url)
                try fm.copyItem(at: replacement, to: url)
            }
            return result
        }

        func inspect(ipaAt url: URL, options: InspectionOptions, workDirectory: URL) async throws -> InspectionResult {
            try await base.inspect(ipaAt: url, options: options, workDirectory: workDirectory)
        }
    }

    func copyFixture(_ name: String, into tmp: TempDir) throws -> URL {
        let dir = tmp.path("DerivedData/Build/Products/Debug-iphoneos")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("App.app")
        try FileManager.default.copyItem(at: Fixtures.app("Debug-iphoneos/\(name).app"), to: dest)
        return dest
    }

    @Test func unswappedCopyIsAccepted() async throws {
        let tmp = try TempDir("kit-copy")
        let app = try copyFixture("AcceptedDev", into: tmp)
        let core = FakeHostCore()
        let lib = BuildLibrary(paths: HostPaths(root: tmp.path("host")), host: core, inspector: SwappingInspector(replacement: nil))
        try await lib.load()
        await lib.activate()
        guard case .accepted(let b) = try await lib.importBuild(at: app) else { Issue.record("수락돼야 함"); return }
        #expect(b.descriptor.configurationEvidence == .path)
        #expect(b.descriptor.configuration == "Debug")
        #expect(core.published.count == 1)
    }

    @Test func swapToNonDebugBuildPublishesNothing() async throws {
        let tmp = try TempDir("kit-swap")
        let app = try copyFixture("AcceptedDev", into: tmp)
        let core = FakeHostCore()
        let inspector = SwappingInspector(replacement: Fixtures.app("Debug-iphoneos/AdhocNoGta.app"))
        let lib = BuildLibrary(paths: HostPaths(root: tmp.path("host")), host: core, inspector: inspector)
        try await lib.load()
        await lib.activate()
        let outcome: ImportOutcome?
        do {
            outcome = try await lib.importBuild(at: app)
        } catch let e as BuildLibraryError {
            #expect(e == .changedDuringImport("App.app"))
            outcome = nil
        }
        if case .accepted = outcome { Issue.record("바뀐 번들이 수락되면 안 됨") }
        #expect(core.published.isEmpty)
        #expect(await lib.builds.isEmpty)
        let ipas = try FileManager.default.contentsOfDirectory(atPath: await lib.paths.publishedDir.path).filter { $0.hasSuffix(".ipa") }
        #expect(ipas.isEmpty)
    }
}
