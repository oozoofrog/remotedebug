import AppKit
import Foundation
import MacHostCore
import MacHostKit
import Network
import RDModels
import XCTest

/// 환경: E2EEnv의 값에 더해 `RD_E2E_WEB=1`(scripts/e2e-web.sh가 설정), `RD_WEB_SHOTS`(스크린숏 폴더).
enum WebEnv {
    static var enabled: Bool { ProcessInfo.processInfo.environment["RD_E2E_WEB"] == "1" }

    static func shots() throws -> URL {
        let path = ProcessInfo.processInfo.environment["RD_WEB_SHOTS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/Volumes/eyedisk/build/remotedebug/e2e-web-shots"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 시험 환경: 가짜 제어 서버, 실제 Go 코어로 공유하는 Mac(`HostModel` + `RDCoreHost`), iPhone 노드 하나(forward).
@MainActor
final class WebWorld {
    static let macPort = 8080
    static let node = "rd-web-iphone"
    /// 서버가 내주는 글자가 마크업으로 해석되지 않는지 보는 탐침. 이 클래스의 요소가 DOM에 생기면 안 된다.
    static let probeClass = "rd-probe"
    static let hostName = "E2E Mac <i class=\"rd-probe\">맥</i>"

    let tmp: URL
    let logs: URL
    let control: FakeControl
    let paths: HostPaths
    let mac: HostModel
    let fqdn: String
    let forwarder: Forwarder
    private(set) var accepted: BuildDescriptor?
    private(set) var rejected: [RejectedBuild] = []
    private var finished = false

    private init(tmp: URL, logs: URL, control: FakeControl, paths: HostPaths, mac: HostModel, fqdn: String, forwarder: Forwarder) {
        self.tmp = tmp
        self.logs = logs
        self.control = control
        self.paths = paths
        self.mac = mac
        self.fqdn = fqdn
        self.forwarder = forwarder
    }

    static func start(binary: String, tmp: URL, logs: URL) async throws -> WebWorld {
        let control = try await FakeControl(binary: binary)
        let paths = HostPaths(root: tmp.appendingPathComponent("host", isDirectory: true))
        let mac = HostModel(core: RDCoreHost(), paths: paths, bookmarks: NoFolderBookmarks(), id8: randomID8(),
                            hostDisplayName: hostName, appVersion: "0.1.0", port: macPort)
        mac.controlURL = control.url
        await mac.start()
        if let error = mac.lastError { throw E2EError("공유를 시작하지 못했다: \(error)") }
        try await until("호스트가 Running·listening이 된다", timeout: .seconds(60)) {
            await mac.refreshStatus()
            return mac.status?.backendState == .running && mac.status?.listening == true
        }
        guard let raw = mac.status?.fqdn, !raw.isEmpty else { throw E2EError("호스트 fqdn이 없다") }
        let fqdn = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
        let forwarder = try await Forwarder(binary: binary, control: control.url, stateDir: tmp.appendingPathComponent("node"),
                                            nodeName: node, target: "\(fqdn):\(macPort)")
        let result = await rawHTTPProbe(port: forwarder.port, timeout: .seconds(120))
        guard case .responded(let head) = result, head.hasPrefix("HTTP/1.1 404"), head.lowercased().contains("x-rd-protocol: 1") else {
            throw E2EError("forward가 호스트에 닿지 않는다: \(result)\n\(forwarder.child.err.string.suffix(1500))")
        }
        return WebWorld(tmp: tmp, logs: logs, control: control, paths: paths, mac: mac, fqdn: fqdn, forwarder: forwarder)
    }

    var loopbackOrigin: String { "http://127.0.0.1:\(forwarder.port)" }
    var tailnetOrigin: String { "http://\(fqdn):\(Self.macPort)" }

    func descriptor() throws -> BuildDescriptor {
        guard let accepted else { throw E2EError("가져온 빌드가 없다") }
        return accepted
    }

    /// 수락되는 Debug 빌드 하나와 거부되는 빌드 넷(Release 경로의 같은 앱, AdHoc 배포, 만료, 서명 없음)을 가져온다.
    func importFixtures() async throws {
        let fixtures = E2EEnv.fixtures.appendingPathComponent("Debug-iphoneos", isDirectory: true)
        let source = fixtures.appendingPathComponent("AcceptedDev.app")
        guard case .accepted(let build) = await mac.importBuild(source) else {
            throw E2EError("AcceptedDev가 수락되지 않았다: \(mac.rejected), \(mac.lastError ?? "")")
        }
        accepted = build.descriptor
        let release = tmp.appendingPathComponent("Release-iphoneos/AcceptedDev.app")
        try FileManager.default.createDirectory(at: release.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: release)
        for url in [release, fixtures.appendingPathComponent("AdHocDist.app"), fixtures.appendingPathComponent("Expired.app"),
                    fixtures.appendingPathComponent("Unsigned.app")] {
            // 판정은 5단계에서 한다(브라우저에 보이는 목록과 함께).
            if case .rejected(let refused) = await mac.importBuild(url) {
                rejected.append(refused)
            } else {
                notRejected.append(url.lastPathComponent)
            }
        }
    }

    /// 거부되어야 했는데 거부되지 않은 픽스처 이름.
    private(set) var notRejected: [String] = []

    /// 다음 페어링 요청 하나가 Mac에 뜰 때까지 기다린다(이미 본 요청은 뺀다).
    func waitForPairRequest(excluding seen: Set<String>) async throws -> PairRequestEvent {
        var found: PairRequestEvent?
        try await until("\(Self.node)의 pair-request가 Mac에 온다", timeout: .seconds(30)) {
            found = mac.pendingPairRequests.first { $0.nodeName == Self.node && !seen.contains($0.requestId) }
            return found != nil
        }
        return found!
    }

    func hasDenied(path: String, reason: String) -> Bool {
        mac.activity.contains {
            if case .denied(let e) = $0.kind { e.path == path && e.reason == reason && e.nodeName == Self.node } else { false }
        }
    }

    func session(_ id: String) -> SessionEvent? {
        for item in mac.activity {
            if case .session(let e) = item.kind, e.sessionId == id { return e }
        }
        return nil
    }

    /// 성공·실패와 상관없이 부른다: 코어를 멈추고 하위 프로세스를 끝내고 로그를 옮긴다.
    func finish() async {
        guard !finished else { return }
        finished = true
        await mac.shutdown()
        try? forwarder.child.err.string.write(to: logs.appendingPathComponent("forward.err"), atomically: true, encoding: .utf8)
        try? control.child.err.string.write(to: logs.appendingPathComponent("control.err"), atomically: true, encoding: .utf8)
        try? FileManager.default.copyItem(at: paths.coreLogFile, to: logs.appendingPathComponent("core.log"))
        ChildRegistry.terminateAll()
    }

    var childrenRunning: Bool { control.child.isRunning || forwarder.child.isRunning }
}

/// 단계 하나의 확인. 실패는 XCTest 실패로 남기고 단계 결과에도 센다.
@MainActor
final class Step {
    let number: Int
    let title: String
    private(set) var failures: [String] = []
    private let report: StepReport

    fileprivate init(number: Int, title: String, report: StepReport) {
        self.number = number
        self.title = title
        self.report = report
    }

    var passed: Bool { failures.isEmpty }

    func fail(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        failures.append(text)
        report.write("W\(number) FAIL \(text) (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
        XCTFail("W\(number): \(text)", file: file, line: line)
    }

    func check(_ condition: Bool, _ what: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
        if condition {
            report.write("W\(number) ok   \(what())")
        } else {
            fail(what(), file: file, line: line)
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        if actual == expected {
            report.write("W\(number) ok   \(what)")
        } else {
            fail("\(what): 실제 \(String(describing: actual)), 기대 \(String(describing: expected))", file: file, line: line)
        }
    }
}

/// 단계별 결과를 파일에 남긴다. `results.txt`는 scripts/e2e-web.sh가 읽는다.
@MainActor
final class StepReport {
    struct Aborted: Error {}

    private let logURL: URL
    private let resultsURL: URL
    /// 단계가 끝날 때마다 부른다. 페이지가 스스로 보고한 문제(JS 오류·CSP 위반 등)를 돌려준다.
    var problemSource: () -> [String] = { [] }
    private var reportedProblems = 0

    init(directory: URL) {
        logURL = directory.appendingPathComponent("steps.log")
        resultsURL = directory.appendingPathComponent("results.txt")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        FileManager.default.createFile(atPath: resultsURL.path, contents: nil)
    }

    func write(_ line: String) { append(line, to: logURL) }

    private func append(_ line: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// 단계를 돌리고 결과를 기록한다. 던지면 뒤 단계(앞 단계의 상태에 기댄다)는 돌리지 않는다.
    func run(_ number: Int, _ title: String, _ body: (Step) async throws -> Void) async throws {
        let step = Step(number: number, title: title, report: self)
        write("W\(number) 시작: \(title)")
        var aborted = false
        do {
            try await body(step)
        } catch {
            aborted = true
            step.fail("중단: \(error)")
        }
        let problems = problemSource()
        if problems.count > reportedProblems {
            for problem in problems[reportedProblems...] { step.fail("페이지 문제: \(problem)") }
            reportedProblems = problems.count
        }
        if HardLimit.fired { step.fail("제한 시간을 넘겨 하네스가 하위 프로세스를 끝냈다") }
        let verdict = step.passed ? "PASS" : "FAIL"
        append("\(verdict) \(number) \(title)", to: resultsURL)
        print("e2e-web: \(verdict) W\(number) \(title)")
        for failure in step.failures { print("e2e-web:   \(failure)") }
        if aborted || (!step.passed && E2EEnv.failFast) { throw Aborted() }
    }
}
