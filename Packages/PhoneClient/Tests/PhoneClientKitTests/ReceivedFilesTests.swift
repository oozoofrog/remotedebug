import CryptoKit
import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

private func hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func resourcesJSON(name: String, body: String, sha: String? = nil) -> (String, String) {
    let sha = sha ?? hex(body)
    let id = ResourceDescriptor.makeID(name: name, sha256: sha)
    return (id, #"{"resources":[{"id":"\#(id)","name":"\#(name)","size":\#(body.utf8.count),"sha256":"\#(sha)","publishedAt":"2026-11-12T01:00:00Z"}]}"#)
}

@MainActor
@Suite struct ReceivedFilesTests {
    @Test func listsAndDownloadsFiles() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        let (id, list) = resourcesJSON(name: "설정.json", body: #"{"a":1}"#)
        h.transport.on("GET", "/v1/resources", .json(list))
        h.transport.on("GET", "/v1/resources/\(id)", Reply(status: 200, body: #"{"a":1}"#, headers: ["X-RD-Protocol": "1"]))
        await h.model.restore()
        await h.model.refresh()

        let resource = try #require(h.model.resources.first)
        #expect(resource.name == "설정.json")
        #expect(!h.model.isReceived(resource))

        var phases: [FileTransferUpdate.Phase] = []
        h.model.onFileTransfer = { phases.append($0.phase) }
        h.model.download(resource)
        #expect(h.model.fileDownloads[id] == .downloading)
        #expect(h.model.fileProgress[id]?.received == 0)
        #expect(h.model.fileProgress[id]?.total == 7)
        #expect(h.model.fileProgress[id]?.startedAt != nil)
        await h.model.waitForBackgroundWork()
        #expect(h.model.fileDownloads[id] == nil)
        #expect(h.model.fileProgress[id] == nil)
        #expect(phases.first == .receiving)
        #expect(phases.last == .received)
        #expect(h.model.isReceived(resource))
        let file = try #require(h.model.receivedFiles.first { $0.name == "설정.json" })
        #expect(try String(contentsOf: file.url, encoding: .utf8) == #"{"a":1}"#)

        h.model.deleteReceivedFile("설정.json")
        #expect(h.model.receivedFiles.isEmpty)
        #expect(!h.model.isReceived(resource))
    }

    @Test func rejectsMismatchedBytes() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        let (id, list) = resourcesJSON(name: "a.txt", body: "hello")
        h.transport.on("GET", "/v1/resources", .json(list))
        h.transport.on("GET", "/v1/resources/\(id)", Reply(status: 200, body: "jello", headers: ["X-RD-Protocol": "1"]))
        await h.model.restore()
        await h.model.refresh()

        h.model.download(try #require(h.model.resources.first))
        await h.model.waitForBackgroundWork()
        #expect(h.model.fileDownloads[id] == .failed(HostAPIError(status: 200, code: HostAPIError.fileMismatchCode, message: "").userMessage))
        #expect(h.model.receivedFiles.isEmpty)
    }

    @Test func olderMacWithoutFilesKeepsBuilds() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        await h.model.restore()
        await h.model.refresh()
        #expect(h.model.resources.isEmpty)
        #expect(h.model.lastError == nil)
        #expect(!h.model.builds.isEmpty)
    }
}

@MainActor
@Suite struct UpdatePageInfoTests {
    @Test func savesUpdatePageFromInfo() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        let info = Examples.info.replacingOccurrences(of: #""hostId": "h_4be0c7a1","#,
                                                      with: #""hostId": "h_4be0c7a1", "updatePage": "https://mac.example.ts.net/remotedebug-update-x/","#)
        h.transport.on("GET", "/v1/info", .json(info))
        h.transport.on("GET", "/v1/builds", .json(Examples.builds))
        await h.model.restore()
        await h.model.refresh()
        #expect(h.model.host?.updatePage?.absoluteString == "https://mac.example.ts.net/remotedebug-update-x/")
        #expect(h.store.load()?.updatePage == h.model.host?.updatePage)

        // Mac이 페이지를 닫으면 지운다. http 주소는 받지 않는다.
        h.transport.set("GET", "/v1/info", .json(Examples.info.replacingOccurrences(of: #""hostId": "h_4be0c7a1","#,
                                                                                      with: #""hostId": "h_4be0c7a1", "updatePage": "http://x/","#)))
        await h.model.refresh()
        #expect(h.model.host?.updatePage == nil)
    }
}

@MainActor
@Suite struct LinkResourceTests {
    @Test func listsLinksAndNeverDownloadsThem() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        let link = "sampleapp://open/item?id=42"
        let sha = ResourceDescriptor.linkHash(link)
        let id = ResourceDescriptor.makeID(name: "상품 42", sha256: sha)
        h.transport.on("GET", "/v1/resources", .json(#"{"resources":[{"id":"\#(id)","name":"상품 42","size":0,"sha256":"\#(sha)","publishedAt":"2026-11-12T01:00:00Z","link":"\#(link)"}]}"#))
        await h.model.restore()
        await h.model.refresh()
        let resource = try #require(h.model.resources.first)
        #expect(resource.isLink)
        #expect(resource.link == link)
        h.model.download(resource)
        #expect(h.model.fileDownloads[id] == nil)
        #expect(h.transport.count("GET", "/v1/resources/\(id)") == 0)
    }
}

@MainActor
@Suite struct ResourceAreaClientTests {
    @Test func keepsProjectAreasFromTheMacList() async throws {
        let h = Harness(storedHost: Harness.pairedHost)
        h.serveHostInfoAndBuilds()
        let sha = String(repeating: "a", count: 64)
        let inArea = ResourceDescriptor.makeID(name: "config.json", sha256: sha)
        let common = ResourceDescriptor.makeID(name: "notes.txt", sha256: sha)
        h.transport.on("GET", "/v1/resources", .json(#"""
        {"resources":[
          {"id":"\#(inArea)","name":"config.json","size":7,"sha256":"\#(sha)","publishedAt":"2026-11-12T02:00:00Z","project":{"id":"0a1b2c3d4e5f","name":"SampleApp"}},
          {"id":"\#(common)","name":"notes.txt","size":3,"sha256":"\#(sha)","publishedAt":"2026-11-12T01:00:00Z"}
        ]}
        """#))
        await h.model.restore()
        await h.model.refresh()
        #expect(h.model.resources.map(\.project?.name) == ["SampleApp", nil])
        let areas = ResourceDescriptor.areas(h.model.resources)
        #expect(areas.map(\.title) == ["SampleApp", "공통"])
        #expect(areas.map { $0.resources.map(\.id) } == [[inArea], [common]])

        // Mac에서 구역만 옮겨도(id는 그대로) 새 목록을 쓴다.
        h.transport.set("GET", "/v1/resources", .json(#"{"resources":[{"id":"\#(inArea)","name":"config.json","size":7,"sha256":"\#(sha)","publishedAt":"2026-11-12T02:00:00Z"},{"id":"\#(common)","name":"notes.txt","size":3,"sha256":"\#(sha)","publishedAt":"2026-11-12T01:00:00Z"}]}"#))
        await h.model.refresh()
        #expect(ResourceDescriptor.areas(h.model.resources).map(\.project) == [nil])
    }
}
