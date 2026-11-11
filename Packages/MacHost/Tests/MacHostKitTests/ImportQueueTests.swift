import Foundation
import RDBuildInspection
import Synchronization
import Testing
@testable import MacHostKit

/// Debug 구성 확인 대화상자의 답이 보여 준 그 빌드에만 적용되는지(MACUI-1, MACAPP-LC-1).
///
/// SwiftUI 대화상자는 버튼을 누르면 버튼 동작과 isPresented setter(false)를 둘 다 부르고, 순서는 정해져 있지 않다.
/// 예전 코드는 setter가 "줄의 첫 항목 건너뛰기"를 해서 한 번의 답이 두 항목을 처리했다. 여기서는 두 호출이
/// 같은 항목 id로 들어오는 경우(버튼 + 중복 답)와 순서가 바뀐 경우를 흉내 낸다.
@MainActor
@Suite("가져오기 확인 줄")
struct ImportQueueTests {
    final class Scope: SecurityScoping {
        let started = Mutex<[URL]>([])
        let stopped = Mutex<[URL]>([])
        let grants: Bool
        init(grants: Bool = true) { self.grants = grants }
        func startAccessing(_ url: URL) -> Bool { started.withLock { $0.append(url) }; return grants }
        func stopAccessing(_ url: URL) { stopped.withLock { $0.append(url) } }
        func starts(_ url: URL) -> Int { started.withLock { $0.filter { $0 == url }.count } }
        func stops(_ url: URL) -> Int { stopped.withLock { $0.filter { $0 == url }.count } }
    }

    nonisolated static func identity(_ url: URL) -> BuildIdentity {
        BuildIdentity(content: .ipa(FileDigest(size: 1, sha256: url.lastPathComponent)), bundleId: "com.example.\(url.lastPathComponent)",
                      version: "1.0", buildNumber: "7")
    }

    /// 첫 시도는 모두 사용자에게 묻게 하고, 확인 뒤 가져오기만 기록한다.
    final class Importer: Sendable {
        let confirmed = Mutex<[URL]>([])
        let answers = Mutex<[BuildIdentity]>([])

        func callAsFunction(_ url: URL, _ mode: ImportMode) async -> ImportOutcome? {
            if case .confirmed(let identity) = mode {
                confirmed.withLock { $0.append(url) }
                answers.withLock { $0.append(identity) }
                return nil
            }
            return .needsConfirmation(ImportQueueTests.identity(url))
        }

        var imported: [URL] { confirmed.withLock { $0 } }
    }

    let a = URL(fileURLWithPath: "/builds/A.app")
    let b = URL(fileURLWithPath: "/builds/B.app")

    func makeQueue() async -> (ImportQueue, Scope, Importer) {
        let scope = Scope()
        let importer = Importer()
        let queue = ImportQueue(scoping: scope)
        await queue.importURLs([a, b]) { await importer($0, $1) }
        return (queue, scope, importer)
    }

    @Test func confirmingAImportsOnlyAAndStillAsksAboutB() async throws {
        let (queue, scope, importer) = await makeQueue()
        let shown = try #require(queue.current)
        #expect(shown.url == a)

        // 버튼 동작: 항목은 동기적으로 빠진다.
        let task = queue.confirm(shown.id) { await importer($0, $1) }
        #expect(queue.current?.url == b, "확인 버튼을 누르는 즉시 A가 줄에서 빠져야 한다")
        // 같은 답이 한 번 더 들어와도(대화상자 setter·더블 클릭) 아무것도 하지 않는다.
        #expect(queue.confirm(shown.id) { await importer($0, $1) } == nil)
        queue.skip(shown.id)
        await task?.value

        #expect(importer.imported == [a], "B는 확인하지 않았으므로 가져오면 안 된다")
        #expect(importer.answers.withLock { $0 } == [Self.identity(a)], "물어본 내용으로 가져온다")
        #expect(scope.starts(a) == 1, "A의 보안 범위를 정확히 한 번 연다")
        #expect(scope.starts(b) == 1, "B의 보안 범위를 정확히 한 번 연다")
        #expect(queue.pending.map(\.url) == [b], "B는 아직 물어야 한다")
        #expect(scope.stops(a) == 1, "A의 보안 범위는 정확히 한 번 놓는다")
        #expect(scope.stops(b) == 0, "묻는 동안 B의 접근을 붙잡아 둔다")
    }

    @Test func skippingADoesNotDropB() async throws {
        let (queue, scope, importer) = await makeQueue()
        let shown = try #require(queue.current)
        queue.skip(shown.id)
        queue.skip(shown.id)  // setter가 한 번 더 부른 것
        #expect(queue.pending.map(\.url) == [b])
        #expect(importer.imported.isEmpty)
        #expect(scope.stops(a) == 1)
        #expect(scope.stops(b) == 0)

        let next = try #require(queue.current)
        let task = queue.confirm(next.id) { await importer($0, $1) }
        await task?.value
        #expect(importer.imported == [b])
        #expect(queue.pending.isEmpty)
        #expect(scope.stops(b) == 1)
    }

    /// 낡은 setter가 버튼보다 먼저 와서 "보여 준 항목 건너뛰기"를 하더라도, 버튼의 답은 그 항목이 이미 빠졌으면
    /// 다른 항목에 넘어가지 않는다.
    @Test func lateAnswerForAnAlreadyHandledItemDoesNotTouchTheNextOne() async throws {
        let (queue, _, importer) = await makeQueue()
        let shown = try #require(queue.current)
        queue.skip(shown.id)
        #expect(queue.confirm(shown.id) { await importer($0, $1) } == nil)
        #expect(importer.imported.isEmpty)
        #expect(queue.pending.map(\.url) == [b])
    }

    @Test func singleUnverifiedBuildIsImportedWhenConfirmed() async throws {
        let scope = Scope()
        let importer = Importer()
        let queue = ImportQueue(scoping: scope)
        await queue.importURLs([a]) { await importer($0, $1) }
        let shown = try #require(queue.current)
        let task = queue.confirm(shown.id) { await importer($0, $1) }
        queue.skip(shown.id)  // 대화상자가 닫히며 들어온 두 번째 호출
        await task?.value
        #expect(importer.imported == [a])
        #expect(queue.pending.isEmpty)
        #expect(scope.stops(a) == 1)
    }

    @Test func acceptedOrOtherwiseRejectedBuildsAreNotQueued() async {
        let scope = Scope()
        let queue = ImportQueue(scoping: scope)
        await queue.importURLs([a, b]) { url, _ in
            url == a ? nil : .rejected(RejectedBuild(sourcePath: url.path, bundleId: nil, reasons: [
                Rejection(code: .configurationUnverified, detail: ""),
                Rejection(code: .profileExpired, detail: ""),
            ], rejectedAt: Date()))
        }
        #expect(queue.pending.isEmpty)
        #expect(scope.starts(a) == 1)
        #expect(scope.starts(b) == 1)
        #expect(scope.stops(a) == 1)
        #expect(scope.stops(b) == 1)
    }

    /// 접근을 열지 못한 URL은 닫지 않는다.
    @Test func scopeThatWasNotGrantedIsNeverStopped() async throws {
        let scope = Scope(grants: false)
        let importer = Importer()
        let queue = ImportQueue(scoping: scope)
        await queue.importURLs([a, b]) { await importer($0, $1) }
        let first = try #require(queue.current)
        await queue.confirm(first.id) { await importer($0, $1) }?.value
        queue.skip(try #require(queue.current).id)
        #expect(scope.starts(a) == 1)
        #expect(scope.starts(b) == 1)
        #expect(scope.stopped.withLock { $0 }.isEmpty)
    }

    // MARK: 물어본 내용과 가져오는 내용 (IQ-1, IQ-2)

    struct Flow {
        let env: BuildLibrarySafetyTests.Env
        let queue: ImportQueue
        let importer: ImportQueue.Importer
    }

    func makeFlow(_ label: String) async throws -> Flow {
        let env = try BuildLibrarySafetyTests().make(label)
        try await env.lib.load()
        await env.lib.activate()
        env.inspector.hooks.withLock { $0.unverifiedUnlessConfirmed = true }
        let lib = env.lib
        let importer: ImportQueue.Importer = { url, mode in try? await lib.importBuild(at: url, mode: mode) }
        return Flow(env: env, queue: ImportQueue(scoping: Scope()), importer: importer)
    }

    func writeIPA(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test(arguments: ["app", "ipa"])
    func swappedContentIsNotPublishedAfterConfirmation(kind: String) async throws {
        let flow = try await makeFlow("swap-\(kind)")
        let env = flow.env
        let source: URL
        if kind == "app" {
            source = try makeImportableApp(in: env.tmp.path("src"), name: "Asked", bundleId: "com.example.asked")
        } else {
            source = env.tmp.path("src/Asked.ipa")
            try writeIPA(source, "asked")
        }
        await flow.queue.importURLs([source], using: flow.importer)
        let item = try #require(flow.queue.current)
        #expect(await env.lib.rejected.isEmpty)

        if kind == "app" {
            try Data("different-content-after-the-question".utf8).write(to: source.appendingPathComponent("App"))
        } else {
            try writeIPA(source, "different-content-after-the-question")
        }
        let lib = env.lib
        var thrown: (any Error)?
        await flow.queue.confirm(item.id) { url, mode in
            do { return try await lib.importBuild(at: url, mode: mode) } catch { thrown = error; return nil }
        }?.value

        #expect(thrown as? BuildLibraryError == .changedSinceConfirmation(source.lastPathComponent))
        #expect((thrown as? LocalizedError)?.errorDescription?.contains("다시 가져와") == true)
        #expect(flow.queue.pending.isEmpty, "답한 항목은 줄에서 빠진다")
        #expect(env.core.published.isEmpty)
        #expect(await env.lib.builds.isEmpty)
        #expect(try BuildLibrarySafetyTests().publishedIPAs(env).isEmpty)
        #expect(try BuildLibrarySafetyTests().workFiles(env).isEmpty)
    }

    /// 파일 내용이 같아도 검사한 번들 ID·버전·빌드 번호가 물어본 것과 다르면 게시하지 않는다.
    @Test(arguments: ["bundleId", "version", "buildNumber"])
    func differentReportedIdentityIsNotPublished(field: String) async throws {
        let flow = try await makeFlow("swap-\(field)")
        let env = flow.env
        let source = env.tmp.path("src/Asked.ipa")
        try writeIPA(source, "asked")
        await flow.queue.importURLs([source], using: flow.importer)
        let item = try #require(flow.queue.current)
        env.inspector.hooks.withLock {
            switch field {
            case "bundleId": $0.ipaBundleOverride = "com.example.other"
            case "version": $0.versionOverride = "9.9"
            default: $0.buildNumberOverride = "999"
            }
        }
        let lib = env.lib
        var thrown: (any Error)?
        await flow.queue.confirm(item.id) { url, mode in
            do { return try await lib.importBuild(at: url, mode: mode) } catch { thrown = error; return nil }
        }?.value
        #expect(thrown as? BuildLibraryError == .changedSinceConfirmation(source.lastPathComponent))
        #expect(env.core.published.isEmpty)
        #expect(await env.lib.builds.isEmpty)
        #expect(try BuildLibrarySafetyTests().publishedIPAs(env).isEmpty)
        #expect(try BuildLibrarySafetyTests().workFiles(env).isEmpty)
    }

    @Test func sameContentIsImportedAndNoRejectionRemains() async throws {
        let flow = try await makeFlow("same")
        let source = try makeImportableApp(in: flow.env.tmp.path("src"), name: "Asked", bundleId: "com.example.asked")
        await flow.queue.importURLs([source], using: flow.importer)
        let item = try #require(flow.queue.current)
        #expect(item.identity.bundleId == "com.example.asked")
        #expect(item.identity.version == "1.0")
        #expect(item.identity.buildNumber == "1")
        #expect(await flow.env.lib.rejected.isEmpty, "답을 기다리는 빌드는 거부 목록에 없다")
        #expect(flow.env.core.published.isEmpty, "답하기 전에는 게시하지 않는다")

        await flow.queue.confirm(item.id, using: flow.importer)?.value
        #expect(flow.env.core.published.count == 1)
        #expect(flow.env.core.published.first?.build.configurationEvidence == .path)
        #expect(await flow.env.lib.rejected.isEmpty)
    }

    @Test func twoPendingItemsStayIndependent() async throws {
        let flow = try await makeFlow("two")
        let first = try makeImportableApp(in: flow.env.tmp.path("src"), name: "First", bundleId: "com.example.first")
        let second = try makeImportableApp(in: flow.env.tmp.path("src"), name: "Second", bundleId: "com.example.second")
        await flow.queue.importURLs([first, second], using: flow.importer)
        #expect(flow.queue.pending.map(\.identity.bundleId) == ["com.example.first", "com.example.second"])

        // 첫 항목의 내용이 바뀌어 거절돼도 둘째 항목은 그대로 가져올 수 있다.
        try Data("first-changed-after-the-question".utf8).write(to: first.appendingPathComponent("App"))
        let firstItem = try #require(flow.queue.current)
        await flow.queue.confirm(firstItem.id, using: flow.importer)?.value
        #expect(flow.env.core.published.isEmpty)
        let secondItem = try #require(flow.queue.current)
        #expect(secondItem.url == second)
        await flow.queue.confirm(secondItem.id, using: flow.importer)?.value
        #expect(flow.env.core.published.map(\.build.bundleId) == ["com.example.second"])
    }

    @Test(arguments: [true, false])
    func staleRejectionIsRemovedOncePublishedOrSkipped(publish: Bool) async throws {
        let flow = try await makeFlow("stale-\(publish)")
        let source = try makeImportableApp(in: flow.env.tmp.path("src"), name: "Asked")
        // 감시 폴더처럼 묻지 않는 가져오기가 먼저 거부를 남겼다.
        guard case .rejected = try await flow.env.lib.importBuild(at: source) else { Issue.record("거부돼야 함"); return }
        #expect(await flow.env.lib.rejected.count == 1)

        await flow.queue.importURLs([source], using: flow.importer)
        let item = try #require(flow.queue.current)
        #expect(await flow.env.lib.rejected.isEmpty, "답을 기다리는 동안 거부 목록에 함께 보이면 안 된다")

        if publish {
            await flow.queue.confirm(item.id, using: flow.importer)?.value
            #expect(flow.env.core.published.count == 1)
        } else {
            flow.queue.skip(item.id)
            #expect(flow.env.core.published.isEmpty)
        }
        #expect(await flow.env.lib.rejected.isEmpty)
    }

    /// 다른 이유로 거부되는 빌드는 묻지 않고 거부 목록에 남는다.
    @Test func otherRejectionsAreRecordedNotAsked() async throws {
        let flow = try await makeFlow("other")
        let source = try makeImportableApp(in: flow.env.tmp.path("src"), name: "RejectMe")
        flow.env.inspector.hooks.withLock { $0.unverifiedUnlessConfirmed = false }
        await flow.queue.importURLs([source], using: flow.importer)
        #expect(flow.queue.pending.isEmpty)
        #expect(await flow.env.lib.rejected.count == 1)
    }
}
