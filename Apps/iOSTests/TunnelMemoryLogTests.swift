import Foundation
import Testing
@testable import RemoteDebug

@Suite struct TunnelMemoryLogTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func logsTheFirstSampleAndThenOnlyGrowthOrTheInterval() {
        var log = TunnelMemoryLog()
        #expect(log.sample(20.0, at: start) == "터널 메모리 20.0 MiB (연결 뒤 최저 20.0, 최고 20.0)")
        // 같은 수준과 작은 오르내림은 남기지 않는다.
        #expect(log.sample(20.4, at: start.addingTimeInterval(2)) == nil)
        #expect(log.sample(19.0, at: start.addingTimeInterval(4)) == nil)
        // 최고치가 1MiB 넘게 오르면 남긴다.
        #expect(log.sample(21.2, at: start.addingTimeInterval(6)) == "터널 메모리 21.2 MiB (연결 뒤 최저 19.0, 최고 21.2)")
        // 5분이 지나면 오르지 않아도 남긴다.
        #expect(log.sample(20.0, at: start.addingTimeInterval(299)) == nil)
        #expect(log.sample(20.0, at: start.addingTimeInterval(306)) == "터널 메모리 20.0 MiB (연결 뒤 최저 19.0, 최고 21.2)")
    }

    @Test func resetStartsOver() {
        var log = TunnelMemoryLog()
        _ = log.sample(30.0, at: start)
        log.reset()
        #expect(log.sample(12.0, at: start.addingTimeInterval(1)) == "터널 메모리 12.0 MiB (연결 뒤 최저 12.0, 최고 12.0)")
    }
}
