import CryptoKit
import Foundation
@testable import MacHostCore
@testable import MacHostKit
import RDBuildInspection
import RDHostLogic
import RDModels
import SwiftailHostServer
import Synchronization
import Testing

/// 실제 모델(`HostModel`) + 실제 코어(`SwiftailHostCore`) + 실제 호스트 로직과 HTTP 전송. tailnet만 가짜다: 노드 층이
/// 가짜 iPhone마다 루프백 평문 리스너를 하나씩 세우고, 그 리스너로 온 요청을 그 iPhone의 tailnet 신원으로 로직에 넘긴다.
/// Swiftail 노드·다리·TLS·인증서는 이 시험에 없다(그 부분은 SwiftailHost의 시험과 실기기 관문이 본다).
@MainActor
@Suite("MacHost E2E (루프백 tailnet)", .serialized)
struct HostE2ETests {
    static let fqdn = "rd-mac-e2e00001.tail0001.ts.net"
    static let phoneA = HostPeer(stableID: "nPHONEA", nodeName: "rd-phone-e2ea", loginName: "user@example.com")
    static let phoneB = HostPeer(stableID: "nPHONEB", nodeName: "rd-phone-e2eb", loginName: "other@example.com")

    @Test(.timeLimit(.minutes(2)))
    func pairInstallRevokeAndShutdown() async throws {
        let tmp = try E2ETempDir()
        let tailnet = LoopbackTailnet(fqdn: Self.fqdn, peers: [Self.phoneA, Self.phoneB])
        let core = SwiftailHostCore(layout: .init(), factory: tailnet.factory, pollIntervals: (.milliseconds(20), .milliseconds(50)))

        // 1. 공유 시작.
        let paths = HostPaths(root: tmp.path("host"))
        let model = HostModel(core: core, paths: paths, bookmarks: NoBookmarks(), watcherOptions: .init(useFileEvents: false),
                              id8: randomID8(), hostDisplayName: "E2E Mac", appVersion: "0.2.0")
        await model.start()
        #expect(model.lastError == nil, "\(model.lastError ?? "")")
        try await waitUntil("Running·tlsReady") {
            await model.refreshStatus()
            return model.status?.backendState == .running && model.status?.tlsReady == true
        }
        try await waitUntil("가짜 iPhone 리스너") { tailnet.client(for: Self.phoneA) != nil && tailnet.client(for: Self.phoneB) != nil }
        let a = try #require(tailnet.client(for: Self.phoneA))
        let b = try #require(tailnet.client(for: Self.phoneB))

        // 2. 디버그 빌드 가져오기 → 수락·게시. 비디버그 빌드는 거부된다.
        let accepted = try #require(await model.importBuild(E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos/AcceptedDev.app")))
        guard case .accepted(let build) = accepted else {
            Issue.record("AcceptedDev가 거부됐다: \(accepted)")
            return
        }
        let unsigned = await model.importBuild(E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos/Unsigned.app"))
        guard case .rejected = unsigned else {
            Issue.record("Unsigned가 거부되지 않았다")
            return
        }
        #expect(model.builds.map(\.id) == [build.id])

        // 3. 페어링하지 않은 노드: 403 not_paired, 활동에 거부가 남는다.
        let unpaired = try await a.get("/v1/builds")
        #expect(unpaired.status == 403 && unpaired.code == "not_paired")
        try await waitUntil("denied 이벤트") {
            model.activity.contains { if case .denied(let e) = $0.kind { e.reason == "not_paired" } else { false } }
        }

        // 4. 페어링: 코드 → 요청 이벤트 → 승인 → 허용 목록.
        await model.beginPairing()
        let code = try #require(model.pairingCode)
        let request = try await a.post("/v1/pair/request", ["code": code.code, "deviceName": "E2E iPhone"])
        #expect(request.status == 202, "\(request.text)")
        let requestID = try #require(request.json?["requestId"] as? String)
        try await waitUntil("pair-request 이벤트") { !model.pendingPairRequests.isEmpty }
        let pending = try #require(model.pendingPairRequests.first)
        #expect(pending.deviceName == "E2E iPhone" && pending.nodeName == "rd-phone-e2ea")
        #expect(model.devices.isEmpty)
        await model.approve(pending.requestId)
        let decided = try await a.get("/v1/pair/request/\(requestID)")
        #expect(decided.json?["state"] as? String == "approved", "\(decided.text)")
        let device = try #require(model.devices.first)
        #expect(device.nodeName == "rd-phone-e2ea" && device.nodeStableId == Self.phoneA.stableID)
        #expect(try JSONFile<DeviceList>(url: paths.devicesFile).load()?.devices.map(\.id) == [device.id])

        // 쓰인 코드는 다른 노드가 다시 쓸 수 없다.
        let reused = try await b.post("/v1/pair/request", ["code": code.code, "deviceName": "Other"])
        #expect(reused.status == 403 && reused.code == "pair_code_invalid", "\(reused.text)")

        // 4-1. 거부.
        await model.beginPairing()
        let denyCode = try #require(model.pairingCode)
        let denyRequest = try await b.post("/v1/pair/request", ["code": denyCode.code, "deviceName": "Intruder"])
        let denyID = try #require(denyRequest.json?["requestId"] as? String)
        try await waitUntil("두 번째 pair-request") { !model.pendingPairRequests.isEmpty }
        let denyPending = try #require(model.pendingPairRequests.first)
        await model.deny(denyPending.requestId)
        #expect(try await b.get("/v1/pair/request/\(denyID)").json?["state"] as? String == "denied")
        #expect(model.devices.map(\.id) == [device.id])
        #expect(try await b.get("/v1/builds").code == "not_paired")

        // 5. 등록된 노드: 수락된 빌드만 보인다.
        let listed = try await a.get("/v1/builds")
        #expect(((listed.json?["builds"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } == [build.id], "\(listed.text)")

        // 6. 설치 세션 → manifest → IPA(전송의 파일 응답). SHA-256이 같다.
        let session = try await a.post("/v1/builds/\(build.id)/sessions", [:])
        #expect(session.status == 201, "\(session.text)")
        let manifestText = try #require(session.json?["manifestUrl"] as? String)
        let manifestURL = try #require(URL(string: manifestText))
        #expect(manifestURL.host() == Self.fqdn && manifestURL.scheme == "https")
        let manifest = try await a.get(manifestURL.path())
        #expect(manifest.status == 200)
        let ipaText = try #require(Self.ipaURL(in: manifest.body))
        let ipaURL = try #require(URL(string: ipaText))
        let ipa = try await a.get(ipaURL.path())
        #expect(ipa.status == 200)
        #expect(SHA256.hash(data: ipa.body).map { String(format: "%02x", $0) }.joined() == build.descriptor.ipa.sha256)
        try await waitUntil("세션 완료 이벤트") {
            model.activity.contains { if case .session(let e) = $0.kind { e.state == .completed && e.buildId == build.id } else { false } }
        }

        // 7. 다른 노드는 첫 노드의 세션으로 받을 수 없다.
        let second = try await a.post("/v1/builds/\(build.id)/sessions", [:])
        let secondText = try #require(second.json?["manifestUrl"] as? String)
        let secondManifest = try #require(URL(string: secondText))
        let stolen = try await b.get(secondManifest.path())
        #expect(stolen.status == 403)

        // 8. 기기 제거 뒤에는 거부된다.
        await model.removeDevice(device.id)
        #expect(model.devices.isEmpty)
        #expect(try await a.get("/v1/builds").code == "not_paired")
        #expect(try await a.get(secondManifest.path()).status == 403)

        // 9. 종료: 노드 층이 멈추고 리스너가 닫힌다.
        await model.shutdown()
        #expect(!model.isRunning && model.status == nil)
        #expect(tailnet.runEnded)
        await #expect(throws: (any Error).self) { try await a.get("/v1/info") }
    }

    // MARK: 도우미

    static func ipaURL(in manifest: Data) -> String? {
        let text = String(decoding: manifest, as: UTF8.self)
        guard let start = text.range(of: "<key>url</key><string>")?.upperBound, let end = text[start...].range(of: "</string>") else {
            return nil
        }
        return String(text[start..<end.lowerBound])
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("기한 안에 일어나지 않음: \(what)")
        throw CancellationError()
    }
}

/// 가짜 tailnet: iPhone 신원마다 루프백 리스너 하나.
final class LoopbackTailnet: Sendable {
    let fqdn: String
    let peers: [HostPeer]
    private let ports = Mutex<[String: UInt16]>([:])
    private let ended = Mutex(false)

    init(fqdn: String, peers: [HostPeer]) { (self.fqdn, self.peers) = (fqdn, peers) }

    var runEnded: Bool { ended.withLock { $0 } }

    var factory: HostNodeFactory {
        HostNodeFactory(make: { [self] _, handler, _ in Layer(tailnet: self, handler: handler) }, logOut: { _ in })
    }

    func client(for peer: HostPeer) -> PeerClient? {
        ports.withLock { $0[peer.stableID] }.map(PeerClient.init(port:))
    }

    struct Layer: HostNodeLayer {
        let tailnet: LoopbackTailnet
        let handler: any HostRequestHandling

        func run() async throws {
            var listeners: [HTTPListener] = []
            for peer in tailnet.peers {
                let listener = try await HTTPListener.start(binding: .loopback(port: 0), security: .plaintext,
                                                            admission: .acceptAllForTesting(peer), handler: handler)
                listeners.append(listener)
                tailnet.ports.withLock { $0[peer.stableID] = listener.port }
            }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            for listener in listeners { listener.close() }
            tailnet.ended.withLock { $0 = true }
        }

        func snapshot() async -> NodeSnapshot {
            NodeSnapshot(state: .running, addresses: ["100.64.0.1"], fqdn: tailnet.fqdn, stableID: "nMACE2E",
                         certDomains: [tailnet.fqdn], peerCount: tailnet.peers.count)
        }

        func certificateSnapshot() async -> CertificateSnapshot? { CertificateSnapshot() }
        var serving: ServingState { ServingState(listening: true, tlsReady: !tailnet.runEnded) }
        func retryCertificates() async {}
    }
}

/// 가짜 iPhone 하나의 HTTP 클라이언트(그 iPhone의 루프백 리스너로 보낸다).
struct PeerClient: Sendable {
    let port: UInt16

    struct Reply: Sendable {
        var status: Int
        var body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
        var code: String? { (json?["error"] as? [String: Any])?["code"] as? String }
    }

    func get(_ path: String) async throws -> Reply { try await send("GET", path, body: nil) }

    func post(_ path: String, _ object: [String: String]) async throws -> Reply {
        try await send("POST", path, body: try JSONSerialization.data(withJSONObject: object))
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 10)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
