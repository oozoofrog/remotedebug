import Foundation
import RDModels
import Synchronization
import Testing

@testable import RDHostLogic

// USB 케이블 설치(docs/protocol-addenda.md R): 직접 연결 리스너에서만, 토큰으로 인증한 기기가,
// 요청이 들어온 케이블의 iPhone에만 설치시킬 수 있다.

/// `anri0`와 `en11`은 UDID `00008120-000000000000001E`인 iPhone의 케이블, `anri1`은 다른 iPhone의 케이블이다. 설치는 시험이 끝낸다.
private final class FakeCableInstaller: HostCableInstalling {
    struct Call { var ipaPath: String; var device: String; var completion: @Sendable (String?) -> Void }
    static let udid = "00008120-000000000000001E"
    static let otherUDID = "00008120-00000000000000FF"
    private let state = Mutex<[Call]>([])

    var calls: [Call] { state.withLock { $0 } }

    func device(onInterface name: String) -> String? {
        ["anri0", "en11"].contains(name) ? Self.udid : name == "anri1" ? Self.otherUDID : nil
    }

    func install(ipaPath: String, device: String, completion: @escaping @Sendable (String?) -> Void) {
        state.withLock { $0.append(Call(ipaPath: ipaPath, device: device, completion: completion)) }
    }
}

@Suite("USB 케이블 설치")
struct CableInstallTests {
    private let cable = HostOrigin.direct(remoteIP: "fe80::1c2d:3e4f:5a6b:7c8d", interface: "anri0")

    private let otherCable = HostOrigin.direct(remoteIP: "fe80::aaaa:bbbb:cccc:dddd", interface: "anri1")

    private func setUp(limits: HostLogic.Limits = .init()) async throws -> (fixture: HostFixture, installer: FakeCableInstaller, auth: String, buildID: String) {
        let installer = FakeCableInstaller()
        let fixture = try HostFixture(direct: true, limits: limits, cableInstaller: installer)
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
        // 받은 인터페이스가 케이블이어도, 보낸 쪽 주소가 링크 로컬이 아니면 케이블 건너편이 아니다.
        for ip in ["192.168.0.20", "10.0.0.5", "fd00::1", "2001:db8::1", "::ffff:192.168.0.20", "not-an-address", ""] {
            let response = await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)],
                                                 origin: .direct(remoteIP: ip, interface: "anri0"))
            #expect(try response.status == 409 && errorCode(response) == "cable_required", "\(ip)")
        }
        // 링크 로컬 주소로 왔어도 받은 인터페이스를 모르면 거절한다(전송은 IPv4 연결의 인터페이스를 주지 않는다).
        for ip in ["169.254.10.20", "fe80::1c2d:3e4f:5a6b:7c8d"] {
            let response = await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)],
                                                 origin: .direct(remoteIP: ip))
            #expect(try response.status == 409 && errorCode(response) == "cable_required", "\(ip)")
        }
        #expect(HostLogic.isLinkLocal("fe80::1") && HostLogic.isLinkLocal("febf::1") && HostLogic.isLinkLocal("169.254.0.1"))
        #expect(!HostLogic.isLinkLocal("fec0::1") && !HostLogic.isLinkLocal("169.255.0.1"))
        // tailnet 리스너에는 이 경로가 없다.
        let tailnet = await fixture.request("POST", "/v1/builds/\(buildID)/cable-install")
        #expect(try tailnet.status == 404 && errorCode(tailnet) == "not_found")
        #expect(installer.calls.isEmpty)
        #expect(!fixture.drain().contains { if case .session = $0 { return true }; return false })
    }

    @Test("기기의 토큰은 처음 케이블 설치를 한 iPhone에 묶인다. 다른 iPhone의 케이블로 오면 거절하고, 허용 목록에서 빼면 풀린다")
    func 기기묶기() async throws {
        let (fixture, installer, credentials, buildID) = try await setUp()
        func install(_ origin: HostOrigin, _ auth: String) async -> HostResponse {
            await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", auth)], origin: origin)
        }
        #expect(await install(cable, credentials).status == 201)
        // 묶인 iPhone은 기기 항목에 실려 Mac 앱이 저장한다.
        let updates = fixture.drain().compactMap { event -> DeviceEntry? in
            if case .deviceUpdated(let device) = event { return device }
            return nil
        }
        #expect(updates.map(\.cableUDID) == [FakeCableInstaller.udid] && updates.first?.id == "d_1")
        try #require(installer.calls.first).completion(nil)

        // 같은 토큰이 다른 iPhone의 케이블로 오면 설치하지 않는다.
        let refused = await install(otherCable, credentials)
        #expect(try refused.status == 409 && errorCode(refused) == "cable_device_mismatch")
        let message = try decode(refused, as: APIErrorBody.self).error.message
        #expect(message.contains("다른 iPhone") && message.contains("기기 목록에서 이 기기를 빼고"))
        #expect(installer.calls.count == 1)
        // 묶인 iPhone으로는 계속 된다(같은 iPhone의 다른 인터페이스 포함). 다시 묶었다고 알리지 않는다.
        _ = fixture.drain()
        #expect(await install(.direct(remoteIP: "fe80::1c2d:3e4f:5a6b:7c8d", interface: "en11"), credentials).status == 201)
        #expect(!fixture.drain().contains { if case .deviceUpdated = $0 { return true }; return false })
        try #require(installer.calls.last).completion(nil)
        #expect(installer.calls.map(\.device) == [FakeCableInstaller.udid, FakeCableInstaller.udid])

        // Mac 앱이 저장해 둔 묶음을 다시 넣어도 지켜진다(앱을 다시 켠 뒤).
        let hash = HostIDs.directTokenHash(String(credentials.split(separator: ".").last ?? ""))
        try fixture.host.setDevices([fixture.device(hash: hash, cableUDID: FakeCableInstaller.udid.lowercased())])
        #expect(try errorCode(await install(otherCable, credentials)) == "cable_device_mismatch")
        #expect(await install(cable, credentials).status == 201, "UDID의 대소문자는 가리지 않는다")
        try #require(installer.calls.last).completion(nil)
        // 주인이 기기를 뺐다가 다시 허용하면(묶음 없는 새 항목) 다른 iPhone에 묶을 수 있다.
        try fixture.host.setDevices([fixture.device(hash: hash)])
        #expect(await install(otherCable, credentials).status == 201)
        #expect(installer.calls.last?.device == FakeCableInstaller.otherUDID)
        try #require(installer.calls.last).completion(nil)
        #expect(try errorCode(await install(cable, credentials)) == "cable_device_mismatch")
    }

    @Test("한 iPhone에는 한 번에 하나만 설치한다. 끝나면 다시 받는다")
    func 한번에하나() async throws {
        let (fixture, installer, credentials, buildID) = try await setUp()
        func install() async -> HostResponse {
            await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)], origin: cable)
        }
        let first: CableInstallResponse = try decode(await install())
        let busy = await install()
        #expect(try busy.status == 409 && errorCode(busy) == "cable_busy")
        #expect(try decode(busy, as: APIErrorBody.self).error.message.contains("이미 진행 중"))
        #expect(installer.calls.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent(".rd-snapshots").path)
            .filter { $0.hasPrefix("cable-") }.count == 1, "거절한 요청은 사본을 남기지 않는다")
        // 실패로 끝나도 자리가 빈다.
        try #require(installer.calls.first).completion("iPhone이 잠겨 있습니다.")
        #expect(try await status(fixture, first.sessionId, auth: credentials, origin: cable).state == .failed)
        #expect(await install().status == 201)
        #expect(installer.calls.count == 2)
        try #require(installer.calls.last).completion(nil)
    }

    @Test("끝났다고 알리지 않는 설치는 기한이 지나면 실패로 끝내고 사본을 지운다")
    func 기한() async throws {
        let (fixture, installer, credentials, buildID) = try await setUp(limits: .init(cableInstallTimeout: 0.2))
        let started: CableInstallResponse = try decode(await fixture.request(
            "POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)], origin: cable))
        let call = try #require(installer.calls.first)
        #expect(FileManager.default.fileExists(atPath: call.ipaPath))
        var state = SessionState.downloading
        for _ in 0..<100 where state == .downloading {
            try await Task.sleep(for: .milliseconds(50))
            state = try await status(fixture, started.sessionId, auth: credentials, origin: cable).state
        }
        let ended = try await status(fixture, started.sessionId, auth: credentials, origin: cable)
        #expect(ended.state == .failed && ended.message == HostLogic.cableInstallTimedOut)
        #expect(!FileManager.default.fileExists(atPath: call.ipaPath), "사본을 지운다")
        // 뒤늦게 온 완료는 세지 않고, 자리가 비어 다시 설치할 수 있다.
        call.completion(nil)
        #expect(try await status(fixture, started.sessionId, auth: credentials, origin: cable).state == .failed)
        #expect(await fixture.request("POST", "/v1/builds/\(buildID)/cable-install", headers: [("authorization", credentials)], origin: cable).status == 201)
        try #require(installer.calls.last).completion(nil)
        #expect(HostLogic.Limits().cableInstallTimeout == HostLogic.Limits.defaultCableInstallTimeout && HostLogic.Limits.defaultCableInstallTimeout >= 1200)
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
