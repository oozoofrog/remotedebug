import Darwin
import Foundation
import Swiftail
import SwiftailCertificates
import SwiftailControl
import SwiftailHostServer
import Synchronization

/// Swiftail 관문 (나)용 HTTPS 파일 서버. 출력은 시간·개수·상태 이름뿐이다: FQDN, tailnet 이름, 주소, 키, 로그인 이름,
/// 로그인 URL은 찍지 않는다. 로그인 URL과 서명 명령은 상태 폴더의 0600 파일에 쓴다.
@main
struct RDSwiftailHost {
    static func main() async {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            fail("\(error)", code: 64)
        }

        // 상태 폴더를 만들기 전에 거절한다.
        let certificates: CertificateConfiguration
        do {
            certificates = try CertificateTrust.configuration(for: options)
        } catch {
            fail("\(error)", code: 78)
        }

        do {
            try prepareStateDirectory(options.stateDirectory)
        } catch {
            fail("상태 폴더를 만들지 못함: \(error.localizedDescription)", code: 73)
        }
        var authKey: String?
        if let file = options.authKeyFile {
            do {
                authKey = try readAuthKey(file)
            } catch {
                fail("\(error)", code: 66)
            }
        }

        var node = NodeConfiguration(stateDirectory: options.stateDirectory, hostname: options.hostname, authKey: authKey)
        if let control = options.controlURL { node.controlURL = control }
        let configuration = HostConfiguration(node: node, certificates: certificates)

        let reporter = GateReporter(stateDirectory: options.stateDirectory)
        let handler = StaticContentHandler(content: ServedContent(filePath: options.filePath, app: options.app)) {
            reporter.handle(response: $0)
        }
        reporter.line(options.isProduction ? "ACME: Let's Encrypt 운영"
            : options.acmeDirectory == Options.stagingDirectoryURL ? "ACME: Let's Encrypt 스테이징" : "ACME: 지정한 디렉터리")
        reporter.line("내보냄: /\(options.filePath == nil ? "" : ", /file")\(options.app == nil ? "" : ", /manifest.plist, /app.ipa")"
            + (authKey == nil ? ". 인증 키 없음(상태 폴더의 신원으로 붙는다)" : ""))

        let runtime: SwiftailHostRuntime
        do {
            runtime = try SwiftailHostRuntime(configuration: configuration, handler: handler) { event in
                if case .certificate(let domain, _, _, _) = event { handler.domain = domain }
                reporter.handle(event)
            }
        } catch {
            fail("설정 오류: \(describe(error))", code: 78)
        }
        let task = Task { try await runtime.run() }
        let sources = installInterruptHandlers(task: task, reporter: reporter)

        // 취소 뒤 `run()`은 노드와 인증서 관리자가 끝난 뒤에 돌아온다. 그 뒤라면 부르는 쪽이 `logOut()`을 부를 수 있다.
        let result = await task.result
        for source in sources { source.cancel() }
        switch result {
        case .success:
            reporter.line("끝: 정상 종료(\(reporter.elapsed()))")
            exit(0)
        case .failure(let error):
            reporter.line("끝: 실패 \(describe(error))")
            exit(1)
        }
    }

    /// SIGINT·SIGTERM: 처음은 `run()`을 취소하고 끝나기를 기다린다. 두 번째는 곧바로 끝낸다.
    ///
    /// `main()`은 main actor라서 거기서 만든 처리기는 main actor로 추론되고, 다른 큐에서 불리면 격리 검사가 프로세스를
    /// 멈춘다. 그래서 격리 없는 함수에서 `@Sendable` 처리기로 만든다.
    nonisolated static func installInterruptHandlers(task: Task<Void, any Error>, reporter: GateReporter) -> [any DispatchSourceSignal] {
        let interrupts = InterruptCounter()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let queue = DispatchQueue(label: "rd-swiftail-host.signals")
        let sources = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: queue) }
        for source in sources {
            source.setEventHandler { @Sendable in
                if interrupts.increment() == 1 {
                    reporter.line("멈추는 중: 노드와 인증서 관리자가 끝나기를 기다린다(한 번 더 누르면 곧바로 끝낸다)")
                    task.cancel()
                } else {
                    reporter.line("곧바로 끝낸다")
                    exit(130)
                }
            }
            source.resume()
        }
        return sources
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    /// 없으면 0700으로 만든다. 있으면 그대로 쓴다(지우거나 권한을 바꾸지 않는다).
    static func prepareStateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    enum AuthKeyError: Error, CustomStringConvertible {
        case unreadable
        case empty
        var description: String {
            switch self {
            case .unreadable: "인증 키 파일을 읽지 못함"
            case .empty: "인증 키 파일이 비었다"
            }
        }
    }

    static func readAuthKey(_ url: URL) throws(AuthKeyError) -> String {
        guard let data = try? Data(contentsOf: url), data.count <= 4_096 else { throw .unreadable }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw .empty }
        return key
    }

    /// 오류의 종류만. 연관 문자열은 Swiftail이 키·경로를 넣지 않지만 여기서도 종류 이름까지만 찍는다.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as NodeError:
            switch error {
            case .control(let control): "NodeError.control(\(caseName(control)))"
            case .invalidConfiguration: "NodeError.invalidConfiguration"
            case .udpUnavailable: "NodeError.udpUnavailable"
            case .stateDirectoryInUse: "NodeError.stateDirectoryInUse"
            case .tunnelDeviceClosed: "NodeError.tunnelDeviceClosed"
            }
        case let error as CertificateError: "CertificateError.\(caseName(error))"
        default: "\(type(of: error)).\(caseName(error))"
        }
    }

    /// enum 값의 case 이름(연관 값 없이).
    static func caseName(_ value: Any) -> String {
        let text = "\(value)"
        return String(text.prefix { $0 != "(" })
    }
}

final class InterruptCounter: Sendable {
    private let count = Mutex(0)

    func increment() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}

/// 사건을 관문에 쓸 줄로 바꾼다. 시간은 프로세스 시작부터다.
final class GateReporter: Sendable {
    private struct State {
        var runningAt: ContinuousClock.Instant?
        var firstCertificateAt: ContinuousClock.Instant?
        var certificateCount = 0
        var connections = 0
    }

    private let started = ContinuousClock.now
    private let stateDirectory: URL
    private let state = Mutex(State())

    init(stateDirectory: URL) { self.stateDirectory = stateDirectory }

    func line(_ text: String) {
        FileHandle.standardOutput.write(Data(("[\(elapsed())] " + text + "\n").utf8))
    }

    func elapsed(since instant: ContinuousClock.Instant? = nil) -> String {
        let duration = (instant ?? started).duration(to: .now)
        return String(format: "%.1f초", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    func handle(_ event: HostEvent) {
        switch event {
        case .nodeState(let nodeState):
            switch nodeState {
            case .starting:
                line("노드: starting")
            case .needsLogin(let url):
                // URL은 로그인 권한이다. 화면에 찍지 않고 0600 파일로만 넘긴다.
                let written = writePrivate("login-url.txt", url.absoluteString + "\n")
                line("노드: needsLogin. 인증 키가 받아들여지지 않았거나 없다." + (written ? " 로그인 URL은 상태 폴더의 login-url.txt에 있다" : " 로그인 URL을 파일에 쓰지 못했다"))
            case .needsMachineAuth:
                line("노드: needsMachineAuth. 관리 콘솔에서 기기를 승인해야 한다")
            case .running:
                state.withLock { $0.runningAt = $0.runningAt ?? .now }
            }
        case .running(let peerCount, let inDomains):
            line("노드: running (시작부터 \(elapsed()), 피어 \(peerCount)명, cert 도메인에 자기 이름 \(inDomains ? "있음" : "없음"))")
        case .tailnetLock(let lock):
            if let request = lock.signingRequest {
                let written = writePrivate("sign-command.txt", "tailscale lock sign \(request.nodeKey) \(request.lockKey)\n")
                line("tailnet lock: 서명이 필요하다." + (written ? " 명령은 상태 폴더의 sign-command.txt에 있다" : " 명령을 파일에 쓰지 못했다"))
            } else {
                line("tailnet lock: mode \(lock.mode), 거른 피어 \(lock.filteredPeerCount)명\(lock.issue.map { ", issue \($0)" } ?? "")")
            }
        case .certificate(_, let notBefore, let notAfter, let chainCount):
            let (first, sinceRunning) = state.withLock { value -> (Bool, ContinuousClock.Instant?) in
                value.certificateCount += 1
                let first = value.firstCertificateAt == nil
                if first { value.firstCertificateAt = .now }
                return (first, value.runningAt)
            }
            let lifetime = String(format: "%.2f일", notAfter.timeIntervalSince(notBefore) / 86_400)
            let remaining = String(format: "%.2f일", notAfter.timeIntervalSinceNow / 86_400)
            line("인증서: \(first ? "첫 인증서" : "새 인증서") (시작부터 \(elapsed())\(sinceRunning.map { ", running부터 \(elapsed(since: $0))" } ?? ""), 수명 \(lifetime), 남은 기간 \(remaining), 사슬 \(chainCount)장)")
        case .certificateStatus(let status):
            var parts: [String] = []
            if let failure = status.lastFailure { parts.append("마지막 실패 \(Self.name(failure))") }
            if let next = status.nextAttempt { parts.append(String(format: "다음 시도 %.0f초 뒤", next.timeIntervalSinceNow)) }
            if let notAfter = status.notAfter { parts.append(String(format: "쥔 인증서 만료까지 %.2f일", notAfter.timeIntervalSinceNow / 86_400)) }
            line("인증서 상태: \(parts.isEmpty ? "실패 없음" : parts.joined(separator: ", "))")
        case .serverFailed(let kind):
            line("서버: TLS 리스너를 띄우지 못함(\(kind))")
        case .serverStarted:
            line("서버: 루프백 리스너가 섰다(tailnet 443 → 루프백)")
        case .listening(let port):
            line("tailnet: \(port) 포트를 듣는다")
        case .defaultInterface(let name):
            line("기본 인터페이스: \(name)")
        case .connection(let origin):
            let count = state.withLock { value -> Int in
                value.connections += 1
                return value.connections
            }
            if case .tailnet(let peer) = origin { line("연결 \(count): 피어 \(peer.stableID)") } else { line("연결 \(count)") }
        case .connectionRejected:
            line("연결: 다리를 거치지 않았거나 준비 전에 끝난 연결을 끊음")
        }
    }

    func handle(response record: ResponseRecord) {
        let route = record.route?.rawValue ?? "(경로 표에 없음)"
        var text = "응답: \(record.method) \(route) \(record.status), 본문 \(record.bodyBytes)바이트, \(String(format: "%.3f초", record.seconds))"
        if record.route == .file || record.route == .ipa, record.seconds > 0 {
            text += String(format: ", %.2f MiB/s", Double(record.bodyBytes) / 1_048_576 / record.seconds)
        }
        text += record.completed ? ", 다 보냄" : ", 도중에 끊김"
        line(text)
    }

    /// 상태 폴더에 0600 파일을 쓴다. 링크를 따라가지 않는다.
    private func writePrivate(_ name: String, _ contents: String) -> Bool {
        let path = stateDirectory.appending(path: name).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { return false }
        let bytes = Array(contents.utf8)
        return bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count
    }

    /// 실패의 종류만(연관 문자열은 찍지 않는다).
    static func name(_ failure: CertificateFailure) -> String {
        switch failure {
        case .nodeNotRunning: "nodeNotRunning"
        case .magicDNSDisabled: "magicDNSDisabled"
        case .httpsNotEnabled: "httpsNotEnabled"
        case .domainNotAllowed: "domainNotAllowed"
        case .controlRejected(let status): "controlRejected(\(status))"
        case .acme(let status, let type): "acme(\(status), \(type.isEmpty ? "-" : type))"
        case .rateLimited(let retryAfter): "rateLimited(\(retryAfter.map { String(format: "%.0f초 뒤", $0.timeIntervalSinceNow) } ?? "-"))"
        case .validationFailed(let type): "validationFailed(\(type.isEmpty ? "-" : type))"
        case .orderFailed(let type): "orderFailed(\(type.isEmpty ? "-" : type))"
        case .unexpectedResponse: "unexpectedResponse"
        case .invalidCertificate: "invalidCertificate"
        case .network: "network"
        case .timedOut: "timedOut"
        }
    }
}
