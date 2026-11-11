import Foundation

/// 앱 종료 순서. 첫 요청만 정리를 시작하고, 정리가 끝날 때까지 나중 요청은 모두 기다리게 한다.
@MainActor
public final class TerminationSequence {
    public enum Phase: Sendable, Hashable {
        case idle
        case shuttingDown
        case finished
    }

    public enum Answer: Sendable, Hashable {
        /// 정리가 끝났다. 바로 끝내도 된다.
        case now
        /// 정리가 진행 중이다. `finish`가 불릴 때까지 끝내면 안 된다.
        case later
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    /// `shutdown`과 `finish`는 첫 요청의 것만 쓴다. `finish`는 `shutdown`이 끝난 뒤 한 번 불린다.
    public func request(
        shutdown: @escaping @MainActor () async -> Void,
        finish: @escaping @MainActor () -> Void
    ) -> Answer {
        switch phase {
        case .finished:
            return .now
        case .shuttingDown:
            return .later
        case .idle:
            phase = .shuttingDown
            Task { @MainActor in
                await shutdown()
                self.phase = .finished
                finish()
            }
            return .later
        }
    }
}
