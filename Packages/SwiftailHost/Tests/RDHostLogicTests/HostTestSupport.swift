import CryptoKit
import Foundation
import RDModels
import Testing
@testable import RDHostLogic

actor MemoryBody: HostBodyReader {
    var bytes: ArraySlice<UInt8>
    let chunkSize: Int
    init(_ data: Data, chunkSize: Int = .max) { bytes = Array(data)[...]; self.chunkSize = chunkSize }
    func read(upTo count: Int) async throws -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        let result = Array(bytes.prefix(min(count, chunkSize)))
        bytes = bytes.dropFirst(result.count)
        return result
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_794_387_600)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}

final class HostFixture: @unchecked Sendable {
    let directory: URL
    let host: HostLogic
    let clock: TestClock
    let events = HostEventQueue()
    static let peer = HostPeer(stableID: "n_phone", nodeName: "rd-phone-00000001", loginName: "")
    init(paired: Bool = true, direct: Bool = false, limits: HostLogic.Limits = .init(), cableInstaller: (any HostCableInstalling)? = nil) throws {
        // 패키지 리소스 묶음 옆은 eyebuild의 산출물 폴더다. 시스템 임시 폴더를 사용하지 않는다.
        directory = HostLogic.resourceRoot.deletingLastPathComponent().appendingPathComponent("host-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = TestClock()
        self.clock = clock
        let queue = events
        let folder = directory
        host = try HostLogic(options: .init(publishDirectory: directory.path,
            info: { .init(hostID: "h_1", hostName: "Mac", fqDN: "rd-mac-1.example.ts.net", appVersion: "1.0") },
            baseURL: { "https://rd-mac-1.example.ts.net" }, now: { clock.now() }, limits: limits,
            direct: { direct ? .init(id: "0123456789abcdef", port: 49152, spki: "c3BraQ==") : nil },
            events: { _ in }, eventDetails: { queue.push($0) }, cableInstaller: cableInstaller,
            feedbackChecklist: { try? Data(contentsOf: folder.appendingPathComponent("checklist-" + $0 + ".json")) }))
        if paired { try host.setDevices([device()]) }
    }
    deinit { host.close(); try? FileManager.default.removeItem(at: directory) }
    func device(id: String = "d_1", stableID: String = "n_phone", hash: String? = nil, push: PushRegistration? = nil) -> DeviceEntry {
        DeviceEntry(id: id, name: "시험 iPhone", nodeStableId: stableID, nodeName: Self.peer.nodeName,
                    loginName: "", pairedAt: clock.now(), directTokenHash: hash, push: push)
    }
    func request(_ method: String, _ target: String, body: String? = nil,
                 headers: [(String, String)] = [], origin: HostOrigin = .tailnet(HostFixture.peer), chunkSize: Int = .max) async -> HostResponse {
        let data = body.map { Data($0.utf8) }
        var headers = headers
        if data != nil && !headers.contains(where: { $0.0 == "content-type" }) { headers.append(("content-type", "application/json")) }
        return await host.handle(HostRequest(method: method, target: target, headers: headers,
            body: data.map { MemoryBody($0, chunkSize: chunkSize) }, contentLength: UInt64(data?.count ?? 0), origin: origin))
    }
    func request(_ target: String) async -> HostResponse { await request("GET", target) }
    func writeResource(_ name: String = "a.txt", _ text: String = "hello") throws -> ResourcePublishRequest {
        let url = directory.appendingPathComponent("resources").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: url)
        return ResourcePublishRequest(resource: .init(id: "", name: name, size: Int64(data.count), sha256: digest(data), publishedAt: clock.now()), path: url.path)
    }
    func writeBuild(_ text: String = "0123456789", bundleID: String = "com.example.app") throws -> PublishRequest {
        let url = directory.appendingPathComponent(UUID().uuidString + ".ipa")
        let data = Data(text.utf8)
        try data.write(to: url)
        return PublishRequest(build: BuildDescriptor(id: "", bundleId: bundleID, displayName: "Sample", version: "1.0", buildNumber: "1",
            minOS: "26.0", debug: true, configuration: "Debug", configurationEvidence: .path,
            signing: .init(teamId: "EXAMPLE", profileName: "Example", profileExpires: clock.now().addingTimeInterval(3600), provisionedDeviceCount: 1, getTaskAllow: true),
            ipa: .init(size: Int64(data.count), sha256: digest(data)), publishedAt: clock.now()), ipaPath: url.path)
    }
    func enroll() async throws -> DirectEnrollment { try decode(await request("POST", "/v1/direct/enroll")) }
    func createSession(_ buildID: String) async throws -> SessionResponse { try decode(await request("POST", "/v1/builds/" + buildID + "/sessions")) }
    func drain() -> [CoreEvent] {
        var result: [CoreEvent] = []
        while let event = events.next() { result.append(event) }
        return result
    }
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func auth(_ enrollment: DirectEnrollment) -> String { "RD-Device " + enrollment.deviceId + "." + enrollment.token }
func responseData(_ response: HostResponse) throws -> Data {
    switch response.body {
    case .none: return Data()
    case .bytes(let bytes): return Data(bytes)
    case .file(let path, let offset, let count):
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: Int(count)) ?? Data()
    }
}
func decode<T: Decodable>(_ response: HostResponse, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: responseData(response))
}
func errorCode(_ response: HostResponse) throws -> String {
    let error: APIErrorBody = try decode(response)
    #expect(!error.error.message.isEmpty)
    return error.error.code
}
func header(_ response: HostResponse, _ name: String) -> String? {
    response.headers.first { $0.name.lowercased() == name.lowercased() }?.value
}
func jsonText(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}
func expectError(_ code: String, _ body: () throws -> Void) {
    do { try body(); Issue.record("오류가 발생해야 합니다: \(code)") }
    catch let error as APIErrorBody { #expect(error.error.code == code) }
    catch { Issue.record("APIErrorBody가 아닙니다: \(error)") }
}
