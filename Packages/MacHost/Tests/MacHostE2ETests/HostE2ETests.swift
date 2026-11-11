import Foundation
import MacHostCore
@testable import MacHostKit
import RDBuildInspection
import RDModels
import Testing

/// 실제 Go 코어(`RDCoreHost`) + 가짜 tailnet(`rdtestenv control`) + 가짜 iPhone 노드(`rdtestenv peer`).
/// `RDTESTENV_BIN`이 없으면 건너뛴다(scripts/e2e-mac.sh가 설정한다).
@MainActor
@Suite("MacHost E2E", .serialized, .enabled(if: E2EEnv.isEnabled))
struct HostE2ETests {
    /// 테일넷 안 호스트 리스너 포트(노드마다 따로인 netstack 포트라 Mac의 포트와 겹치지 않는다).
    static let port = 8080

    @Test(.timeLimit(.minutes(10)))
    func pairInstallRevokeAndShutdown() async throws {
        let bin = try #require(E2EEnv.rdtestenv)
        let tmp = try E2ETempDir()
        let control = try await FakeControl(binary: bin)
        defer { control.stop() }

        // 1. 실제 코어로 공유 시작(루프백 제어 서버 → listenTLS=false).
        let paths = HostPaths(root: tmp.path("host"))
        let model = HostModel(core: RDCoreHost(), paths: paths, bookmarks: NoBookmarks(),
                              watcherOptions: .init(useFileEvents: false), id8: randomID8(),
                              hostDisplayName: "E2E Mac", appVersion: "0.1.0", port: Self.port)
        model.controlURL = control.url
        #expect(model.makeConfigForTest().listenTLS == false)
        await model.start()
        #expect(model.lastError == nil, "\(model.lastError ?? "")")
        #expect(model.isRunning)
        try await waitUntil("호스트가 Running·listening이 된다", timeout: .seconds(60)) {
            await model.refreshStatus()
            return model.status?.backendState == .running && model.status?.listening == true
        }
        let status = try #require(model.status)
        #expect(status.fqdn.hasPrefix(model.nodeName + "."))
        let base = "http://\(status.fqdn):\(Self.port)"
        #expect(model.installPageURL?.absoluteString == base + "/", "설치 페이지 주소는 코어 리스너와 같은 스킴·포트")

        // 2. 디버그 빌드 가져오기 → 수락·게시. 비디버그 빌드는 거부되고 목록에 없다.
        let accepted = try #require(await model.importBuild(E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos/AcceptedDev.app")))
        guard case .accepted(let build) = accepted else {
            Issue.record("AcceptedDev가 거부됐다: \(accepted)")
            return
        }
        let releaseCopy = tmp.path("Release-iphoneos/AcceptedDev.app")
        try FileManager.default.createDirectory(at: releaseCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos/AcceptedDev.app"), to: releaseCopy)
        let nonDebug: [(URL, RejectionCode)] = [
            (releaseCopy, .configurationNotDebug),
            (E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos/AdHocDist.app"), .notDevelopmentProfile),
            (E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos/Expired.app"), .profileExpired),
            (E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos/Unsigned.app"), .unsigned),
        ]
        for (url, code) in nonDebug {
            let outcome = await model.importBuild(url)
            guard case .rejected(let r) = outcome else {
                Issue.record("\(url.lastPathComponent)(\(url.deletingLastPathComponent().lastPathComponent))가 거부되지 않았다: \(String(describing: outcome))")
                continue
            }
            #expect(r.codes.contains(code), "\(url.lastPathComponent): \(r.codes)")
            #expect(!r.messages.isEmpty)
        }
        #expect(model.builds.map(\.id) == [build.id])
        #expect(model.rejected.count == nonDebug.count)

        // 3. 페어링하지 않은 노드: 403 not_paired, 활동에 거부가 남는다.
        let phone = Peer(binary: bin, control: control.url, stateDir: tmp.path("pa"), hostname: "rd-phone-e2ea")
        let unpaired = try await phone.run("builds", ["--host", base])
        expectHTTP(unpaired, 403, code: "not_paired")
        try await waitUntil("denied 이벤트가 활동에 들어온다") {
            model.activity.contains { if case .denied(let e) = $0.kind { e.reason == "not_paired" } else { false } }
        }

        // 4. 페어링: 코드 → 요청 이벤트 → 사용자가 승인 → 허용 목록.
        await model.beginPairing()
        let code = try #require(model.pairingCode)
        #expect(code.displayCode.count == 9)
        #expect(model.pairingLink?.absoluteString == "remotedebug://pair?host=\(status.fqdn)&code=\(code.code)")
        #expect(model.installPageLink?.absoluteString == "\(base)/#code=\(code.code)")
        let pairing = try phone.start("pair", ["--host", base, "--code", code.code, "--device-name", "E2E iPhone", "--wait", "90s"])
        try await waitUntil("pair-request 이벤트가 온다", timeout: .seconds(60)) { !model.pendingPairRequests.isEmpty }
        let request = try #require(model.pendingPairRequests.first)
        #expect(request.deviceName == "E2E iPhone")
        #expect(request.nodeName == "rd-phone-e2ea")
        #expect(model.pairingState == .requestReceived(requestId: request.requestId))
        #expect(model.pairingCode == nil, "쓰인 코드는 더 보여 주지 않는다")
        #expect(model.devices.isEmpty, "허용 전에는 허용 목록이 비어 있다")
        #expect(pairing.isRunning, "허용하기 전에는 iPhone이 결과를 기다리고 있어야 한다(pending)")
        await model.approve(request.requestId)
        let paired = await pairing.wait(timeout: .seconds(60))
        expectHTTP(paired, 200)
        #expect((paired.body?["state"] as? String) == "approved", "\(paired.summary)")
        #expect(model.devices.count == 1)
        let device = try #require(model.devices.first)
        #expect(device.nodeName == "rd-phone-e2ea")
        #expect(device.name == "E2E iPhone")
        let saved = try JSONFile<DeviceList>(url: paths.devicesFile).load()
        #expect(saved?.devices.map(\.id) == [device.id], "허용한 기기를 저장한다")
        #expect(model.pendingPairRequests.isEmpty)

        // 쓰인 코드는 다시 쓸 수 없다(다른 노드).
        let intruder = Peer(binary: bin, control: control.url, stateDir: tmp.path("pb"), hostname: "rd-phone-e2eb")
        let reused = try await intruder.run("pair", ["--host", base, "--code", code.code, "--wait", "5s"])
        expectHTTP(reused, 403, code: "pair_code_invalid")

        // 4-1. 거부: 실제 어댑터·브리지로 allow=false를 보내면 기기가 추가되지 않는다(T3).
        await model.beginPairing()
        let denyCode = try #require(model.pairingCode)
        let denyPairing = try intruder.start("pair", ["--host", base, "--code", denyCode.code, "--device-name", "Intruder", "--wait", "90s"])
        try await waitUntil("두 번째 pair-request 이벤트가 온다", timeout: .seconds(60)) { !model.pendingPairRequests.isEmpty }
        let denyRequest = try #require(model.pendingPairRequests.first)
        #expect(denyRequest.nodeName == "rd-phone-e2eb")
        #expect(denyPairing.isRunning, "거부하기 전에는 iPhone이 결과를 기다리고 있어야 한다(pending)")
        await model.deny(denyRequest.requestId)
        #expect(model.lastError == nil, "\(model.lastError ?? "")")
        let denied = await denyPairing.wait(timeout: .seconds(60))
        expectHTTP(denied, 200)
        #expect((denied.body?["state"] as? String) == "denied", "\(denied.summary)")
        #expect(model.devices.map(\.id) == [device.id], "거부한 기기가 허용 목록에 들어갔다")
        #expect(try JSONFile<DeviceList>(url: paths.devicesFile).load()?.devices.map(\.id) == [device.id])
        expectHTTP(try await intruder.run("builds", ["--host", base]), 403, code: "not_paired")
        try await waitUntil("거부 결과가 활동에 남는다") {
            model.activity.contains { if case .pairDecided(let e) = $0.kind { e.requestId == denyRequest.requestId && e.state == .denied } else { false } }
        }

        // 5. 등록된 노드: 빌드 목록에 수락된 빌드만 있다.
        let listed = try await phone.run("builds", ["--host", base])
        expectHTTP(listed, 200)
        let listedIDs = ((listed.body?["builds"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        #expect(listedIDs == [build.id], "\(listed.summary)")

        // 6. 설치 세션 → manifest → IPA, SHA-256이 descriptor와 같다.
        let session = try await phone.run("session", ["--host", base, "--build", build.id])
        expectHTTP(session, 201)
        let manifestURL = try #require(session.body?["manifestUrl"] as? String, "\(session.summary)")
        let manifestFile = tmp.path("manifest.plist")
        expectHTTP(try await phone.run("fetch", ["--url", manifestURL, "--out", manifestFile.path]), 200)
        let ipaURL = try manifestIPAURL(manifestFile)
        #expect(ipaURL.hasPrefix(base + "/i/"))
        let ipaFile = tmp.path("app.ipa")
        expectHTTP(try await phone.run("fetch", ["--url", ipaURL, "--out", ipaFile.path]), 200)
        #expect(try sha256Hex(ipaFile) == build.descriptor.ipa.sha256)
        #expect(Int64(try Data(contentsOf: ipaFile).count) == build.descriptor.ipa.size)
        try await waitUntil("세션 완료 이벤트") {
            model.activity.contains { if case .session(let e) = $0.kind { e.state == .completed && e.buildId == build.id } else { false } }
        }

        // 7. 등록되지 않은 노드는 첫 노드의 토큰으로 받을 수 없다.
        let second = try await phone.run("session", ["--host", base, "--build", build.id])
        expectHTTP(second, 201)
        let secondManifest = try #require(second.body?["manifestUrl"] as? String)
        let stolen = try await intruder.run("fetch", ["--url", secondManifest, "--out", tmp.path("stolen.plist").path])
        expectHTTP(stolen, 403)
        #expect(["not_paired", "token_invalid"].contains(stolen.errorCode ?? ""), "\(stolen.summary)")
        expectHTTP(try await intruder.run("builds", ["--host", base]), 403, code: "not_paired")
        expectHTTP(try await intruder.run("session", ["--host", base, "--build", build.id]), 403, code: "not_paired")

        // 8. 기기 제거 뒤에는 접근이 거부된다.
        await model.removeDevice(device.id)
        #expect(model.lastError == nil, "\(model.lastError ?? "")")
        #expect(model.devices.isEmpty)
        expectHTTP(try await phone.run("builds", ["--host", base]), 403, code: "not_paired")
        let revokedFetch = try await phone.run("fetch", ["--url", secondManifest, "--out", tmp.path("revoked.plist").path])
        expectHTTP(revokedFetch, 403)

        // 9. 종료 뒤 호스트의 리스너가 닫혔는지 TCP 단계에서 본다(T5). 사라진 노드로 가는 HTTP 요청은 응답 없이 기한을 넘기므로
        // 피어의 오류 문장으로는 "리스너는 열렸는데 답이 없음"과 구별되지 않는다. forward는 tailnet 연결이 성공해야 바이트를 잇고,
        // 연결을 끝내 맺지 못하면 "forward: dial"을 남기고 로컬 연결을 닫는다. 같은 경로로 종료 전 HTTP 응답을 먼저 확인한다.
        let forwarder = try Child(bin, ["forward", "--control", control.url, "--state-dir", tmp.path("fw").path, "--hostname", "rd-phone-e2ec",
                                        "--listen", "127.0.0.1:0", "--to", "\(status.fqdn):\(Self.port)"])
        defer { forwarder.terminate() }
        let forwardPort = try await forwardListenPort(forwarder)
        let beforeShutdown = await rawHTTPProbe(port: forwardPort, timeout: .seconds(120))
        guard case .responded(let head) = beforeShutdown, head.hasPrefix("HTTP/1.1 403") else {
            Issue.record("종료 전 forward 경로가 동작하지 않는다: \(beforeShutdown)\n\(forwarder.err.string.suffix(1500))")
            return
        }

        await model.shutdown()
        #expect(!model.isRunning)
        #expect(model.status == nil)
        // forward는 10초 연결 시도를 20번 한 뒤 닫는다(약 210초).
        let afterShutdown = await rawHTTPProbe(port: forwardPort, timeout: .seconds(300))
        #expect(afterShutdown == .closed, "종료 뒤 리스너가 닫히지 않았다: \(afterShutdown)")
        // stderr는 비동기로 쌓이므로 로컬 연결이 닫힌 뒤에 도착할 수 있다.
        do {
            try await waitUntil("forward: dial 기록", timeout: .seconds(5)) { forwarder.err.string.contains("forward: dial") }
        } catch {
            Issue.record("tailnet 연결이 실패하지 않았다: \(forwarder.err.string.suffix(1500))")
        }
    }

    // MARK: 도우미

    private func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if await condition() { return }
        throw E2EError("시간 안에 일어나지 않았다: \(what)")
    }

    private func forwardListenPort(_ forwarder: Child) async throws -> UInt16 {
        var port: UInt16?
        try await waitUntil("forward가 준비된다", timeout: .seconds(90)) {
            guard let line = forwarder.out.string.split(separator: "\n").first,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let listen = obj["listen"] as? String, let text = listen.split(separator: ":").last else { return false }
            port = UInt16(text)
            return port != nil
        }
        return try #require(port)
    }

    private func expectHTTP(_ r: ProcessResult, _ status: Int, code: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.httpStatus == status, "\(r.summary)", sourceLocation: sourceLocation)
        if let code { #expect(r.errorCode == code, "\(r.summary)", sourceLocation: sourceLocation) }
    }

    private func manifestIPAURL(_ file: URL) throws -> String {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any]
        let items = plist?["items"] as? [[String: Any]]
        let assets = items?.first?["assets"] as? [[String: Any]]
        guard let url = assets?.first(where: { $0["kind"] as? String == "software-package" })?["url"] as? String else {
            throw E2EError("매니페스트에 IPA 주소가 없다")
        }
        return url
    }
}

extension ProcessResult {
    /// `rdtestenv peer`의 출력 `{"status":N,"body":…}`.
    var httpStatus: Int? { json?["status"] as? Int }
    var body: [String: Any]? { json?["body"] as? [String: Any] }
    var errorCode: String? { (body?["error"] as? [String: Any])?["code"] as? String }
}

extension HostModel {
    func makeConfigForTest() -> CoreConfig { makeConfig(authKey: "") }
}
