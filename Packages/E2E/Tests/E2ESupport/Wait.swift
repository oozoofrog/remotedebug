import Foundation

/// 조건이 참이 될 때까지 기다린다. 시간을 넘기면 던진다(하네스 실패가 ‘조용함’으로 보이면 안 된다).
@MainActor
public func until(_ what: String, timeout: Duration = .seconds(30), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    if await condition() { return }
    throw E2EError("시간 안에 일어나지 않았다: \(what)")
}
