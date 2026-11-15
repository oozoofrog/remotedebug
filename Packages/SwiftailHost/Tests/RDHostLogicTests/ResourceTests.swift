import Foundation
import RDModels
import Testing
@testable import RDHostLogic

@Suite("공유 파일과 링크")
struct ResourceTests {
    @Test("게시 목록 사본 다운로드 범위와 게시 취소")
    func 게시목록다운로드() async throws {
        let fixture = try HostFixture()
        let request = try fixture.writeResource("설정 파일.json", #"{"a":1}"#)
        let id = try fixture.host.publishResource(request)
        #expect(id.hasPrefix("r_"))
        try Data("changed".utf8).write(to: URL(fileURLWithPath: request.path))
        let listResponse = await fixture.request("/v1/resources")
        #expect(listResponse.status == 200)
        let list: ResourcesResponse = try decode(listResponse)
        let descriptor = try #require(list.resources.first)
        #expect(list.resources.count == 1)
        #expect(descriptor.id == id && descriptor.name == "설정 파일.json" && descriptor.size == 7)
        #expect(descriptor.sha256 == request.resource.sha256)
        let file = await fixture.request("/v1/resources/" + id)
        #expect(file.status == 200)
        #expect(try responseData(file) == Data(#"{"a":1}"#.utf8))
        #expect(header(file, "Content-Type") == "application/octet-stream")
        #expect(header(file, "Content-Disposition")?.hasPrefix("attachment;") == true)
        let range = await fixture.request("GET", "/v1/resources/" + id, headers: [("range", "bytes=1-3")])
        #expect(range.status == 206)
        #expect(try responseData(range) == Data(#""a""#.utf8))
        try fixture.host.unpublishResource(id: id)
        let missing = await fixture.request("/v1/resources/" + id)
        #expect(try missing.status == 404 && (errorCode(missing)) == "resource_not_found")
        expectError("resource_not_found") { try fixture.host.unpublishResource(id: id) }
    }

    @Test("목록과 파일 모두 페어링 필요")
    func 인증() async throws {
        let fixture = try HostFixture(paired: false)
        let id = try fixture.host.publishResource(fixture.writeResource())
        for path in ["/v1/resources", "/v1/resources/" + id] {
            let response = await fixture.request(path)
            #expect(try response.status == 403 && (errorCode(response)) == "not_paired")
        }
    }

    @Test("해시 이름 경로와 중복 게시 검증")
    func 잘못된게시() throws {
        let fixture = try HostFixture()
        let good = try fixture.writeResource()
        var bad = good
        bad.resource.sha256 = String(repeating: "0", count: 64)
        expectError("hash_mismatch") { try fixture.host.publishResource(bad) }
        for name in ["", ".", "..", "a/b", "a\\b", "a:b", "a\nb", String(repeating: "x", count: 256)] {
            var changed = good
            changed.resource.name = name
            expectError("bad_request") { try fixture.host.publishResource(changed) }
        }
        let outside = try HostFixture()
        var changed = good
        changed.path = try outside.writeResource().path
        expectError("path_outside_publish_dir") { try fixture.host.publishResource(changed) }
        let id = try fixture.host.publishResource(good)
        #expect(try fixture.host.publishResource(good) == id)
        changed = good
        changed.resource.id = "r_wrong"
        expectError("bad_request") { try fixture.host.publishResource(changed) }
        changed = good
        changed.resource.size = (4 << 30) + 1
        expectError("bad_request") { try fixture.host.publishResource(changed) }
    }

    @Test("링크 해시와 다운로드 거부 및 다양한 스킴")
    func 링크() async throws {
        let fixture = try HostFixture()
        let link = "sampleapp://open/item?id=42&tab=detail"
        let resource = ResourceDescriptor(id: "", name: "상품 42 열기", size: 99, sha256: "", publishedAt: fixture.clock.now(), link: link)
        let id = try fixture.host.publishResource(.init(resource: resource, path: ""))
        let list: ResourcesResponse = try decode(await fixture.request("/v1/resources"))
        let got = try #require(list.resources.first)
        #expect(got.id == id && got.link == link && got.size == 0)
        #expect(got.sha256 == digest(Data(link.utf8)))
        #expect(await fixture.request("/v1/resources/" + id).status == 404)
        for value in ["", "no-scheme", "https://a\nb", String(repeating: "x", count: 9000)] {
            var bad = resource
            bad.link = value
            if value.isEmpty { expectError("path_outside_publish_dir") { try fixture.host.publishResource(.init(resource: bad, path: "")) } }
            else { expectError("bad_request") { try fixture.host.publishResource(.init(resource: bad, path: "")) } }
        }
        for value in ["maps://?q=%EC%84%9C%EC%9A%B8", "app-settings:", "sample:recipient"] {
            var good = resource
            good.link = value
            _ = try fixture.host.publishResource(.init(resource: good, path: ""))
        }
        try fixture.host.unpublishResource(id: id)
    }

    @Test("프로젝트 구역 변경과 이름 길이 경계")
    func 프로젝트() async throws {
        let fixture = try HostFixture()
        var request = try fixture.writeResource()
        request.resource.project = .init(id: "0a1b2c3d4e5f", name: "SampleApp")
        let id = try fixture.host.publishResource(request)
        func project() async throws -> ResourceProject? {
            let list: ResourcesResponse = try decode(await fixture.request("/v1/resources"))
            return list.resources.first?.project
        }
        #expect(try await project() == request.resource.project)
        request.resource.project = .init(id: "ffffffffffff", name: "다른 앱")
        #expect(try fixture.host.publishResource(request) == id)
        #expect(try await project()?.name == "다른 앱")
        request.resource.project = nil
        _ = try fixture.host.publishResource(request)
        #expect(try await project() == nil)
        let invalid: [ResourceProject] = [
            .init(id: "", name: "x"), .init(id: "abc", name: ""), .init(id: "a/b", name: "x"), .init(id: "a b", name: "x"),
            .init(id: "한글", name: "x"), .init(id: String(repeating: "a", count: 65), name: "x"),
            .init(id: "abc", name: "a\nb"), .init(id: "abc", name: String(repeating: "x", count: 256))
        ]
        for project in invalid {
            request.resource.project = project
            expectError("bad_request") { try fixture.host.publishResource(request) }
            request.resource.link = "https://example.com"
            expectError("bad_request") { try fixture.host.publishResource(request) }
            request.resource.link = nil
        }
        request.resource.project = .init(id: String(repeating: "a", count: 64), name: String(repeating: "x", count: 255))
        _ = try fixture.host.publishResource(request)
    }

    @Test("단일 범위 접미 범위와 조건부 응답")
    func 범위와조건() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publishResource(fixture.writeResource("a.bin", "0123456789"))
        for (range, expected, status) in [("bytes=0-2", "012", 206), ("bytes=7-", "789", 206), ("bytes=-2", "89", 206),
                                          ("bytes=8-99", "89", 206)] {
            let response = await fixture.request("GET", "/v1/resources/" + id, headers: [("range", range)])
            #expect(try response.status == status && (responseData(response)) == Data(expected.utf8))
        }
        let multipart = await fixture.request("GET", "/v1/resources/" + id, headers: [("range", "bytes=0-1,5-6")])
        #expect(multipart.status == 206)
        #expect(header(multipart, "Content-Type")?.hasPrefix("multipart/byteranges; boundary=") == true)
        let multipartText = String(decoding: try responseData(multipart), as: UTF8.self)
        #expect(multipartText.contains("Content-Range: bytes 0-1/10\r\n"))
        #expect(multipartText.contains("\r\n\r\n01\r\n") && multipartText.contains("\r\n\r\n56\r\n"))
        multipart.onFinished?(UInt64(multipartText.utf8.count), true)
        let excessive = await fixture.request("GET", "/v1/resources/" + id, headers: [("range", "bytes=0-9,0-9")])
        #expect(excessive.status == 200)
        excessive.onFinished?(20, true)
        for range in ["bytes=10-", "bytes=4-2", "items=0-1", "bytes=x-y", "bytes=0-9223372036854775808"] {
            let response = await fixture.request("GET", "/v1/resources/" + id, headers: [("range", range)])
            #expect(response.status == 416)
        }
        let full = await fixture.request("/v1/resources/" + id)
        let etag = try #require(header(full, "ETag"))
        #expect(await fixture.request("GET", "/v1/resources/" + id, headers: [("if-none-match", etag)]).status == 304)
        #expect(await fixture.request("GET", "/v1/resources/" + id, headers: [("if-match", "\"wrong\"")]).status == 412)
        #expect(await fixture.request("GET", "/v1/resources/" + id, headers: [("range", "bytes=0-1"), ("if-range", "\"wrong\"")]).status == 200)
        let head = await fixture.request("HEAD", "/v1/resources/" + id)
        #expect(head.status == 200 && header(head, "Accept-Ranges") == "bytes")
        #expect(header(head, "Content-Length") == nil)
    }

    @Test("파일 한도와 사본 경로 및 심볼릭 링크")
    func 한도와경로() throws {
        let fixture = try HostFixture()
        let other = try HostFixture()
        let outside = try other.writeResource()
        let link = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        var request = try fixture.writeResource()
        request.path = link.path
        expectError("path_outside_publish_dir") { try fixture.host.publishResource(request) }
        for index in 0..<500 {
            let descriptor = ResourceDescriptor(id: "", name: "link\(index)", size: 0, sha256: "", publishedAt: fixture.clock.now(), link: "sample:\(index)")
            _ = try fixture.host.publishResource(.init(resource: descriptor, path: ""))
        }
        request = try fixture.writeResource()
        expectError("bad_request") { try fixture.host.publishResource(request) }
        fixture.host.close()
        expectError("not_running") { try fixture.host.publishResource(request) }
    }
}
