import Foundation
import MetricKit
import RDModels

/// 이 앱 자신의 크래시를 MetricKit에서 받아 크래시 기록으로 넘긴다. iOS는 크래시 뒤 다음 실행 때 알려 준다.
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let deliver: @Sendable (CrashReport) async -> Void

    init(deliver: @escaping @Sendable (CrashReport) async -> Void) {
        self.deliver = deliver
    }

    func start() {
        MXMetricManager.shared.add(self)
        handle(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        handle(payloads)
    }

    private func handle(_ payloads: [MXDiagnosticPayload]) {
        var reports: [CrashReport] = []
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let raw = crash.jsonRepresentation()
                let pretty = (try? JSONSerialization.jsonObject(with: raw))
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) } ?? raw
                let stamp = payload.timeStampEnd.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().time(includingFractionalSeconds: false))
                    .replacingOccurrences(of: ":", with: "")
                reports.append(CrashReport(
                    kind: .metrickit,
                    name: "RemoteDebug-\(stamp).json",
                    bundleId: Bundle.main.bundleIdentifier ?? "",
                    appVersion: "\(crash.applicationVersion) (\(crash.metaData.applicationBuildVersion))",
                    crashedAt: payload.timeStampEnd,
                    text: String(decoding: pretty, as: UTF8.self)))
            }
        }
        guard !reports.isEmpty else { return }
        let deliver = self.deliver
        Task { for report in reports { await deliver(report) } }
    }
}
