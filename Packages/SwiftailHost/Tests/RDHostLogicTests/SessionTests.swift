import Foundation
import RDModels
import Testing
@testable import RDHostLogic

@Suite("게시 빌드와 설치 세션")
struct SessionTests {
    @Test("게시 검증과 사본 불변 및 설명 교체")
    func 게시검증() async throws {
        let fixture = try HostFixture()
        let original = try fixture.writeBuild()
        var bad = original
        bad.build.debug = false
        expectError("not_debug_build") { try fixture.host.publish(bad) }
        bad = original
        bad.build.signing.getTaskAllow = false
        expectError("not_debug_build") { try fixture.host.publish(bad) }
        bad = original
        bad.build.bundleId = ""
        expectError("bad_request") { try fixture.host.publish(bad) }
        bad = original
        bad.build.icon = Data("invalid".utf8)
        expectError("bad_request") { try fixture.host.publish(bad) }
        bad = original
        bad.build.releaseNotes = String(repeating: "a", count: BuildDescriptor.maxReleaseNotesBytes + 1)
        expectError("bad_request") { try fixture.host.publish(bad) }
        bad = original
        bad.build.ipa.sha256 = String(repeating: "0", count: 64)
        expectError("hash_mismatch") { try fixture.host.publish(bad) }
        bad = original
        bad.build.id = "b_wrong"
        expectError("bad_request") { try fixture.host.publish(bad) }
        let id = try fixture.host.publish(original)
        #expect(fixture.host.counts().builds == 1)
        var updated = original
        updated.build.displayName = "New name"
        #expect(try fixture.host.publish(updated) == id)
        let list: BuildsResponse = try decode(await fixture.request("/v1/builds"))
        #expect(list.builds.count == 1 && list.builds[0].displayName == "New name")
        #expect(list.builds[0].releaseNotes == nil)
        updated.build.releaseNotes = "  로그인 고침\r\n- 목록 정렬\n"
        #expect(try fixture.host.publish(updated) == id)
        let noted: BuildsResponse = try decode(await fixture.request("/v1/builds"))
        #expect(noted.builds[0].releaseNotes == "로그인 고침\n- 목록 정렬")
        try Data("changed source".utf8).write(to: URL(fileURLWithPath: original.ipaPath))
        let session = try await fixture.createSession(id)
        let target = try #require(URLComponents(url: session.manifestUrl, resolvingAgainstBaseURL: false)?.path)
        #expect(await fixture.request(target).status == 200)
        let file = await fixture.request(target.replacingOccurrences(of: "manifest.plist", with: "app.ipa"))
        #expect(try responseData(file) == Data("0123456789".utf8))
        file.onFinished?(10, true)
    }

    @Test("HEAD는 매니페스트 횟수 상태와 만료를 바꾸지 않음")
    func HEAD요청() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publish(fixture.writeBuild())
        let session = try await fixture.createSession(id)
        let manifest = session.manifestUrl.path
        let ipa = manifest.replacingOccurrences(of: "manifest.plist", with: "app.ipa")
        _ = fixture.drain()
        for _ in 0..<7 {
            #expect(await fixture.request("HEAD", manifest).status == 200)
            let response = await fixture.request("HEAD", ipa)
            #expect(response.status == 200 && header(response, "Accept-Ranges") == "bytes")
            response.onFinished?(0, true)
        }
        let status: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.state == .created && status.expiresAt == session.expiresAt && status.bytesServed == 0)
        #expect(fixture.drain().isEmpty)
        for _ in 0..<5 { #expect(await fixture.request(manifest).status == 200) }
        let exhausted = await fixture.request(manifest)
        #expect(try exhausted.status == 410 && (errorCode(exhausted)) == "session_expired")
    }

    @Test("겹친 범위를 합쳐 완료하고 토큰은 즉시 닫음")
    func 범위완료() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publish(fixture.writeBuild())
        let session = try await fixture.createSession(id)
        let target = session.manifestUrl.path.replacingOccurrences(of: "manifest.plist", with: "app.ipa")
        for (range, bytes) in [("bytes=0-3", 4), ("bytes=2-5", 4), ("bytes=0-3", 4)] {
            let response = await fixture.request("GET", target, headers: [("range", range)])
            #expect(response.status == 206)
            response.onFinished?(UInt64(bytes), true)
        }
        var status: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.state == .downloading && status.bytesServed == 6)
        #expect(status.expiresAt == fixture.clock.now().addingTimeInterval(600))
        let last = await fixture.request("GET", target, headers: [("range", "bytes=6-")])
        #expect(last.status == 206)
        last.onFinished?(4, true)
        last.onFinished?(4, true)
        status = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.state == .completed && status.bytesServed == 10)
        #expect(await fixture.request(target).status == 410)
        let events = fixture.drain()
        #expect(events.filter { if case .session(let s) = $0 { return s.state == .completed }; return false }.count == 1)
    }

    @Test("유효 범위 전송은 완료까지 만료를 보류")
    func 진행중만료() async throws {
        let fixture = try HostFixture(limits: .init(sessionTTL: 2, sessionMaxTTL: 6))
        let id = try fixture.host.publish(fixture.writeBuild())
        let session = try await fixture.createSession(id)
        let target = session.manifestUrl.path.replacingOccurrences(of: "manifest.plist", with: "app.ipa")
        let response = await fixture.request("GET", target, headers: [("range", "bytes=0-3")])
        fixture.clock.advance(7)
        fixture.host.sweep()
        var status: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.state == .downloading)
        #expect(fixture.host.transferState(sessionID: session.sessionId)?.allowed == false)
        response.onFinished?(4, true)
        status = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.state == .expired && status.bytesServed == 4)
    }

    @Test("중단된 마지막 조각과 매니페스트 없이 시작한 전체 받기")
    func 중단과완료() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publish(fixture.writeBuild(String(repeating: "x", count: 100_000)))
        let session = try await fixture.createSession(id)
        let target = session.manifestUrl.path.replacingOccurrences(of: "manifest.plist", with: "app.ipa")
        let partial = await fixture.request(target)
        partial.onFinished?(40_000, false)
        var status: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.bytesServed == 32768 && status.state == .downloading)
        let full = await fixture.request("GET", target, headers: [("range", "bytes=0-2,9-12")])
        #expect(full.status == 200)
        full.onFinished?(100_000, true)
        status = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.bytesServed == 100_000 && status.state == .completed)
    }

    @Test("게시 취소와 목록 제거는 열린 세션을 실패로 고정")
    func 철회() async throws {
        for removeDevice in [false, true] {
            let fixture = try HostFixture()
            let id = try fixture.host.publish(fixture.writeBuild())
            let session = try await fixture.createSession(id)
            let response = await fixture.request(session.manifestUrl.path.replacingOccurrences(of: "manifest.plist", with: "app.ipa"))
            if removeDevice { try fixture.host.setDevices([]); try fixture.host.setDevices([fixture.device()]) }
            else { try fixture.host.unpublish(buildID: id) }
            #expect(fixture.host.transferState(sessionID: session.sessionId)?.allowed == false)
            response.onFinished?(10, false)
            let status: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
            #expect(status.state == .failed)
            #expect(await fixture.request(session.manifestUrl.path).status == 410)
        }
    }

    @Test("다른 기기의 세션은 거부하고 오래된 토큰은 정리")
    func 소유와정리() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publish(fixture.writeBuild())
        let session = try await fixture.createSession(id)
        let foreign = HostPeer(stableID: "n_other", nodeName: "rd-phone-00000002", loginName: "")
        try fixture.host.setDevices([fixture.device(), fixture.device(id: "d_2", stableID: "n_other")])
        for target in ["/v1/sessions/" + session.sessionId, session.manifestUrl.path] {
            let response = await fixture.request("GET", target, origin: .tailnet(foreign))
            #expect(try response.status == 403 && (errorCode(response)) == "token_invalid")
        }
        fixture.clock.advance(180)
        fixture.host.sweep()
        #expect(await fixture.request(session.manifestUrl.path).status == 410)
        fixture.clock.advance(3601)
        fixture.host.sweep()
        let removed = await fixture.request(session.manifestUrl.path)
        #expect(try removed.status == 403 && (errorCode(removed)) == "token_invalid")
    }

    @Test("사본 변경은 세션 생성과 서빙에서 감지")
    func 사본변경() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publish(fixture.writeBuild())
        let session = try await fixture.createSession(id)
        let path = try #require(fixture.host.locked { fixture.host.builds[id]?.file.path })
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try Data("changed snapshot".utf8).write(to: URL(fileURLWithPath: path))
        let creation = await fixture.request("POST", "/v1/builds/" + id + "/sessions")
        #expect(try creation.status == 409 && (errorCode(creation)) == "build_changed")
        #expect(await fixture.request("HEAD", session.manifestUrl.path).status == 409)
        let status: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.state == .created)
        #expect(await fixture.request(session.manifestUrl.path).status == 409)
        let failed: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(failed.state == .failed)
    }

    @Test("파일 응답은 게시 취소 뒤에도 같은 사본을 열 수 있음")
    func 응답파일수명() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publishResource(fixture.writeResource("a.txt", "snapshot"))
        let response = await fixture.request("/v1/resources/" + id)
        try fixture.host.unpublishResource(id: id)
        #expect(try responseData(response) == Data("snapshot".utf8))
        guard case .file(let path, _, _) = response.body else { Issue.record("파일 응답 없음"); return }
        response.onFinished?(8, true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("닫기는 모든 열린 세션 실패와 사본 제거")
    func 종료() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publish(fixture.writeBuild())
        _ = try fixture.host.publishResource(fixture.writeResource())
        _ = try await fixture.createSession(id)
        _ = fixture.drain()
        fixture.host.close()
        #expect(fixture.host.counts().builds == 0)
        #expect(fixture.drain().contains { if case .session(let s) = $0 { return s.state == .failed }; return false })
        #expect(await fixture.request("/v1/info").status == 200)
        expectError("not_running") { try fixture.host.publish(fixture.writeBuild()) }
    }
    @Test("파일 경로별 진행률과 읽기 실패를 전송에서 전달")
    func 전송관찰() async throws {
        let fixture = try HostFixture()
        let id = try fixture.host.publish(fixture.writeBuild(String(repeating: "x", count: 100_000)))
        let session = try await fixture.createSession(id)
        let response = await fixture.request(session.manifestUrl.path.replacingOccurrences(of: "manifest.plist", with: "app.ipa"))
        guard case .file(let path, _, _) = response.body else { Issue.record("파일 응답 없음"); return }
        #expect(fixture.host.transferState(filePath: path)?.allowed == true)
        fixture.host.recordTransferProgress(filePath: path, sentBodyBytes: 32768)
        let status: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(status.state == .downloading && status.bytesServed == 32768)
        fixture.host.recordTransferReadFailure(filePath: path)
        #expect(fixture.host.transferState(filePath: path)?.allowed == false)
        response.onFinished?(32768, false)
        let failed: SessionStatus = try decode(await fixture.request("/v1/sessions/" + session.sessionId))
        #expect(failed.state == .failed && failed.bytesServed == 32768)
        #expect(fixture.host.transferState(filePath: path) == nil)
    }

}
