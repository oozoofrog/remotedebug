#if os(macOS)
import Dispatch
import Foundation

/// Security.framework 정적 코드 호출(`SecStaticCodeCreateWithPath`, `SecStaticCodeCheckValidity`,
/// `SecCodeCopySigningInformation`)을 프로세스 전체에서 하나뿐인 전용 직렬 DispatchQueue에서만 돌린다.
///
/// 왜: `SecStaticCodeCheckValidity`는 안에서 dispatch group을 기다린다. Swift 협력 스레드 풀의 스레드가 모두 이 호출에
/// 막히면 프로세스 전체가 교착한다(스레드 수만큼 동시에 검사하면 재현됨). 호출자 스레드에서 잠금만 잡는 방식으로는
/// 풀리지 않는다(잠금을 기다리는 협력 스레드가 여전히 풀을 채운다). 그래서 Security 호출은 협력 풀 밖의
/// 이 큐의 스레드에서만 실행한다.
///
/// - 동기 API(`sync`)는 큐에 작업을 넣고 세마포어로 기다린다. `DispatchQueue.sync`는 호출자 스레드에서 블록을
///   실행할 수 있어 쓰지 않는다. 이미 이 큐 위라면 그대로 실행한다(재진입 교착 방지).
/// - 비동기 API(`run`)는 checked continuation으로 기다려 협력 스레드를 막지 않는다.
enum SecurityGate {
    private static let key = DispatchSpecificKey<Bool>()

    static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "remotedebug.security-static-code", qos: .userInitiated)
        q.setSpecific(key: key, value: true)
        return q
    }()

    static var isOnGate: Bool { DispatchQueue.getSpecific(key: key) == true }

    /// 어느 스레드에서든 부를 수 있다. 호출자 스레드는 큐의 작업이 끝날 때까지 기다린다.
    /// `body`는 escaping이다: 세마포어 신호 뒤에도 dispatch 블록이 잠시 살아 있을 수 있어
    /// `withoutActuallyEscaping`을 쓰면 안 된다(런타임 검사에 걸림).
    static func sync<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        if isOnGate { return try body() }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        queue.async {
            box.result = Result { try body() }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    /// 협력 스레드를 막지 않고 큐에서 실행한 결과를 기다린다.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

/// 세마포어가 쓰기→읽기 순서를 보장한다.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, any Error>?
}
#endif
