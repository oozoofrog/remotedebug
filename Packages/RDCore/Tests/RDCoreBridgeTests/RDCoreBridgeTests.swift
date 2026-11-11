import Foundation
import Testing

@testable import RDCoreBridge

/// C 경계 검증. 이 테스트는 실제 노드를 시작하지 않는다(검증 단계에서 거절되는 설정만 쓴다).
@Suite struct RDCoreBridgeTests {
    @Test func unknownHandleReturnsError() throws {
        #expect(throws: RDCoreError.self) { try RDNode(handle: -1).status() }
        do {
            _ = try RDNode(handle: -1).status()
        } catch let error as RDCoreError {
            #expect(error.code == "unknown_handle")
        }
    }

    @Test func malformedConfigIsRejectedWithoutStartingANode() {
        do {
            _ = try RDNode.start(config: Data("not json".utf8))
            Issue.record("잘못된 JSON이 통과했다")
        } catch let error as RDCoreError {
            #expect(["invalid_config", "bad_request"].contains(error.code), "code=\(error.code)")
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test func plainHTTPWithNonLoopbackControlURLIsRejected() {
        let config = #"{"mode":"host","stateDir":"/nonexistent/rd-bridge-test","hostname":"rd-mac-test","listenTLS":false,"controlURL":"https://control.invalid","port":8080,"publishDir":"/nonexistent/rd-bridge-test/pub"}"#
        do {
            _ = try RDNode.start(config: Data(config.utf8))
            Issue.record("평문 HTTP + 외부 제어 서버가 통과했다")
        } catch let error as RDCoreError {
            #expect(error.code == "invalid_config", "code=\(error.code)")
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test func setDefaultInterfaceOnUnknownHandleFails() {
        do {
            try RDNode(handle: -1).setDefaultInterface("en0")
            Issue.record("없는 핸들이 통과했다")
        } catch let error as RDCoreError {
            #expect(error.code == "unknown_handle", "code=\(error.code)")
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    /// 범위 밖 mtu만 거절 사유가 되도록 나머지는 통과 가능한 값으로 둔다(만들 수 있는 stateDir).
    /// utun fd는 테스트에서 만들 수 없으므로, mtu 검사가 빠지면 fd 검사의 다른 메시지가 나와 실패한다.
    @Test(arguments: [1279, 1421, 1500, 9000])
    func tunnelMTUOutOfRangeIsRejected(mtu: Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rd-bridge-tunnel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = #"{"mode":"tunnel","stateDir":"\#(dir.path)","hostname":"rd-phone-test","controlURL":"http://127.0.0.1:1","utunFd":7,"mtu":\#(mtu)}"#
        do {
            _ = try RDNode.start(config: Data(config.utf8))
            Issue.record("범위 밖 mtu \(mtu)가 통과했다")
        } catch let error as RDCoreError {
            #expect(error.code == "invalid_config", "code=\(error.code)")
            #expect(error.message == "mtu는 1280 이상 1420 이하여야 합니다.", "message=\(error.message)")
        } catch {
            Issue.record("예상하지 못한 오류: \(error)")
        }
    }

    @Test func eventStreamEndsWhenTheNodeIsGone() async {
        var count = 0
        for await _ in RDNode(handle: -1).events(pollMilliseconds: 50) { count += 1 }
        #expect(count == 0)
    }
}
