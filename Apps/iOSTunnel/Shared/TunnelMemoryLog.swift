import Foundation

/// 터널 확장의 메모리 사용량(phys_footprint)을 언제 기록으로 남길지 정한다. 부작용이 없다.
///
/// 상태 요청은 2초마다 오지만 기록은 연결한 뒤 첫 값, 최고치가 1MiB 넘게 올랐을 때, 5분마다만 남긴다.
struct TunnelMemoryLog {
    static let step = 1.0
    static let interval: TimeInterval = 300

    private(set) var minimum: Double?
    private(set) var maximum: Double?
    private var loggedMaximum: Double?
    private var lastLog: Date?

    /// 연결이 끊기면 처음부터 다시 센다.
    mutating func reset() {
        self = TunnelMemoryLog()
    }

    /// 값 하나를 받아, 남길 기록이 있으면 그 문장을 돌려준다.
    mutating func sample(_ mib: Double, at now: Date) -> String? {
        minimum = min(minimum ?? mib, mib)
        maximum = max(maximum ?? mib, mib)
        guard let low = minimum, let high = maximum else { return nil }
        let first = lastLog == nil
        let grew = loggedMaximum.map { high >= $0 + Self.step } ?? true
        let due = lastLog.map { now.timeIntervalSince($0) >= Self.interval } ?? true
        guard first || grew || due else { return nil }
        loggedMaximum = high
        lastLog = now
        return String(format: "터널 메모리 %.1f MiB (연결 뒤 최저 %.1f, 최고 %.1f)", mib, low, high)
    }
}
