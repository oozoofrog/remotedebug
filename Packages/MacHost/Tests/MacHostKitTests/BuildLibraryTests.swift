import Foundation
import RDBuildInspection
import RDModels
import Testing
@testable import MacHostKit

@Suite("BuildLibrary")
struct BuildLibraryTests {
    func makeLibrary(_ tmp: TempDir, core: FakeHostCore, inspector: FakeInspector = FakeInspector(), keep: Int = 3, maxRejected: Int = 50) -> BuildLibrary {
        BuildLibrary(paths: HostPaths(root: tmp.path("host")), host: core, inspector: inspector, packager: FakePackager(),
                     keepPerBundle: keep, maxRejected: maxRejected)
    }

    @Test func acceptedImportPublishes() async throws {
        let tmp = try TempDir("accept")
        let core = FakeHostCore()
        let lib = makeLibrary(tmp, core: core)
        try await lib.load()
        await lib.activate()
        let app = try makeImportableApp(in: tmp.path("src"), name: "Good", bundleId: "com.example.good")

        let outcome = try await lib.importBuild(at: app)
        guard case .accepted(let build) = outcome else { Issue.record("수락돼야 함: \(outcome)"); return }

        let paths = await lib.paths
        let ipa = paths.ipaURL(forBuildID: build.id)
        #expect(core.published.count == 1)
        #expect(core.published.first?.ipaPath == ipa.path)
        #expect(core.published.first?.build == build.descriptor)
        let data = try Data(contentsOf: ipa)
        #expect(build.descriptor.ipa.sha256 == sha256Hex(data))
        #expect(build.descriptor.ipa.size == Int64(data.count))
        #expect(build.id == BuildDescriptor.makeID(bundleId: "com.example.good", ipaSHA256: sha256Hex(data)))
        // 인덱스 저장
        let saved = try JSONFile<BuildLibrary.Index>(url: paths.buildsFile).load()
        #expect(saved?.builds.map(\.id) == [build.id])
        // 작업 폴더에 임시 파일이 남지 않는다
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.workDir.path).isEmpty)
    }

    @Test func rejectedImportExposesReasonsWithoutPublishing() async throws {
        let tmp = try TempDir("reject")
        let core = FakeHostCore()
        let lib = makeLibrary(tmp, core: core)
        try await lib.load()
        await lib.activate()
        let app = try makeImportableApp(in: tmp.path("src"), name: "RejectMe", bundleId: "com.example.bad")

        let outcome = try await lib.importBuild(at: app)
        guard case .rejected(let rejected) = outcome else { Issue.record("거부돼야 함"); return }
        #expect(rejected.codes == [.configurationNotDebug, .getTaskAllowMissing])
        #expect(rejected.bundleId == "com.example.bad")
        #expect(rejected.messages.count == 2)
        #expect(rejected.messages[0].contains("Debug 구성"))
        #expect(core.published.isEmpty)
        #expect(await lib.builds.isEmpty)
        #expect(await lib.rejected.map(\.id) == [rejected.id])
        let published = try FileManager.default.contentsOfDirectory(atPath: await lib.paths.publishedDir.path)
        #expect(published.filter { $0.hasSuffix(".ipa") }.isEmpty)
    }

    @Test func unreadableBuildIsRejectedWithCode() async throws {
        let tmp = try TempDir("unreadable")
        let core = FakeHostCore()
        let lib = makeLibrary(tmp, core: core)
        try await lib.load()
        let app = try makeImportableApp(in: tmp.path("src"), name: "Unreadable")
        let outcome = try await lib.importBuild(at: app)
        guard case .rejected(let r) = outcome else { Issue.record("거부돼야 함"); return }
        #expect(r.codes == [.unreadable])
        #expect(!r.messages.isEmpty)
    }

    @Test func unsupportedFileThrows() async throws {
        let tmp = try TempDir("unsupported")
        let lib = makeLibrary(tmp, core: FakeHostCore())
        try await lib.load()
        let file = tmp.path("notes.txt")
        try Data("x".utf8).write(to: file)
        await #expect(throws: BuildLibraryError.unsupportedFile("notes.txt")) {
            try await lib.importBuild(at: file)
        }
    }

    @Test func rejectedListIsCapped() async throws {
        let tmp = try TempDir("cap")
        let lib = makeLibrary(tmp, core: FakeHostCore(), maxRejected: 3)
        try await lib.load()
        for i in 0..<5 {
            _ = try await lib.importBuild(at: try makeImportableApp(in: tmp.path("src"), name: "Reject\(i)"))
        }
        let rejected = await lib.rejected
        #expect(rejected.count == 3)
        #expect(rejected.first?.fileName == "Reject4.app")
    }

    @Test func keepsNewestNPerBundle() async throws {
        let tmp = try TempDir("retain")
        let core = FakeHostCore()
        let lib = makeLibrary(tmp, core: core, keep: 3)
        try await lib.load()
        await lib.activate()
        var ids: [String] = []
        for i in 0..<5 {
            let app = try makeImportableApp(in: tmp.path("src\(i)"), name: "App", bundleId: "com.example.same")
            guard case .accepted(let b) = try await lib.importBuild(at: app) else { Issue.record("수락돼야 함"); return }
            ids.append(b.id)
        }
        let other = try makeImportableApp(in: tmp.path("other"), name: "Other", bundleId: "com.example.other")
        guard case .accepted(let otherBuild) = try await lib.importBuild(at: other) else { Issue.record("수락돼야 함"); return }

        let builds = await lib.builds
        #expect(builds.map(\.id) == [otherBuild.id, ids[4], ids[3], ids[2]])
        #expect(core.unpublished == [ids[0], ids[1]])
        let paths = await lib.paths
        for old in ids.prefix(2) { #expect(!FileManager.default.fileExists(atPath: paths.ipaURL(forBuildID: old).path)) }
        for kept in builds { #expect(FileManager.default.fileExists(atPath: paths.ipaURL(forBuildID: kept.id).path)) }
    }

    @Test func importWhileInactiveDefersPublishUntilActivate() async throws {
        let tmp = try TempDir("inactive")
        let core = FakeHostCore()
        let lib = makeLibrary(tmp, core: core)
        try await lib.load()
        let app = try makeImportableApp(in: tmp.path("src"), name: "Later")
        guard case .accepted(let b) = try await lib.importBuild(at: app) else { Issue.record("수락돼야 함"); return }
        #expect(core.published.isEmpty)
        let report = await lib.activate()
        #expect(report.restored == [b.id])
        #expect(core.published.map(\.build.id) == [b.id])
    }

    @Test func restoreRepublishesAndDropsMissingOrChangedIPAs() async throws {
        let tmp = try TempDir("restore")
        let first = FakeHostCore()
        let lib = makeLibrary(tmp, core: first)
        try await lib.load()
        var ids: [String] = []
        for (i, bid) in ["com.a", "com.b", "com.c"].enumerated() {
            let app = try makeImportableApp(in: tmp.path("src\(i)"), name: "App\(i)", bundleId: bid)
            guard case .accepted(let b) = try await lib.importBuild(at: app) else { Issue.record("수락돼야 함"); return }
            ids.append(b.id)
        }
        let paths = await lib.paths
        // 하나는 지우고, 하나는 내용을 바꾸고, 목록에 없는 IPA를 하나 둔다.
        try FileManager.default.removeItem(at: paths.ipaURL(forBuildID: ids[0]))
        try Data("tampered".utf8).write(to: paths.ipaURL(forBuildID: ids[1]))
        let orphan = paths.publishedDir.appendingPathComponent("b_deadbeef.ipa")
        try Data("orphan".utf8).write(to: orphan)

        // 앱 재시작: 새 인스턴스가 인덱스를 읽고 다시 게시한다.
        let second = FakeHostCore()
        let restarted = makeLibrary(tmp, core: second)
        try await restarted.load()
        #expect(await restarted.builds.count == 3)
        let report = await restarted.activate()

        #expect(report.restored == [ids[2]])
        #expect(Set(report.removed) == [ids[0], ids[1]])
        #expect(second.published.map(\.build.id) == [ids[2]])
        #expect(second.published.first?.ipaPath == paths.ipaURL(forBuildID: ids[2]).path)
        #expect(await restarted.builds.map(\.id) == [ids[2]])
        #expect(!FileManager.default.fileExists(atPath: paths.ipaURL(forBuildID: ids[1]).path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let saved = try JSONFile<BuildLibrary.Index>(url: paths.buildsFile).load()
        #expect(saved?.builds.map(\.id) == [ids[2]])
    }

    @Test func publishFailureLeavesNoFileAndThrows() async throws {
        let tmp = try TempDir("pubfail")
        let core = FakeHostCore()
        core.state.withLock { $0.failPublish = true }
        let lib = makeLibrary(tmp, core: core)
        try await lib.load()
        await lib.activate()
        let app = try makeImportableApp(in: tmp.path("src"), name: "Fails")
        await #expect(throws: BuildLibraryError.self) { try await lib.importBuild(at: app) }
        #expect(await lib.builds.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: await lib.paths.publishedDir.path)
        #expect(files.filter { $0.hasSuffix(".ipa") }.isEmpty)
    }

    @Test func unpublishRemovesFromCoreDiskAndIndex() async throws {
        let tmp = try TempDir("unpub")
        let core = FakeHostCore()
        let lib = makeLibrary(tmp, core: core)
        try await lib.load()
        await lib.activate()
        guard case .accepted(let b) = try await lib.importBuild(at: try makeImportableApp(in: tmp.path("src"), name: "X")) else {
            Issue.record("수락돼야 함"); return
        }
        try await lib.unpublish(id: b.id)
        #expect(core.unpublished == [b.id])
        #expect(await lib.builds.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: await lib.paths.ipaURL(forBuildID: b.id).path))
        await #expect(throws: BuildLibraryError.unknownBuild(b.id)) { try await lib.unpublish(id: b.id) }
    }

    @Test func importsInspectOneAtATime() async throws {
        let tmp = try TempDir("serial")
        let inspector = FakeInspector(delay: .milliseconds(5))
        let core = FakeHostCore()
        let lib = makeLibrary(tmp, core: core, inspector: inspector, keep: 10)
        try await lib.load()
        await lib.activate()
        var apps: [URL] = []
        for i in 0..<6 { apps.append(try makeImportableApp(in: tmp.path("src\(i)"), name: "P\(i)", bundleId: "com.p\(i)")) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for app in apps { group.addTask { _ = try await lib.importBuild(at: app) } }
            try await group.waitForAll()
        }
        #expect(inspector.count == 12)  // .app마다 폴더 검사 + 만든 IPA 검사
        #expect(inspector.maxConcurrent == 1)
        #expect(await lib.builds.count == 6)
        #expect(core.published.count == 6)
    }

    @Test func ipaImportCopiesIntoPublishedFolder() async throws {
        let tmp = try TempDir("ipa")
        let core = FakeHostCore()
        let lib = makeLibrary(tmp, core: core)
        try await lib.load()
        await lib.activate()
        let source = tmp.path("Thing.ipa")
        try Data("ipa-bytes".utf8).write(to: source)
        guard case .accepted(let b) = try await lib.importBuild(at: source) else { Issue.record("수락돼야 함"); return }
        #expect(b.descriptor.ipa.sha256 == sha256Hex(Data("ipa-bytes".utf8)))
        let copy = await lib.paths.ipaURL(forBuildID: b.id)
        #expect(try Data(contentsOf: copy) == Data("ipa-bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

@Suite("BuildLibrary + 킷 검사기")
struct BuildLibraryKitIntegrationTests {
    @Test func realKitAcceptsDebugFixtureAndPublishes() async throws {
        let tmp = try TempDir("kit-accept")
        let core = FakeHostCore()
        let lib = BuildLibrary(paths: HostPaths(root: tmp.path("host")), host: core)
        try await lib.load()
        await lib.activate()

        let outcome = try await lib.importBuild(at: Fixtures.app("Debug-iphoneos/AcceptedDev.app"))
        guard case .accepted(let b) = outcome else { Issue.record("수락돼야 함: \(outcome)"); return }
        #expect(b.descriptor.debug)
        #expect(b.descriptor.signing.getTaskAllow)
        #expect(b.descriptor.configuration == "Debug")
        let ipa = await lib.paths.ipaURL(forBuildID: b.id)
        let digest = try await KitBuildPackager().digest(of: ipa)
        #expect(digest == FileDigest(size: b.descriptor.ipa.size, sha256: b.descriptor.ipa.sha256))
        #expect(core.published.map(\.build) == [b.descriptor])

        // 만든 IPA를 다시 가져와도(.ipa 경로) 같은 빌드로 수락된다.
        let exported = tmp.path("Again.ipa")
        try FileManager.default.copyItem(at: ipa, to: exported)
        // IPA에는 구성 폴더 정보가 없어 사용자 확인 없이는 거부된다.
        let unconfirmed = try await lib.importBuild(at: exported)
        guard case .rejected(let r) = unconfirmed else { Issue.record("확인 없이는 거부돼야 함: \(unconfirmed)"); return }
        #expect(r.codes == [.configurationUnverified])
        guard case .needsConfirmation(let identity) = try await lib.importBuild(at: exported, mode: .askIfUnverified) else {
            Issue.record("구성을 물어야 함"); return
        }
        #expect(identity.bundleId == b.descriptor.bundleId)
        #expect(identity.version == b.descriptor.version)
        #expect(identity.buildNumber == b.descriptor.buildNumber)
        let again = try await lib.importBuild(at: exported, mode: .confirmed(identity))
        guard case .accepted(let b2) = again else { Issue.record("IPA 재가져오기 수락돼야 함: \(again)"); return }
        #expect(b2.id == b.id)
        #expect(await lib.builds.count == 1)
    }

    @Test func realKitRejectsDistributionProfileFixture() async throws {
        let tmp = try TempDir("kit-reject")
        let core = FakeHostCore()
        let lib = BuildLibrary(paths: HostPaths(root: tmp.path("host")), host: core)
        try await lib.load()
        await lib.activate()

        let outcome = try await lib.importBuild(at: Fixtures.app("Debug-iphoneos/AdHocDist.app"))
        guard case .rejected(let r) = outcome else { Issue.record("거부돼야 함: \(outcome)"); return }
        #expect(r.codes.contains(.notDevelopmentProfile))
        #expect(r.messages.contains { $0.contains("개발용 프로필이 아닙니다") })
        #expect(core.published.isEmpty)
    }
}
