import Foundation
import RDModels
import Synchronization
import Testing

@testable import RDHostLogic

// USB 케이블 설치(docs/protocol-addenda.md Q): 직접 연결 리스너에서만, 토큰으로 인증한 기기가,
// 요청이 들어온 케이블의 iPhone에만 설치시킬 수 있다.

/// `anri0`와 `en11`은 UDID `00008120-000000000000001E`인 iPhone의 케이블이다. 설치는 시험이 끝낸다.
private final class FakeCableInstaller: HostCableInstalling {
    struct Call { var ipaPath: String; var device: String; var completion: @Sendable (String?) -> Void }
    static let udid = "00008120-000000000000001E"
    private let state = Mutex<[Call]>([])

    var calls: [Call] { state.withLock { $0 } }

    func device(onInterface name: String) -> String? {
        ["anri0", "en11"].contains(name) ? Self.udid : nil
    }

    func install(ipaPath: String, device: String, completion: @escaping @Sendable (String?) -> Void) {
        state.withLock { $0.append(Call(ipaPath: ipaPath, device: device, completion: completion)) }
    }
}

@Suite("USB 케이블 설치")
struct CableInstallTests {
    private let cable = HostOrigin.direct(remoteIP: "fe80::1c2d:3e4f:5a6b:7c8d", interface: "anri0")

    private func setUp() async throws -> (fixture: HostFixture, installer: FakeCableInstaller, auth: String, buildID: String) {
        let installer = FakeCableInstaller()
        let fixture = try HostFixture(direct: true, cableInstaller: installer)
        let credentials = auth(try await fixture.enroll())
        let buildID = try fixture.host.publish(fixture.writeBuild())
        _ = fixture.drain()
        return (fixture, installer, credentials, buildID)
    }

    private func status(_ fixture: HostFixture, _ id: String, auth: String, origin: HostOrigin) async throws -> SessionStatus {
        try decode(await fixture.request("GET", "/v1/sessions/" + id, headers: [("authorization", auth)], origin: origin))
    }

    @Test("케이블로 온 요청은 그 케이블의 iPhone에 설치하고 세션으로 진행을 알린다")
    func 설치() async throws {
        let (fixture, installer, credentials, buildID) = try await setUp()
        let response = await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)], origin: cable)
        #expect(response.status == 201)
        #expect(header(response, "X-RD-Protocol") == "1")
        let started: CableInstallResponse = try decode(response)
        #expect(started.state == .downloading)

        let call = try #require(installer.calls.first)
        #expect(installer.calls.count == 1)
        #expect(call.device == FakeCableInstaller.udid)
        // 설치가 읽는 파일은 게시본의 사본이다. 게시를 취소해도 남는다.
        #expect(try Data(contentsOf: URL(fileURLWithPath: call.ipaPath)) == Data("0123456789".utf8))

        let running = try await status(fixture, started.sessionId, auth: credentials, origin: cable)
        #expect(running.state == .downloading && running.buildId == buildID && running.message == nil)
        // 설치가 도는 동안에는 시간이 지나도 만료되지 않는다.
        fixture.clock.advance(3_600)
        #expect(try await status(fixture, started.sessionId, auth: credentials, origin: cable).state == .downloading)

        call.completion(nil)
        let done = try await status(fixture, started.sessionId, auth: credentials, origin: cable)
        #expect(done.state == .completed && done.bytesServed == done.size && done.message == nil)
        #expect(!FileManager.default.fileExists(atPath: call.ipaPath))
        let states = fixture.drain().compactMap { event -> SessionState? in
            if case .session(let session) = event, session.sessionId == started.sessionId { return session.state }
            return nil
        }
        #expect(states == [.downloading, .completed])
        // 완료를 두 번 알려도 한 번만 센다.
        call.completion("늦은 실패")
        #expect(try await status(fixture, started.sessionId, auth: credentials, origin: cable).state == .completed)
    }

    @Test("설치가 실패하면 이유를 세션에 싣는다")
    func 실패() async throws {
        let (fixture, installer, credentials, buildID) = try await setUp()
        let started: CableInstallResponse = try decode(await fixture.request(
            "POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)], origin: cable))
        try #require(installer.calls.first).completion("iPhone이 잠겨 있습니다. 잠금을 풀고 다시 설치하세요.")
        let failed = try await status(fixture, started.sessionId, auth: credentials, origin: cable)
        #expect(failed.state == .failed)
        #expect(failed.message == "iPhone이 잠겨 있습니다. 잠금을 풀고 다시 설치하세요.")
    }

    @Test("토큰이 없으면 어떤 케이블로 와도 거절한다")
    func 인증() async throws {
        let (fixture, installer, _, buildID) = try await setUp()
        for value in ["", "RD-Device d_1.abc", "Bearer x"] {
            let response = await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", value)], origin: cable)
            #expect(try response.status == 403 && errorCode(response) == "not_paired")
        }
        #expect(installer.calls.isEmpty)
    }

    @Test("케이블이 아닌 길로 온 요청은 토큰이 맞아도 설치하지 않는다")
    func 케이블만() async throws {
        let (fixture, installer, credentials, buildID) = try await setUp()
        // 같은 네트워크(Wi-Fi)로 온 요청, 인터페이스를 모르는 요청.
        for origin in [HostOrigin.direct(remoteIP: "192.168.0.20", interface: "en1"), .direct(remoteIP: "192.168.0.20")] {
            let response = await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)], origin: origin)
            #expect(try response.status == 409 && errorCode(response) == "cable_required")
        }
        // tailnet 리스너에는 이 경로가 없다.
        let tailnet = await fixture.request("POST", "/v1/builds/\(buildID)/cable-install")
        #expect(try tailnet.status == 404 && errorCode(tailnet) == "not_found")
        #expect(installer.calls.isEmpty)
        #expect(!fixture.drain().contains { if case .session = $0 { return true }; return false })
    }

    @Test("없는 빌드와 바뀐 빌드는 설치하지 않는다")
    func 빌드확인() async throws {
        let (fixture, installer, credentials, _) = try await setUp()
        let missing = await fixture.request("POST", "/v1/builds/b_none/cable-install", headers: [("authorization", credentials)], origin: cable)
        #expect(try missing.status == 404 && errorCode(missing) == "build_not_found")
        let get = await fixture.request("GET", "/v1/builds/b_none/cable-install", headers: [("authorization", credentials)], origin: cable)
        #expect(get.status == 405)
        #expect(installer.calls.isEmpty)
    }

    @Test("다른 기기는 남의 케이블 설치 세션을 볼 수 없다")
    func 세션주인() async throws {
        let (fixture, installer, credentials, buildID) = try await setUp()
        let started: CableInstallResponse = try decode(await fixture.request(
            "POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)], origin: cable))
        // tailnet으로 온 다른 노드.
        let other = HostOrigin.tailnet(HostPeer(stableID: "n_other", nodeName: "rd-phone-00000002", loginName: ""))
        try fixture.host.setDevices([fixture.device(hash: nil), fixture.device(id: "d_2", stableID: "n_other")])
        let response = await fixture.request("GET", "/v1/sessions/" + started.sessionId, origin: other)
        #expect(try response.status == 403 && errorCode(response) == "token_invalid")
        // 케이블 세션에는 매니페스트·IPA 주소가 없다.
        #expect(await fixture.request("GET", "/i//manifest.plist").status != 200)
        installer.calls.first?.completion(nil)
    }

    @Test("로직을 닫으면 도는 설치의 세션은 실패로 끝나고 늦은 완료는 무시한다")
    func 닫기() async throws {
        let (fixture, installer, credentials, buildID) = try await setUp()
        _ = await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)], origin: cable)
        fixture.host.close()
        let states = fixture.drain().compactMap { event -> SessionState? in
            if case .session(let session) = event { return session.state }
            return nil
        }
        #expect(states == [.downloading, .failed])
        try #require(installer.calls.first).completion(nil)
        #expect(!fixture.drain().contains { if case .session = $0 { return true }; return false })
    }
}
