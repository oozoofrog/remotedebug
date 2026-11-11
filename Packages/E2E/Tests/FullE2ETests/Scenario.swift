import Foundation
import Testing

/// 시나리오 하나의 확인. 실패는 Swift Testing 이슈로 남기고 시나리오 결과에도 센다.
@MainActor
final class Scenario {
    let number: Int
    let title: String
    private(set) var failures: [String] = []
    private let report: ScenarioReport

    fileprivate init(number: Int, title: String, report: ScenarioReport) {
        self.number = number
        self.title = title
        self.report = report
    }

    var passed: Bool { failures.isEmpty }

    func fail(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        failures.append(text)
        report.write("S\(number) FAIL \(text) (\(sourceLocation.fileName):\(sourceLocation.line))")
        Issue.record(Comment(rawValue: "S\(number): \(text)"), sourceLocation: sourceLocation)
    }

    func check(_ condition: Bool, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if condition {
            report.write("S\(number) ok   \(what)")
        } else {
            fail(what, sourceLocation: sourceLocation)
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if actual == expected {
            report.write("S\(number) ok   \(what)")
        } else {
            fail("\(what): 실제 \(String(describing: actual)), 기대 \(String(describing: expected))", sourceLocation: sourceLocation)
        }
    }

    /// 호스트 응답 하나의 상태 코드·오류 코드·공통 헤더(protocol §4 `X-RD-Protocol`, §8 오류 형식).
    func response(_ exchange: Exchange?, status: Int, code: String? = nil, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let exchange else {
            fail("\(what): 요청 기록이 없다", sourceLocation: sourceLocation)
            return
        }
        equal(exchange.status, status, "\(what) HTTP 상태", sourceLocation: sourceLocation)
        equal(exchange.header("X-RD-Protocol"), "1", "\(what) X-RD-Protocol", sourceLocation: sourceLocation)
        if let code {
            equal(exchange.errorCode, code, "\(what) 오류 코드", sourceLocation: sourceLocation)
            equal(exchange.json.map { Set($0.keys) }, ["error"], "\(what) 오류 본문 키", sourceLocation: sourceLocation)
            let detail = exchange.json?["error"] as? [String: Any]
            equal(detail.map { Set($0.keys) }, ["code", "message"], "\(what) error 안의 키", sourceLocation: sourceLocation)
            check((detail?["message"] as? String)?.isEmpty == false, "\(what) 오류 메시지가 있다", sourceLocation: sourceLocation)
        }
    }

    /// JSON 키가 문서의 키와 정확히 같은지(디코더는 모르는 키를 무시하고 선택 키가 빠져도 지나간다).
    func keys(_ object: [String: Any]?, _ expected: Set<String>, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        equal(object.map { Set($0.keys) }, expected, "\(what) 키", sourceLocation: sourceLocation)
    }

    /// 시각 문자열이 UTC ISO-8601(`Z`)인지(protocol 머리말).
    func utcTimestamp(_ value: Any?, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let text = value as? String ?? ""
        check(text.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z/) != nil, "\(what) UTC ISO-8601: \(text)", sourceLocation: sourceLocation)
    }
}

/// 시나리오별 결과를 파일에 남긴다. `results.txt`는 scripts/e2e-full.sh가 읽는다.
@MainActor
final class ScenarioReport {
    struct Aborted: Error {}

    private let logURL: URL
    private let resultsURL: URL
    private(set) var failed = 0

    init(directory: URL) {
        logURL = directory.appendingPathComponent("scenarios.log")
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

    /// 시나리오를 돌리고 결과를 기록한다. 던지면 앞 시나리오의 상태에 기대는 뒤 시나리오는 돌리지 않는다.
    func run(_ number: Int, _ title: String, _ body: (Scenario) async throws -> Void) async throws {
        let scenario = Scenario(number: number, title: title, report: self)
        write("S\(number) 시작: \(title)")
        var aborted = false
        do {
            try await body(scenario)
        } catch {
            aborted = true
            scenario.fail("중단: \(error)")
        }
        if HardLimit.fired { scenario.fail("제한 시간을 넘겨 하네스가 하위 프로세스를 끝냈다") }
        let verdict = scenario.passed ? "PASS" : "FAIL"
        if !scenario.passed { failed += 1 }
        append("\(verdict) \(number) \(title)", to: resultsURL)
        print("e2e-full: \(verdict) S\(number) \(title)")
        for failure in scenario.failures { print("e2e-full:   \(failure)") }
        if aborted || (!scenario.passed && E2EEnv.failFast) { throw Aborted() }
    }
}
