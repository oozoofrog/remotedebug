import Foundation
import RDModels
import Synchronization
import Testing
@testable import MacHostKit

private final class FakePageServer: UpdatePageServing {
    let configs = Mutex<[UpdatePageConfig]>([])
    func apply(_ config: UpdatePageConfig) async throws -> String {
        configs.withLock { $0.append(config) }
        return config.listen.hasSuffix(":0") ? "127.0.0.1:50123" : config.listen
    }
    var last: UpdatePageConfig? { configs.withLock { $0.last } }
}

private final class FakeTailscale: TailscaleControlling {
    struct State {
        var installed = true
        var backend = "Running"
        var routes: [String: String] = [:]
        var calls: [[String]] = []
    }
    let state = Mutex(State())

    func run(_ arguments: [String]) async -> (status: Int32, output: String)? {
        state.withLock { s in
            s.calls.append(arguments)
            guard s.installed else { return nil }
            switch Array(arguments.prefix(2)) {
            case ["status", "--json"]:
                return (0, #"{"BackendState":"\#(s.backend)","Self":{"DNSName":"mac.example.ts.net."}}"#)
            case ["serve", "status"]:
                let handlers = s.routes.map { #""\#($0.key)":{"Proxy":"\#($0.value)"}"# }.joined(separator: ",")
                return (0, #"{"Web":{"mac.example.ts.net:443":{"Handlers":{\#(handlers)}}}}"#)
            default:
                guard arguments.first == "serve", let i = arguments.firstIndex(of: "--set-path") else { return (1, "bad") }
                let path = arguments[i + 1], target = arguments[i + 2]
                if target == "off" { s.routes[path] = nil } else { s.routes[path] = target }
                return (0, "")
            }
        }
    }
}

@MainActor
@Suite struct UpdatePageTests {
    private func build(_ id: String, bundle: String = "com.oozoofrog.app.RemoteDebugPhone", at seconds: TimeInterval) -> LibraryBuild {
        var d = sampleDescriptor(bundleId: bundle, now: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        d.id = id
        return LibraryBuild(descriptor: d, sourcePath: "/x")
    }

    @Test func servesNewestPhoneBuildOnceRouted() async throws {
        let dir = try TempDir("update-page")
        let server = FakePageServer()
        let cli = FakeTailscale()
        let page = UpdatePageModel(root: dir.url, server: server, cli: cli)
        await page.start()
        let path = try #require(page.routePath)
        #expect(path.hasPrefix("/remotedebug-update-"))
        #expect(page.tailscale == .connected(dnsName: "mac.example.ts.net"))
        #expect(!page.isRouted)
        #expect(page.pageURL == nil)
        #expect(server.last?.listen == "127.0.0.1:50123")

        await page.sync(builds: [build("b_old", at: 0), build("b_new", at: 60), build("b_other", bundle: "com.example.other", at: 120)]) {
            URL(fileURLWithPath: "/published/\($0).ipa")
        }
        #expect(page.servedBuild?.id == "b_new")
        #expect(server.last?.page?.ipaPath == "/published/b_new.ipa")
        #expect(server.last?.publicURL == "")

        await page.enable()
        #expect(cli.state.withLock { $0.routes[path] } == "http://127.0.0.1:50123")
        #expect(page.isRouted)
        #expect(page.pageURL?.absoluteString == "https://mac.example.ts.net\(path)/")
        #expect(server.last?.publicURL == "https://mac.example.ts.net\(path)/")

        // 다시 열어도 같은 경로·포트를 쓴다.
        let reopened = UpdatePageModel(root: dir.url, server: server, cli: cli)
        await reopened.start()
        #expect(reopened.routePath == path)
        #expect(reopened.isRouted)
        #expect(server.last?.listen == "127.0.0.1:50123")

        await page.disable()
        #expect(!page.isRouted)
        #expect(page.pageURL == nil)
    }

    @Test func reportsMissingAndDisconnectedTailscale() async throws {
        let dir = try TempDir("update-page-missing")
        let cli = FakeTailscale()
        cli.state.withLock { $0.installed = false }
        let page = UpdatePageModel(root: dir.url, server: FakePageServer(), cli: cli)
        await page.start()
        #expect(page.tailscale == .missing)

        cli.state.withLock { $0.installed = true; $0.backend = "Stopped" }
        await page.refresh()
        #expect(page.tailscale == .notConnected("Stopped"))
        #expect(page.pageURL == nil)
    }
}
