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
            fileSharing: .init(list: { shared.files }, share: { url in
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
