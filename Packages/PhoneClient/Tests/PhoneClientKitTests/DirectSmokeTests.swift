import Foundation
import RDModels
import Testing

@testable import PhoneClientKit

/// 실제 코어의 직접 연결 리스너에 iPhone 앱의 실제 전송(공개 키 고정 `URLSession`)으로 붙어 보는 수동 확인.
/// `RD_DIRECT_SMOKE_FILE`이 있을 때만 돈다. Mac 쪽은 core/internal/host의 `TestDirectSmokeServer`가 띄운다.
@Suite("직접 연결 수동 확인")
struct DirectSmokeTests {
    private struct Setup: Decodable {
        var address: String
        var port: Int
        var spki: String
        var deviceId: String
        var token: String
        var hostId: String
        var resourceId: String
        var resourceName: String
        var size: Int64
        var sha256: String
    }

    private static var file: String? { ProcessInfo.processInfo.environment["RD_DIRECT_SMOKE_FILE"] }

    @Test(.enabled(if: DirectSmokeTests.file != nil))
    func pinnedTransportTalksToTheRealListener() async throws {
        let path = try #require(Self.file)
        defer { FileManager.default.createFile(atPath: path + ".done", contents: nil) }
        let setup = try JSONDecoder().decode(Setup.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let client = ClientInfo(osVersion: "26.1", appVersion: "0.1.0")
        let endpoint = DirectEndpoint(host: setup.address, port: setup.port)
        let authorization = "RD-Device \(setup.deviceId).\(setup.token)"

        // 맞는 고정 값: 정보, 파일 목록, 파일 받기(크기와 SHA-256 확인까지).
        let api = try #require(HostAPI(direct: endpoint, authorization: authorization,
                                       transport: PinnedURLSessionTransport(pin: setup.spki), client: client))
        let info = try await api.info()
        #expect(info.hostId == setup.hostId)
        let resources = try await api.resources()
        let resource = try #require(resources.first { $0.id == setup.resourceId })
        #expect(resource.size == setup.size)
        let progress = ProgressBox()
        let downloaded = try await api.download(resource) { received, _ in progress.note(received) }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let (size, sha) = try FileDigest.sha256(of: downloaded)
        #expect(size == setup.size)
        #expect(sha == setup.sha256)
        #expect(progress.last == setup.size)

        // 틀린 고정 값: TLS에서 끊긴다. 서버 쪽은 이 요청을 받지 않았음을 따로 확인한다.
        let wrong = try #require(HostAPI(direct: endpoint, authorization: authorization,
                                         transport: PinnedURLSessionTransport(pin: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="), client: client))
        do {
            _ = try await wrong.info()
            Issue.record("틀린 공개 키에 연결됐다")
        } catch let error as HostAPIError {
            #expect(error.isConnectionFailure)
        }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func note(_ received: Int64) { lock.withLock { value = max(value, received) } }
    var last: Int64 { lock.withLock { value } }
}
