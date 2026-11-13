import Foundation
import Testing

@testable import RDModels

@Suite struct ResourceAreaTests {
    private let app = ResourceProject(id: "0a1b2c3d4e5f", name: "SampleApp")
    private let tool = ResourceProject(id: "ffffffffffff", name: "budget")

    private func resource(_ name: String, at seconds: TimeInterval, link: String? = nil, project: ResourceProject? = nil) -> ResourceDescriptor {
        ResourceDescriptor(id: ResourceDescriptor.makeID(name: name, sha256: "00"), name: name, size: link == nil ? 3 : 0, sha256: "00",
                           publishedAt: Date(timeIntervalSince1970: 1_790_000_000 + seconds), link: link, project: project)
    }

    @Test func projectRoundTripsAndOldShapeStaysTheSame() throws {
        let inArea = resource("config.json", at: 0, project: app)
        let encoded = try RDJSON.encoder().encode(inArea)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["project"] as? [String: String] == ["id": "0a1b2c3d4e5f", "name": "SampleApp"])
        #expect(try RDJSON.decoder().decode(ResourceDescriptor.self, from: encoded) == inArea)

        // 구역이 없으면 키를 쓰지 않는다(이전 앱이 보던 모양 그대로).
        let common = resource("config.json", at: 0)
        let commonObject = try #require(JSONSerialization.jsonObject(with: RDJSON.encoder().encode(common)) as? [String: Any])
        #expect(commonObject["project"] == nil)

        // 이전 Mac 앱이 보낸 목록(필드 없음)은 공통이다.
        let old = Data(#"{"resources":[{"id":"r_1a2b3c4d","name":"config.json","size":7,"sha256":"ab","publishedAt":"2026-11-12T01:00:00Z"}]}"#.utf8)
        #expect(try RDJSON.decoder().decode(ResourcesResponse.self, from: old).resources.first?.project == nil)
    }

    @Test func malformedProjectFallsBackToCommon() throws {
        for project in [#"null"#, #""SampleApp""#, #"{"id":"","name":"x"}"#, #"{"id":"abc"}"#, #"{"id":"a/b","name":"x"}"#, #"{"id":"abc","name":"a\nb"}"#] {
            let json = Data(#"{"id":"r_1a2b3c4d","name":"a.txt","size":1,"sha256":"ab","publishedAt":"2026-11-12T01:00:00Z","project":\#(project)}"#.utf8)
            let decoded = try RDJSON.decoder().decode(ResourceDescriptor.self, from: json)
            #expect(decoded.project == nil, "\(project)")
            #expect(decoded.name == "a.txt")
        }
    }

    @Test func projectIDHidesTheFolderPath() {
        let folder = URL(fileURLWithPath: "/Users/example/Projects/SampleApp")
        let project = ResourceProject(name: "SampleApp", folder: folder)
        #expect(project.id.count == 12)
        #expect(project.id.allSatisfy { $0.isHexDigit })
        #expect(project.isValid)
        #expect(project == ResourceProject(name: "SampleApp", folder: URL(fileURLWithPath: "/Users/example/Projects/Other/../SampleApp")))
        #expect(project.id != ResourceProject(name: "SampleApp", folder: URL(fileURLWithPath: "/Users/example/Projects/Other")).id)
        let encoded = String(decoding: (try? RDJSON.encoder().encode(project)) ?? Data(), as: UTF8.self)
        #expect(!encoded.contains("example") && !encoded.contains("Projects"))

        #expect(!ResourceProject(id: String(repeating: "a", count: 65), name: "x").isValid)
        #expect(!ResourceProject(id: "abc", name: String(repeating: "x", count: 256)).isValid)
        #expect(ResourceProject(id: String(repeating: "a", count: 64), name: String(repeating: "x", count: 255)).isValid)
    }

    @Test func areasPutProjectsByNameThenCommonAndKeepOrderInside() {
        let list = [
            resource("d.txt", at: 40),
            resource("c.txt", at: 30, project: tool),
            resource("문서", at: 20, link: "https://example.com/docs", project: app),
            resource("b.txt", at: 10, project: tool),
            resource("a.txt", at: 0, project: app),
        ]
        let areas = ResourceDescriptor.areas(list)
        // 이름순은 대소문자를 가리지 않는다.
        #expect(areas.map(\.title) == ["budget", "SampleApp", "공통"])
        #expect(areas.map { $0.resources.map(\.name) } == [["c.txt", "b.txt"], ["문서", "a.txt"], ["d.txt"]])
        #expect(Set(areas.map(\.id)).count == 3)

        // 공통만 있으면 구역 하나, 프로젝트만 있으면 공통 구역이 없다.
        #expect(ResourceDescriptor.areas([list[0]]).map(\.project) == [nil])
        #expect(ResourceDescriptor.areas([list[1]]).map(\.title) == ["budget"])
        #expect(ResourceDescriptor.areas([]).isEmpty)
    }

    @Test func sameProjectIDUsesTheNewestName() {
        let renamed = ResourceProject(id: app.id, name: "SampleApp 2")
        let areas = ResourceDescriptor.areas([resource("old.txt", at: 0, project: app), resource("new.txt", at: 10, project: renamed)])
        #expect(areas.count == 1)
        #expect(areas.first?.title == "SampleApp 2")
        #expect(areas.first?.resources.map(\.name) == ["old.txt", "new.txt"])
    }
}
