#if os(macOS)
import Dispatch
import Foundation
import Synchronization

/// 긴 동기 작업(묶기·풀기·해시)의 진행 상황.
public struct ArchiveProgress: Sendable, Hashable {
    /// 지금까지 읽거나 쓴 원본(압축 전) 바이트 수.
    public var completedBytes: Int64
    /// 전체 바이트 수(작업 시작 때 계산한 값).
    public var totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 1 }
}

/// 동기 작업의 취소 확인과 진행 보고.
///
/// 작업은 청크(1 MiB)와 항목 경계마다 `check()`를 부른다. `Task.isCancelled`(비동기 문맥에서 직접 호출했을 때)나
/// `shouldContinue()`가 false이면 `CancellationError`를 던지고, 작업이 만든 임시 파일은 지운다.
public struct OperationControl: Sendable {
    public var shouldContinue: @Sendable () -> Bool
    public var progress: (@Sendable (ArchiveProgress) -> Void)?

    public init(shouldContinue: @escaping @Sendable () -> Bool = { true }, progress: (@Sendable (ArchiveProgress) -> Void)? = nil) {
        self.shouldContinue = shouldContinue
        self.progress = progress
    }

    /// 현재 태스크의 취소만 확인한다(동기 함수를 비동기 문맥에서 바로 부르면 그 태스크의 취소가 보인다).
    public static let `default` = OperationControl()

    /// 취소됐으면 `CancellationError`를 던진다.
    public func check() throws {
        if Task.isCancelled || !shouldContinue() { throw CancellationError() }
    }
}

/// 진행 바이트를 모아 `OperationControl.progress`로 보내고 청크마다 취소를 확인한다.
final class ProgressMeter {
    private let control: OperationControl
    private let total: Int64
    private var done: Int64 = 0

    init(_ control: OperationControl, total: Int64) {
        self.control = control
        self.total = total
    }

    func advance(_ bytes: Int) throws {
        done += Int64(bytes)
        control.progress?(ArchiveProgress(completedBytes: done, totalBytes: total))
        try control.check()
    }

    func check() throws { try control.check() }
}

/// 비동기 래퍼가 블로킹 I/O를 협력 스레드 풀 밖(전용 동시 큐)에서 돌리게 한다.
/// 태스크가 취소되면 `OperationControl.shouldContinue`가 false가 되어 작업이 다음 청크 경계에서 멈춘다.
package enum BlockingWork {
    package static let queue = DispatchQueue(label: "remotedebug.blocking-io", qos: .userInitiated, attributes: .concurrent)

    /// `cancellable`이 false이면(정리 작업 등) 이미 취소된 태스크에서도 끝까지 실행한다.
    package static func run<T: Sendable>(
        on queue: DispatchQueue = BlockingWork.queue,
        cancellable: Bool = true,
        progress: (@Sendable (ArchiveProgress) -> Void)? = nil,
        _ body: @escaping @Sendable (OperationControl) throws -> T
    ) async throws -> T {
        if !cancellable {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async { continuation.resume(with: Result { try body(OperationControl(progress: progress)) }) }
            }
        }
        try Task.checkCancellation()
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async {
                    let control = OperationControl(shouldContinue: { !flag.isSet }, progress: progress)
                    continuation.resume(with: Result { try body(control) })
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}

package final class CancelFlag: Sendable {
    private let state = Mutex(false)

    package init() {}

    package var isSet: Bool { state.withLock { $0 } }
    package func set() { state.withLock { $0 = true } }
}
#endif
