import Testing

@testable import SwiftailHostServer

@Suite("매니페스트와 경로")
struct ManifestAndRoutesTests {
    private let app = AppPackage(ipaPath: "/x/app.ipa", bundleIdentifier: "com.example.app", bundleVersion: "1.0 (2)",
                                 title: "Tom & \"Jerry\" <beta>")
    private let domain = "rd-mac-1a2b3c4d.tail0001.ts.net"

    @Test func manifestShapeAndEscaping() {
        let text = String(decoding: InstallManifest.render(ipaURL: "https://\(domain)/app.ipa", app: app), as: UTF8.self)
        #expect(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist"))
        #expect(text.contains("<key>kind</key><string>software-package</string>"))
        #expect(text.contains("<key>url</key><string>https://\(domain)/app.ipa</string>"))
        #expect(text.contains("<key>bundle-identifier</key><string>com.example.app</string>"))
        #expect(text.contains("<key>bundle-version</key><string>1.0 (2)</string>"))
        #expect(text.contains("<key>kind</key><string>software</string>"))
        #expect(text.contains("<key>title</key><string>Tom &amp; &quot;Jerry&quot; &lt;beta&gt;</string>"))
        #expect(!text.contains("<beta>"))
    }

    @Test func installURLEncodesManifestURL() {
        #expect(InstallManifest.installURL(manifestURL: "https://\(domain)/manifest.plist")
            == "itms-services://?action=download-manifest&url=https%3A%2F%2Frd-mac-1a2b3c4d.tail0001.ts.net%2Fmanifest.plist")
    }

    @Test func routesDependOnContent() {
        let empty = ServedContent()
        #expect(HostRouter.route(for: "/", content: empty) == .index)
        #expect(HostRouter.route(for: "/file", content: empty) == nil)
        #expect(HostRouter.route(for: "/manifest.plist", content: empty) == nil)
        #expect(HostRouter.route(for: "/app.ipa", content: empty) == nil)
        let full = ServedContent(filePath: "/x/file", app: app)
        #expect(Route.allCases.allSatisfy { HostRouter.route(for: $0.rawValue, content: full) == $0 })
    }

    @Test func indexLinksOnlyWhatIsServed() {
        let none = String(decoding: HostRouter.indexPage(content: ServedContent(), domain: domain), as: UTF8.self)
        #expect(!none.contains("itms-services") && !none.contains("href=\"/file\""))
        let page = String(decoding: HostRouter.indexPage(content: ServedContent(filePath: "/x", app: app), domain: domain), as: UTF8.self)
        #expect(page.contains("href=\"/file\""))
        #expect(page.contains("href=\"itms-services://?action=download-manifest&amp;url=https%3A%2F%2F"))
        #expect(page.contains("Tom &amp; &quot;Jerry&quot; &lt;beta&gt; 설치"))
    }

    @Test func manifestPlanUsesListenerDomain() {
        let content = ServedContent(app: app)
        let (route, plan) = HostRouter.plan(HTTPRequest(method: .get, path: "/manifest.plist"), content: content, domain: domain)
        #expect(route == .manifest)
        guard case .bytes(200, _, let body) = plan else {
            Issue.record("200 본문이 아님")
            return
        }
        #expect(String(decoding: body, as: UTF8.self).contains("https://\(domain)/app.ipa"))
        let (_, missing) = HostRouter.plan(HTTPRequest(method: .get, path: "/nope"), content: content, domain: domain)
        #expect(missing == .bytes(status: 404, headers: [], body: []))
    }

    @Test func responseHead() {
        let text = String(decoding: ResponseHead.serialize(status: 405, contentLength: 0, headers: []), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n"))
        #expect(text.contains("Allow: GET, HEAD\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }
}
