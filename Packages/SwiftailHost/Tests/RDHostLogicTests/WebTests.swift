import Foundation
import RDModels
import Testing
@testable import RDHostLogic

func matches(_ pattern: String, _ text: String) throws -> [[String]] {
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
        (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
func replacing(_ pattern: String, in text: String, with replacement: String = "") throws -> String {
    try NSRegularExpression(pattern: pattern).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
}
func javascriptStrings(_ text: String) throws -> [(String, Bool)] {
    let bytes = Array(text.utf8)
    var position = 0, result: [(String, Bool)] = []
    while position < bytes.count {
        if bytes[position...].starts(with: [47, 47]) {
            while position < bytes.count && bytes[position] != 10 { position += 1 }
        } else if bytes[position...].starts(with: [47, 42]) {
            position += 2
            while position + 1 < bytes.count && !bytes[position...].starts(with: [42, 47]) { position += 1 }
            guard position + 1 < bytes.count else { throw HostErrors.make("bad_request", "주석 종료 없음") }
            position += 2
        } else if [34, 39, 96].contains(bytes[position]) {
            let start = position, quote = bytes[position]
            position += 1
            while position < bytes.count && bytes[position] != quote {
                if bytes[position] == 92 { position += 1 }
                position += 1
            }
            guard position < bytes.count else { throw HostErrors.make("bad_request", "문자열 종료 없음") }
            position += 1
            if quote == 34 {
                let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<position]), options: [.fragmentsAllowed]) as? String
                let prefix = String(decoding: bytes[..<start], as: UTF8.self)
                result.append((try #require(value), !(try matches(#"\bt\(\s*$"#, prefix)).isEmpty))
            }
        } else { position += 1 }
    }
    return result
}

@Suite("설치 웹 페이지")
struct WebTests {
    let routes = [("/", "index.html", "text/html; charset=utf-8"), ("/assets/install.css", "install.css", "text/css; charset=utf-8"),
                  ("/assets/install.js", "install.js", "text/javascript; charset=utf-8"), ("/assets/logic.js", "logic.js", "text/javascript; charset=utf-8")]
    func texts(_ fixture: HostFixture) async throws -> [String: String] {
        var result: [String: String] = [:]
        for (path, _, _) in routes { result[path] = String(decoding: try responseData(await fixture.request(path)), as: UTF8.self) }
        return result
    }
    func checkHeaders(_ response: HostResponse) {
        for (name, value) in [
            ("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
            ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"), ("Cache-Control", "no-store"), ("X-Frame-Options", "DENY"), ("X-RD-Protocol", "1")
        ] {
            #expect(header(response, name) == value)
            #expect(response.headers.filter { $0.name.lowercased() == name.lowercased() }.count == 1)
        }
        #expect(header(response, "Set-Cookie") == nil)
    }

    @Test("정확한 경로와 쿼리 HEAD 및 메서드 응답")
    func 경로와머리() async throws {
        let fixture = try HostFixture(paired: false)
        let originalHashes = [
            "index.html": "2270658592d617dc6a7deeebc46583b8a1a7829630957105ebd40325366f5bea",
            "install.css": "3b98a74fffdb3fe728b3bc3e6d1e952b88a1e4007d29b14ec6e24675cb352b42",
            "install.js": "d4a26ba1ed81d308f39b6cf3ac739fcc19a43e447c87113fcbc9acd8aa1f3ee5",
            "logic.js": "b080f4d9c05d4f8c5b9bb0fb9ba0ff8ab4905643b1b2eb92ed24744bef21ad9a"
        ]
        let source = HostLogic.resourceRoot.appendingPathComponent("web")
        for (path, file, type) in routes {
            let expected = try Data(contentsOf: source.appendingPathComponent(file))
            #expect(digest(expected) == originalHashes[file])
            for target in [path, path + "?x=1"] {
                let response = await fixture.request(target)
                #expect(response.status == 200 && header(response, "Content-Type") == type)
                #expect(try responseData(response) == expected)
                #expect(header(response, "Content-Length") == nil)
                checkHeaders(response)
            }
            let head = await fixture.request("HEAD", path)
            #expect(head.status == 200 && header(head, "Content-Type") == type)
            // 접점은 GET과 같은 본문을 돌려주고 전송이 HEAD 본문을 생략한다.
            #expect(try responseData(head) == expected)
            checkHeaders(head)
            for method in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"] {
                let response = await fixture.request(method, path)
                #expect(try response.status == 405 && errorCode(response) == "method_not_allowed")
                #expect(header(response, "Allow") == "GET, HEAD")
                #expect(header(response, "Content-Type") == "application/json")
                checkHeaders(response)
            }
        }
    }

    @Test("리소스는 비어 있지 않고 인라인 코드나 외부 참조 없음")
    func 리소스내용() async throws {
        let pages = try await texts(HostFixture(paired: false))
        #expect(pages.count == 4)
        for text in pages.values { #expect(text.utf8.count >= 200) }
        let html = try #require(pages["/"])
        for wanted in [#"lang="ko""#, #"name="viewport""#, #"src="/assets/logic.js""#, #"src="/assets/install.js""#, #"href="/assets/install.css""#] { #expect(html.contains(wanted)) }
        for bad in ["<script>", "<style", " style=", "onclick=", "onload=", "javascript:", "http://", "https://"] { #expect(!html.contains(bad)) }
        for path in ["/assets/install.js", "/assets/logic.js"] {
            let script = try #require(pages[path])
            for bad in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function", "document.cookie", "http://", "https://"] { #expect(!script.contains(bad)) }
        }
    }

    @Test("정규화와 인코딩 변형은 페이지를 반환하지 않음")
    func 다른경로() async throws {
        let fixture = try HostFixture(paired: false)
        let targets = ["/foo", "/index.html", "/assets", "/assets/", "/assets/install.js/", "/assets/other.js", "/assets/../x",
                       "/assets/../assets/install.js", "/assets/./install.js", "/./", "/.", "/assets/%2e%2e/assets/install.js", "/assets/%2E%2E/x",
                       "/%2e%2e/", "/assets/install%2Ejs", "/assets%2Finstall.js", "/%61ssets/install.js", "/ASSETS/install.js", "/assets/INSTALL.JS",
                       "/web/index.html", "/web/logic.js", "/assets/web/logic.js", "//", "//assets/install.js", #"/assets\install.js"#, #"\"#, #"/assets/..\install.js"#]
        for target in targets {
            let response = await fixture.request(target)
            #expect(try response.status == 404 && errorCode(response) == "not_found")
            #expect(header(response, "Content-Security-Policy") == nil)
            #expect(try !String(decoding: responseData(response), as: UTF8.self).contains("<html"))
        }
    }

    @Test("페이지 요청은 거부 사건과 제한 횟수를 쓰지 않음")
    func 사건없음() async throws {
        let fixture = try HostFixture(paired: false)
        for _ in 0..<3 {
            for (path, _, _) in routes {
                for method in ["GET", "HEAD", "POST"] { _ = await fixture.request(method, path) }
            }
        }
        #expect(fixture.drain().isEmpty)
        #expect(fixture.host.locked { fixture.host.denials.isEmpty })
        #expect(await fixture.request("/v1/builds").status == 403)
        guard case .denied(let event) = fixture.events.next() else { Issue.record("거부 사건 없음"); return }
        #expect(event.path == "/v1/builds" && event.suppressed == nil)
    }

    @Test("기존 API 경로의 인증과 메서드 오류 유지")
    func 기존경로() async throws {
        let fixture = try HostFixture(paired: false)
        let cases: [(String, String, Int, String)] = [
            ("GET", "/v1/info", 403, "not_paired"), ("HEAD", "/v1/info", 403, "not_paired"), ("GET", "/v1/builds", 403, "not_paired"),
            ("POST", "/v1/builds/b_00000000/sessions", 403, "not_paired"), ("GET", "/v1/sessions/s_00000000", 403, "not_paired"),
            ("GET", "/v1/pair/request/pr_00000000", 403, "not_paired"), ("POST", "/v1/pair/request", 400, "bad_request"),
            ("GET", "/i/TOKEN/manifest.plist", 403, "not_paired"), ("GET", "/i/TOKEN/app.ipa", 403, "not_paired"),
            ("POST", "/v1/info", 405, "method_not_allowed"), ("DELETE", "/v1/builds", 405, "method_not_allowed"),
            ("GET", "/v1/pair/request", 405, "method_not_allowed"), ("GET", "/nope", 404, "not_found"), ("GET", "/v1", 404, "not_found"),
            ("GET", "/v1/", 404, "not_found"), ("GET", "/i/", 404, "not_found"), ("GET", "/v1/devices/self/push-token", 404, "not_found")
        ]
        for (method, path, status, code) in cases {
            let response = await fixture.request(method, path)
            #expect(try response.status == status && errorCode(response) == code)
            #expect(header(response, "X-RD-Protocol") == "1")
            #expect(header(response, "Content-Security-Policy") == nil && header(response, "Allow") == nil)
        }
    }

    @Test("스크립트 순서 요소 id와 초점 대상 연결")
    func 페이지연결() async throws {
        let pages = try await texts(HostFixture(paired: false))
        let html = try #require(pages["/"]), script = try #require(pages["/assets/install.js"])
        let logic = try #require(html.range(of: #"<script src="/assets/logic.js" defer></script>"#))
        let install = try #require(html.range(of: #"<script src="/assets/install.js" defer></script>"#))
        #expect(logic.lowerBound < install.lowerBound)
        #expect(html.components(separatedBy: "<script").count - 1 == 2)
        var ids = Set(try matches(#"\$\("([a-z0-9-]+)"\)"#, script).map { $0[1] })
        let views = try #require(try matches(#"var views = \[([^\]]*)\]"#, script).first?[1])
        for view in try matches(#""([a-z]+)""#, views) { ids.insert("view-" + view[1]) }
        #expect(ids.count >= 20)
        for id in ids { #expect(html.components(separatedBy: "id=\"" + id + "\"").count - 1 == 1) }
        let headings = try matches("<h2 [^>]*>", html)
        #expect(headings.count == 5)
        for heading in headings { #expect(heading[0].contains(#"tabindex="-1""#)) }
        for id in ["notice", "refresh-error"] {
            let tag = try #require(try matches("<[a-z0-9]+ [^>]*id=\"" + id + "\"[^>]*>", html).first?[0])
            #expect(tag.contains(#"tabindex="-1""#) && !tag.contains("aria-live") && !tag.contains("role="))
        }
    }

    @Test("네 언어의 문자열 슬롯과 자리표시자는 원문과 일치")
    func 번역완전성() async throws {
        let pages = try await texts(HostFixture(paired: false))
        let html = try #require(pages["/"]), logic = try #require(pages["/assets/logic.js"])
        let block = try #require(try matches(#"(?s)RD-STRINGS-BEGIN[^\n]*\n(.*?)\n[^\n]*RD-STRINGS-END"#, logic).first?[1])
        let start = try #require(block.firstIndex(of: "{")), end = try #require(block.lastIndex(of: "}"))
        let table = try JSONDecoder().decode([String: [String: String]].self, from: Data(block[start...end].utf8))
        #expect(Set(table.keys) == Set(["en", "ja", "zh-Hans", "zh-Hant"]))
        let visibleHTML = try replacing("(?s)<noscript>.*?</noscript>", in: html)
        func hasKorean(_ text: String) throws -> Bool { try !matches("[가-힣]", text).isEmpty }
        var keys: Set<String> = []
        for match in try matches(">([^<]*)<", visibleHTML) {
            let value = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if try hasKorean(value) { keys.insert(value) }
        }
        for match in try matches(#"\s([a-z-]+)="([^"]*)""#, visibleHTML) where try hasKorean(match[2]) {
            #expect(["aria-label", "placeholder", "title", "alt"].contains(match[1]))
            keys.insert(match[2].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for path in ["/assets/logic.js", "/assets/install.js"] {
            var script = try #require(pages[path])
            if path == "/assets/logic.js" { script = try replacing("(?s)// RD-STRINGS-BEGIN.*?// RD-STRINGS-END", in: script) }
            for (literal, translated) in try javascriptStrings(script) {
                if try translated || hasKorean(literal) { keys.insert(literal) }
            }
        }
        #expect(keys.count >= 50)
        var filled = 0
        func placeholders(_ text: String) throws -> [String] { try matches(#"\{([A-Za-z0-9_]+)\}"#, text).map { $0[1] }.sorted() }
        for slots in table.values {
            #expect(Set(slots.keys) == keys)
            for (key, value) in slots where !value.isEmpty {
                filled += 1
                #expect(try placeholders(value) == placeholders(key))
            }
        }
        #expect(filled > 0)
        for wanted in [#"<html lang="ko">"#, "<title>RemoteDebug 빌드 설치</title>", "페어링 요청", "남은 시간"] { #expect(html.contains(wanted)) }
    }
    @Test("API 경로 정규화와 리다이렉트 문자열 처리")
    func 경로정규화() async throws {
        let fixture = try HostFixture()
        let response = await fixture.request("/v1/../v1/info?x=<value>&y=1")
        #expect(response.status == 301)
        #expect(header(response, "Location") == "/v1/info?x=<value>&y=1")
        let body = String(decoding: try responseData(response), as: UTF8.self)
        #expect(body.contains("x=&lt;value&gt;&amp;y=1"))
        #expect(await fixture.request("/v1/%69nfo").status == 200)
    }

}
