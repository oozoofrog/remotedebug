import Foundation
import Synchronization
import Testing
@testable import MacHostKit

@Suite("FolderScanner")
struct FolderScannerTests {
    @Test func findsDeviceAppsInBothLayouts() throws {
        let tmp = try TempDir("scan")
        let root = tmp.path("root")
        let direct = try makeFakeApp(at: root.appendingPathComponent("Debug-iphoneos/Direct.app"))
        let products = root.appendingPathComponent("DerivedData/Proj-abc/Build/Products")
        let derived = try makeFakeApp(at: products.appendingPathComponent("Debug-iphoneos/Derived.app"))
        let release = try makeFakeApp(at: products.appendingPathComponent("Release-iphoneos/Rel.app"))
        try makeFakeApp(at: products.appendingPathComponent("Debug-iphoneos/DerivedUITests-Runner.app"))
        try makeFakeApp(at: products.appendingPathComponent("Debug-iphonesimulator/Sim.app"))
        try makeFakeApp(at: root.appendingPathComponent("Other/Debug-iphoneos/NotUnderBuild.app"))
        try makeFakeApp(at: root.appendingPathComponent(".hidden/Build/Products/Debug-iphoneos/Hidden.app"))
        // 깊이 제한 밖
        let deep = (0..<4).reduce(root) { u, i in u.appendingPathComponent("d\(i)") }
        try makeFakeApp(at: deep.appendingPathComponent("Build/Products/Debug-iphoneos/Deep.app"))

        let found = FolderScanner(maxDepth: 2).findApps(in: root).map(\.path)
        #expect(Set(found) == Set([direct, derived, release].map(\.standardizedFileURL.path)))

        let deeper = FolderScanner(maxDepth: 8).findApps(in: root).map(\.lastPathComponent)
        #expect(deeper.contains("Deep.app"))
    }

    @Test func bundleWithoutInfoPlistIsBuilding() throws {
        let tmp = try TempDir("state")
        let app = try makeFakeApp(at: tmp.path("A.app"), withInfoPlist: false)
        #expect(FolderScanner.state(of: app) == .building)

        let ready = try makeFakeApp(at: tmp.path("B.app"), payload: "12345")
        guard case .ready(let fp) = FolderScanner.state(of: ready) else { Issue.record("준비돼야 함"); return }
        #expect(fp.executableSize == 5)

        // 실행 파일이 아직 없음
        let noExe = try makeFakeApp(at: tmp.path("C.app"))
        try FileManager.default.removeItem(at: noExe.appendingPathComponent("App"))
        #expect(FolderScanner.state(of: noExe) == .building)
    }
}

@Suite("FolderWatcher")
struct FolderWatcherTests {
    final class Received: Sendable {
        let urls = Mutex<[String]>([])
        let accept = Mutex(true)
        var names: [String] { urls.withLock { $0.map { URL(fileURLWithPath: $0).lastPathComponent } } }
        func handler() -> FolderWatcher.BuildHandler {
            { url in
                self.urls.withLock { $0.append(url.path) }
                return self.accept.withLock { $0 }
            }
        }
    }

    @Test func fingerprintSkipsUnchangedAndRetriesBuildingBundles() async throws {
        let tmp = try TempDir("watch-fp")
        let root = tmp.path("root")
        let config = root.appendingPathComponent("Debug-iphoneos")
        let a = try makeFakeApp(at: config.appendingPathComponent("A.app"), payload: "aaa")
        let b = try makeFakeApp(at: config.appendingPathComponent("B.app"), withInfoPlist: false)
        let received = Received()
        let watcher = FolderWatcher(root: root, options: .init(useFileEvents: false), onBuild: received.handler())

        await watcher.start()
        #expect(received.names == ["A.app"])
        #expect(await watcher.buildingApps.map(\.lastPathComponent) == ["B.app"])

        await watcher.rescan()
        #expect(received.names == ["A.app"])  // 지문이 같아 다시 넘기지 않는다

        // 빌드가 끝남 → 넘김. A의 실행 파일이 바뀜 → 다시 넘김.
        try makeFakeApp(at: b)
        try Data("aaaa-new".utf8).write(to: a.appendingPathComponent("App"))
        await watcher.rescan()
        #expect(received.names.sorted() == ["A.app", "A.app", "B.app"])
        #expect(await watcher.buildingApps.isEmpty)
        await watcher.stop()
    }

    @Test func failedHandlingIsRetriedOnNextScan() async throws {
        let tmp = try TempDir("watch-retry")
        let root = tmp.path("root")
        try makeFakeApp(at: root.appendingPathComponent("Debug-iphoneos/A.app"))
        let received = Received()
        received.accept.withLock { $0 = false }
        let watcher = FolderWatcher(root: root, options: .init(useFileEvents: false), onBuild: received.handler())
        await watcher.start()
        received.accept.withLock { $0 = true }
        await watcher.rescan()
        await watcher.rescan()
        #expect(received.names == ["A.app", "A.app"])
    }

    @Test func changesAreDebounced() async throws {
        let tmp = try TempDir("watch-debounce")
        let root = tmp.path("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sleeper = ManualSleeper()
        let received = Received()
        let options = FolderWatcher.Options(debounce: .seconds(2), sleep: { await sleeper.sleep($0) }, useFileEvents: false)
        let watcher = FolderWatcher(root: root, options: options, onBuild: received.handler())
        await watcher.start()
        #expect(await watcher.scanCount == 1)

        try makeFakeApp(at: root.appendingPathComponent("Debug-iphoneos/A.app"))
        await watcher.fileSystemChanged()
        await watcher.fileSystemChanged()
        await watcher.fileSystemChanged()
        #expect(await eventually { await sleeper.pendingCount == 3 })
        #expect(await watcher.scanCount == 1)  // 지연이 끝나기 전에는 훑지 않는다

        await sleeper.releaseAll()
        #expect(await eventually { await watcher.scanCount == 2 })
        // 마지막 알림 하나만 검사로 이어진다
        for _ in 0..<50 { await Task.yield() }
        #expect(await watcher.scanCount == 2)
        #expect(received.names == ["A.app"])
        #expect(await sleeper.requested == [.seconds(2), .seconds(2), .seconds(2)])

        // 멈춘 뒤의 알림은 무시한다
        await watcher.stop()
        await watcher.fileSystemChanged()
        #expect(await sleeper.pendingCount == 0)
    }
}

@Suite("FolderScanner·FolderWatcher 보강")
struct FolderWatcherStateTests {
    final class Box: Sendable {
        let watcher = Mutex<FolderWatcher?>(nil)
        let names = Mutex<[String]>([])
    }

    @Test func scannerFindsAppsWhenBuildOrProductsFolderIsChosen() throws {
        let tmp = try TempDir("scan-build")
        let build = tmp.path("DerivedData/Proj-abc/Build")
        let app = try makeFakeApp(at: build.appendingPathComponent("Products/Debug-iphoneos/App.app"))
        try makeFakeApp(at: build.appendingPathComponent("Intermediates.noindex/Debug-iphoneos/Hidden.app"))
        let expected = [app.standardizedFileURL.path]
        #expect(FolderScanner().findApps(in: build).map(\.path) == expected)
        #expect(FolderScanner().findApps(in: build.appendingPathComponent("Products")).map(\.path) == expected)
        #expect(FolderScanner().findApps(in: tmp.path("DerivedData")).map(\.path) == expected)
    }

    @Test func stopDuringScanStopsDelivery() async throws {
        let tmp = try TempDir("watch-stop")
        let config = tmp.path("root/Debug-iphoneos")
        for n in ["A", "B", "C"] { try makeFakeApp(at: config.appendingPathComponent("\(n).app")) }
        let box = Box()
        let watcher = FolderWatcher(root: tmp.path("root"), options: .init(useFileEvents: false)) { url in
            let first = box.names.withLock { $0.append(url.lastPathComponent); return $0.count == 1 }
            if first, let w = box.watcher.withLock({ $0 }) { await w.stop() }
            return true
        }
        box.watcher.withLock { $0 = watcher }
        await watcher.start()
        #expect(box.names.withLock { $0 } == ["A.app"])
        #expect(await watcher.isRunning == false)

        // 다시 시작하면 넘기지 못한 빌드만 넘긴다.
        await watcher.start()
        #expect(box.names.withLock { $0 } == ["A.app", "B.app", "C.app"])
        await watcher.stop()
    }

    @Test func processedFingerprintsSurviveRestart() async throws {
        let tmp = try TempDir("watch-state")
        let root = tmp.path("root")
        let a = try makeFakeApp(at: root.appendingPathComponent("Debug-iphoneos/A.app"), payload: "aaa")
        try makeFakeApp(at: root.appendingPathComponent("Debug-iphoneos/B.app"), payload: "bbb")
        let stateFile = tmp.path("watched.json")
        let names = Mutex<[String]>([])
        let refuseB = Mutex(true)
        let handler: FolderWatcher.BuildHandler = { url in
            names.withLock { $0.append(url.lastPathComponent) }
            return !(url.lastPathComponent == "B.app" && refuseB.withLock { $0 })
        }

        let first = FolderWatcher(root: root, options: .init(useFileEvents: false), stateFile: stateFile, onBuild: handler)
        await first.start()
        await first.stop()
        #expect(names.withLock { $0 }.sorted() == ["A.app", "B.app"])

        // 다시 시작(앱 재실행): 처리한 A는 넘기지 않고, 처리하지 못한 B만 다시 넘긴다.
        refuseB.withLock { $0 = false }
        names.withLock { $0 = [] }
        let second = FolderWatcher(root: root, options: .init(useFileEvents: false), stateFile: stateFile, onBuild: handler)
        await second.start()
        #expect(names.withLock { $0 } == ["B.app"])
        await second.stop()

        names.withLock { $0 = [] }
        let third = FolderWatcher(root: root, options: .init(useFileEvents: false), stateFile: stateFile, onBuild: handler)
        await third.start()
        #expect(names.withLock { $0 }.isEmpty)
        try Data("aaaa-rebuilt".utf8).write(to: a.appendingPathComponent("App"))
        await third.rescan()
        #expect(names.withLock { $0 } == ["A.app"])
        await third.stop()
    }
}
