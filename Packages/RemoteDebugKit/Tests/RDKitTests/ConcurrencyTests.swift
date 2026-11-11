import Foundation
import RDModels
import Testing

@testable import RDBuildInspection
@testable import RDPackaging

/// 교착 감시: 정해진 시간 안에 `finish()`가 불리지 않으면 테스트 실행 전체를 실패로 끝낸다.
/// 협력 스레드 풀이나 GCD 풀이 막혀도 동작하도록 전용 Thread에서 기다린다.
final class Watchdog: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)

    init(seconds: Double, label: String) {
        let done = self.done
        let thread = Thread {
            if done.wait(timeout: .now() + seconds) == .timedOut {
                FileHandle.standardError.write(Data("WATCHDOG: \(label)이(가) \(Int(seconds))초 안에 끝나지 않았습니다(교착). 테스트 실행을 중단합니다.\n".utf8))
                exit(70)
            }
        }
        thread.start()
    }

    func finish() { done.signal() }
}

@Suite struct ConcurrencyTests {
    /// 회귀: SecStaticCodeCheckValidity를 협력 스레드에서 직접 부르던 때에는 코어 수만큼 동시에 검사하면 교착했다.
    /// 동기 API와 비동기 API를 섞어 4 × activeProcessorCount개씩 동시에 돌린다.
    @Test func manyConcurrentInspectionsDoNotDeadlock() async throws {
        let width = 4 * ProcessInfo.processInfo.activeProcessorCount
        let app = Fixtures.app("Debug-iphoneos/AcceptedDev.app")
        let watchdog = Watchdog(seconds: 60, label: "동시 검사 \(width * 3)건")
        defer { watchdog.finish() }
        let started = Date()

        let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for i in 0..<width {
                group.addTask { try BuildInspector.inspect(appAt: app, options: .init()).accepted }
                group.addTask { try await BuildInspector.inspect(appAt: app, options: .init()).accepted }
                if i % 2 == 0 {
                    group.addTask { try CodeSignatureInspector.inspect(bundleAt: app).status == .valid }
                } else {
                    group.addTask { try await CodeSignatureInspector.inspect(bundleAt: app).status == .valid }
                }
            }
            var all: [Bool] = []
            for try await ok in group { all.append(ok) }
            return all
        }
        #expect(accepted.count == width * 3)
        #expect(accepted.allSatisfy { $0 })
        #expect(Date().timeIntervalSince(started) < 30, "동시 검사가 너무 오래 걸렸습니다")
    }

    @Test func concurrentIPAInspectionsDoNotDeadlock() async throws {
        let tmp = try TempDir("conc-ipa")
        let ipa = tmp.path("x.ipa")
        _ = try await IPABuilder.package(appAt: Fixtures.app("loose/DebugDylib.app"), to: ipa)
        let work = tmp.path("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let width = 2 * ProcessInfo.processInfo.activeProcessorCount
        let watchdog = Watchdog(seconds: 60, label: "동시 IPA 검사 \(width * 2)건")
        defer { watchdog.finish() }

        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<width {
                group.addTask { try BuildInspector.inspect(ipaAt: ipa, options: .init(), workDirectory: work).accepted }
                group.addTask { try await BuildInspector.inspect(ipaAt: ipa, options: .init(), workDirectory: work).accepted }
            }
            var all: [Bool] = []
            for try await ok in group { all.append(ok) }
            return all
        }
        #expect(results.count == width * 2 && results.allSatisfy { $0 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty, "풀어 낸 폴더가 남았습니다")
        withExtendedLifetime(tmp) {}
    }

    @Test func asyncAndSyncResultsMatch() async throws {
        for fixture in ["Debug-iphoneos/AcceptedDev.app", "Debug-iphoneos/Expired.app", "Debug-iphoneos/Unsigned.app"] {
            let app = Fixtures.app(fixture)
            let opts = InspectionOptions(now: Date(timeIntervalSince1970: 1_794_387_600))
            // 비동기 문맥에서는 async 판이 우선이므로 동기 판은 동기 클로저로 부른다.
            let sync: () throws -> InspectionResult = { try BuildInspector.inspect(appAt: app, options: opts) }
            let a = try sync()
            let b = try await BuildInspector.inspect(appAt: app, options: opts)
            #expect(a == b, "\(fixture)")
        }
    }

    // MARK: 취소

    @Test func cancelledPackagingThrowsAndLeavesNoPartialFile() async throws {
        let tmp = try TempDir("cancel-pack")
        let app = tmp.path("Big.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        // 여러 청크가 되도록 압축이 잘 안 되는 큰 파일을 둔다.
        var g = SystemRandomNumberGenerator()
        try Data((0..<(6 << 20)).map { _ in UInt8.random(in: 0...255, using: &g) }).write(to: app.appendingPathComponent("blob"))
        let out = tmp.path("Big.ipa")

        // 동기 API: shouldContinue가 첫 진행 보고 뒤 false가 된다.
        let flag = CancelFlag()
        let control = OperationControl(shouldContinue: { !flag.isSet }, progress: { _ in flag.set() })
        #expect(throws: CancellationError.self) { try IPABuilder.package(appAt: app, to: out, control: control) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).sorted() == ["Big.app"], "임시 파일이 남았습니다")

        // 비동기 API: 진행 보고가 오면 태스크를 취소한다.
        let started = DispatchSemaphore(value: 0)
        let task = Task {
            try await IPABuilder.package(appAt: app, to: out, progress: { _ in started.signal() })
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { started.wait(); c.resume() }
        }
        task.cancel()
        let result = await task.result
        // 매우 빠른 기기에서는 취소 전에 끝날 수도 있다. 끝나지 않았다면 반드시 CancellationError여야 한다.
        if case .failure(let error) = result {
            #expect(error is CancellationError, "\(error)")
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).filter { $0.contains(".partial-") }
        #expect(leftovers.isEmpty)
    }

    @Test func cancelledTaskStopsSyncCallsAtChunkBoundary() async throws {
        let tmp = try TempDir("cancel-digest")
        let file = tmp.path("f.bin")
        try Data(count: 3 << 20).write(to: file)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try IPABuilder.fileDigest(at: file)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        withExtendedLifetime(tmp) {}
    }

    @Test func extractionReportsProgressAndCanBeCancelled() throws {
        let tmp = try TempDir("cancel-extract")
        let zip = tmp.path("a.zip")
        let w = try ZipWriter(url: zip)
        try w.addData(Data(count: 3 << 20), name: "a.bin", modified: Date())
        try w.finish()
        let reader = try ZipReader(url: zip)

        let seen = ProgressLog()
        try reader.extractAll(to: tmp.path("ok"), control: OperationControl(progress: { seen.append($0) }))
        #expect(seen.last?.completedBytes == 3 << 20 && seen.last?.totalBytes == 3 << 20)

        #expect(throws: CancellationError.self) {
            try reader.extractAll(to: tmp.path("stop"), control: OperationControl(shouldContinue: { false }))
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ArchiveProgress] = []

    func append(_ p: ArchiveProgress) { lock.withLock { items.append(p) } }
    var last: ArchiveProgress? { lock.withLock { items.last } }
}
