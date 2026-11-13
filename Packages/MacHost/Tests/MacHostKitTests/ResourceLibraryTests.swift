import Foundation
import RDModels
import Testing
@testable import MacHostKit

@Suite struct ResourceLibraryTests {
    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func addPublishesWhileActiveAndReplacesSameName() async throws {
        let dir = try TempDir("files")
        let paths = HostPaths(root: dir.url.appendingPathComponent("state"))
        let core = FakeHostCore()
        let library = ResourceLibrary(paths: paths, host: core)
        try await library.load()

        // 공유 전에 넣은 파일은 저장만 하고, 공유를 시작할 때 게시한다.
        let first = try await library.add(write(#"{"v":1}"#, to: dir.url.appendingPathComponent("src/config.json")))
        #expect(first.name == "config.json")
        #expect(first.size == 7)
        #expect(first.id == ResourceDescriptor.makeID(name: "config.json", sha256: first.sha256))
        #expect(core.coreResources.isEmpty)
        #expect(await library.activate().isEmpty)
        #expect(Set(core.coreResources.keys) == [first.id])
        #expect(core.coreResources[first.id]?.path == paths.resourceURL(forID: first.id).path)

        // 같은 이름의 새 내용은 이전 파일을 바꾼다.
        let second = try await library.add(write(#"{"v":2}"#, to: dir.url.appendingPathComponent("src/config.json")))
        #expect(second.id != first.id)
        #expect(await library.resources.map(\.id) == [second.id])
        #expect(Set(core.coreResources.keys) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: paths.resourceURL(forID: first.id).path))

        // 다시 읽어도 목록이 남는다.
        let reloaded = ResourceLibrary(paths: paths, host: core)
        try await reloaded.load()
        #expect(await reloaded.resources == [second])

        try await library.remove(id: second.id)
        #expect(await library.resources.isEmpty)
        #expect(core.coreResources.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.resourceURL(forID: second.id).path))
    }

    @Test func rejectsFoldersAndCleansNames() async throws {
        let dir = try TempDir("files-reject")
        let library = ResourceLibrary(paths: HostPaths(root: dir.url.appendingPathComponent("state")), host: FakeHostCore())
        let folder = dir.url.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await #expect(throws: ResourceLibraryError.notAFile("folder")) { try await library.add(folder) }

        #expect(ResourceLibrary.safeName("a:b\u{7}.txt") == "a_b_.txt")
        #expect(ResourceLibrary.safeName("..") == "file")
        #expect(ResourceLibrary.safeName(String(repeating: "가", count: 100)).utf8.count <= 255)
    }

    @MainActor
    @Test func agentPushAndList() async throws {
        let tmp = try TempDir("files-agent")
        final class Box { var files: [ResourceDescriptor] = [] }
        let shared = Box()
        let sample = ResourceDescriptor(id: "r_00000001", name: "a.png", size: 3, sha256: String(repeating: "0", count: 64), publishedAt: Date())
        let model = ProjectsModel(
            root: tmp.url,
            fileSharing: .init(list: { shared.files }, share: { url, _ in
                guard url.lastPathComponent == "a.png" else { return .failure(ShareFileFailure("없음")) }
                shared.files = [sample]
                return .success(sample)
            }, remove: { id in shared.files.removeAll { $0.id == id } })
        ) { _ in nil }

        let pushed = await model.handleAgentRequest("push\n/tmp/a.png\n\n")
        #expect(pushed.ok)
        #expect(pushed.file == sample)
        #expect(await model.handleAgentRequest("files\n\n\n").files == [sample])
        #expect(await !model.handleAgentRequest("push\n/tmp/b.png\n\n").ok)
        #expect(await !model.handleAgentRequest("push\n\n\n").ok)
        #expect(await !model.handleAgentRequest("unpush\nr_nope\n\n").ok)
        #expect(await model.handleAgentRequest("unpush\nr_00000001\n\n").ok)
        #expect(shared.files.isEmpty)
    }
}

@Suite struct ResourceLinkTests {
    @Test func linksPublishWithoutFilesAndReplaceSameAddress() async throws {
        let dir = try TempDir("links")
        let paths = HostPaths(root: dir.url.appendingPathComponent("state"))
        let core = FakeHostCore()
        let library = ResourceLibrary(paths: paths, host: core)
        try await library.load()
        #expect(await library.activate().isEmpty)

        let link = try #require(URL(string: "sampleapp://open/item?id=42"))
        let first = try await library.addLink(link)
        #expect(first.link == link.absoluteString)
        #expect(first.size == 0)
        #expect(first.sha256 == ResourceDescriptor.linkHash(link.absoluteString))
        #expect(first.name == "open – item")
        #expect(core.coreResources[first.id]?.path == "")

        // 같은 주소에 이름을 붙여 다시 보내면 바뀐다.
        let renamed = try await library.addLink(link, title: "상품 42")
        #expect(renamed.name == "상품 42")
        #expect(await library.resources.map(\.id) == [renamed.id])
        #expect(Set(core.coreResources.keys) == [renamed.id])

        // 다시 읽어도 남는다(파일이 없어도).
        let reloaded = ResourceLibrary(paths: paths, host: core)
        try await reloaded.load()
        #expect(await reloaded.resources == [renamed])

        await #expect(throws: ResourceLibraryError.badLink("no-scheme")) { try await library.addLink(URL(string: "no-scheme")!) }
        try await library.remove(id: renamed.id)
        #expect(core.coreResources.isEmpty)
    }

    @Test func scriptKeepsIdsAndAddresses() {
        let script = AgentScript.text(agentDir: "/tmp/rd", bundleID: "com.example")
        #expect(script.contains("push|connect|schemes|build) case \"$path\""))
    }
}

@Suite struct ResourceAreaLibraryTests {
    private let app = ResourceProject(id: "0a1b2c3d4e5f", name: "SampleApp")
    private let other = ResourceProject(id: "ffffffffffff", name: "가계부")

    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func oldResourcesFileLoadsAsCommon() async throws {
        let dir = try TempDir("areas-old")
        let paths = HostPaths(root: dir.url.appendingPathComponent("state"))
        let sha = ResourceDescriptor.linkHash("https://example.com/docs")
        let fileSHA = String(repeating: "a", count: 64)
        let fileID = ResourceDescriptor.makeID(name: "config.json", sha256: fileSHA)
        // 구역이 생기기 전 버전이 쓴 파일.
        let old = """
        [
          {"id":"\(fileID)","name":"config.json","size":7,"sha256":"\(fileSHA)","publishedAt":"2026-11-12T01:00:00Z"},
          {"id":"\(ResourceDescriptor.makeID(name: "문서", sha256: sha))","name":"문서","size":0,"sha256":"\(sha)","publishedAt":"2026-11-11T01:00:00Z","link":"https://example.com/docs"}
        ]
        """
        _ = try write(old, to: paths.resourcesFile)
        _ = try write(#"{"v":1}"#, to: paths.resourceURL(forID: fileID))

        let core = FakeHostCore()
        let library = ResourceLibrary(paths: paths, host: core)
        try await library.load()
        #expect(await library.resources.map(\.name) == ["config.json", "문서"])
        #expect(await library.resources.allSatisfy { $0.project == nil })
        #expect(ResourceDescriptor.areas(await library.resources).map(\.title) == ["공통"])

        // 옮긴 뒤 다시 읽으면 구역이 남는다.
        try await library.move(id: fileID, to: app)
        let reloaded = ResourceLibrary(paths: paths, host: core)
        try await reloaded.load()
        #expect(await reloaded.resources.map(\.project) == [app, nil])
    }

    @Test func addIntoAreaMoveAndKeepAfterProjectIsGone() async throws {
        let dir = try TempDir("areas")
        let paths = HostPaths(root: dir.url.appendingPathComponent("state"))
        let core = FakeHostCore()
        let library = ResourceLibrary(paths: paths, host: core)
        try await library.load()
        #expect(await library.activate().isEmpty)

        let file = try await library.add(write("one", to: dir.url.appendingPathComponent("src/a.txt")), project: app)
        let link = try await library.addLink(#require(URL(string: "sampleapp://open")), title: "열기", project: app)
        let common = try await library.add(write("two", to: dir.url.appendingPathComponent("src/b.txt")))
        #expect(file.project == app && link.project == app && common.project == nil)
        #expect(core.coreResources[file.id]?.resource.project == app)
        #expect(core.coreResources[common.id]?.resource.project == nil)
        #expect(ResourceDescriptor.areas(await library.resources).map(\.title) == ["SampleApp", "공통"])

        // 옮겨도 id, 보낸 시각, 목록 순서는 그대로이고 코어의 설명이 바뀐다.
        let order = await library.resources.map(\.id)
        let moved = try await library.move(id: file.id, to: other)
        #expect(moved.id == file.id && moved.publishedAt == file.publishedAt && moved.project == other)
        #expect(await library.resources.map(\.id) == order)
        #expect(core.coreResources[file.id]?.resource.project == other)
        #expect(FileManager.default.fileExists(atPath: paths.resourceURL(forID: file.id).path))
        #expect(try await library.move(id: link.id, to: nil).project == nil)
        #expect(core.coreResources[link.id]?.resource.project == nil)
        await #expect(throws: ResourceLibraryError.missing) { try await library.move(id: "r_nope", to: nil) }

        // 같은 파일을 다른 구역으로 다시 보내면 그 구역으로 옮긴다.
        let again = try await library.add(write("one", to: dir.url.appendingPathComponent("src/a.txt")), project: app)
        #expect(again.id == file.id && again.project == app)
        #expect(await library.resources.count == 3)

        // 이름이 같은 새 내용은 구역이 달라도 이전 파일을 바꾼다(iPhone이 이름으로 저장한다).
        let replaced = try await library.add(write("three", to: dir.url.appendingPathComponent("src/a.txt")), project: other)
        #expect(await library.resources.filter { $0.name == "a.txt" } == [replaced])
        #expect(replaced.project == other)

        // 프로젝트 연결과 상관없이 구역 이름은 항목에 저장돼 남는다.
        let reloaded = ResourceLibrary(paths: paths, host: core)
        try await reloaded.load()
        #expect(ResourceDescriptor.areas(await reloaded.resources).map(\.title) == ["가계부", "공통"])
    }

    @Test func cleansProjectNamesTheCoreWouldReject() {
        #expect(ResourceLibrary.cleaned(ResourceProject(id: "abc", name: " My\nApp "))?.name == "MyApp")
        #expect(ResourceLibrary.cleaned(ResourceProject(id: "abc", name: String(repeating: "가", count: 200)))?.name.utf8.count ?? 0 <= 255)
        #expect(ResourceLibrary.cleaned(ResourceProject(id: "a/b", name: "x")) == nil)
        #expect(ResourceLibrary.cleaned(ResourceProject(id: "abc", name: "\n")) == nil)
        #expect(ResourceLibrary.cleaned(nil) == nil)
    }
}
