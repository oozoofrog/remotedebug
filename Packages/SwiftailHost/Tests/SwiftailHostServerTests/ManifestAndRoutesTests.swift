import RDHostLogic
import Swiftail
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
        #expect(StaticContentHandler.route(for: "/", content: empty) == .index)
        #expect(StaticContentHandler.route(for: "/file", content: empty) == nil)
        #expect(StaticContentHandler.route(for: "/manifest.plist", content: empty) == nil)
        #expect(StaticContentHandler.route(for: "/app.ipa", content: empty) == nil)
        let full = ServedContent(filePath: "/x/file", app: app)
        #expect(Route.allCases.allSatisfy { StaticContentHandler.route(for: $0.rawValue, content: full) == $0 })
    }

    @Test func indexLinksOnlyWhatIsServed() {
        let none = String(decoding: StaticContentHandler.indexPage(content: ServedContent(), domain: domain), as: UTF8.self)
        #expect(!none.contains("itms-services") && !none.contains("href=\"/file\""))
        let page = String(decoding: StaticContentHandler.indexPage(content: ServedContent(filePath: "/x", app: app), domain: domain), as: UTF8.self)
        #expect(page.contains("href=\"/file\""))
        #expect(page.contains("href=\"itms-services://?action=download-manifest&amp;url=https%3A%2F%2F"))
        #expect(page.contains("Tom &amp; &quot;Jerry&quot; &lt;beta&gt; 설치"))
    }

    @Test func manifestUsesListenerDomain() async {
        let content = ServedContent(app: AppPackage(ipaPath: "/x.ipa", bundleIdentifier: "com.example.app", bundleVersion: "1", title: "앱"))
        let handler = StaticContentHandler(content: content, domain: domain)
        let manifest = await handler.handle(HostRequest(method: "GET", target: "/manifest.plist", headers: [], body: nil,
                                                       contentLength: 0, origin: .direct(remoteIP: "127.0.0.1")))
        #expect(manifest.status == 200)
        guard case .bytes(let body) = manifest.body else { Issue.record("본문 없음"); return }
        #expect(String(decoding: body, as: UTF8.self).contains("https://\(domain)/app.ipa"))
        let missing = await handler.handle(HostRequest(method: "GET", target: "/nope", headers: [], body: nil, contentLength: 0,
                                                      origin: .direct(remoteIP: "127.0.0.1")))
        #expect(missing.status == 404)
        let post = await handler.handle(HostRequest(method: "POST", target: "/", headers: [], body: nil, contentLength: 0,
                                                   origin: .direct(remoteIP: "127.0.0.1")))
        #expect(post.status == 405 && post.headers.contains { $0.name == "Allow" })
    }

    /// 다리가 알려 준 신원 → 로직의 상대. 이름은 MagicDNS 이름의 첫 레이블, 없으면 표시용 이름.
    @Test func bridgeIdentityBecomesHostPeer() {
        let named = PeerIdentity(stableID: "nPHONE1", name: "rd-phone-1a2b3c4d.tail0001.ts.net.", computedName: "phone",
                                 loginName: "user@example.com")
        #expect(HTTPListener.peer(named) == HostPeer(stableID: "nPHONE1", nodeName: "rd-phone-1a2b3c4d", loginName: "user@example.com"))
        let unnamed = PeerIdentity(stableID: "nPHONE2", name: "", computedName: "phone", loginName: "")
        #expect(HTTPListener.peer(unnamed) == HostPeer(stableID: "nPHONE2", nodeName: "phone", loginName: ""))
        let dotOnly = PeerIdentity(stableID: "nPHONE3", name: ".tail0001.ts.net", computedName: "phone", loginName: "")
        #expect(HTTPListener.peer(dotOnly).nodeName == "phone")
    }
}
