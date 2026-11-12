import Foundation

/// 큰 파일을 시스템 백그라운드 세션으로 받는다. 앱이 백그라운드로 가거나 멈춰도 iOS가 전송을 이어 가고,
/// 끝나면 앱을 깨워 결과를 넘긴다. 실패하거나 취소하면 이어받기 데이터를 남겨 다음 요청에서 이어 받는다.
///
/// 백그라운드 세션은 같은 식별자로 프로세스에 하나만 만들 수 있어 `shared`만 쓴다.
/// 앱이 종료된 뒤 iOS가 앱을 다시 띄워 넘겨주는 전송(받을 쪽이 없는 전송)은 `attach`로 받은 처리기에 넘긴다.
/// 처리기가 붙기 전에 끝난 전송은 모아 두었다가 붙을 때 넘긴다.
public final class FileDownloader: NSObject, @unchecked Sendable {
    public static let identifier = "com.oozoofrog.app.RemoteDebugPhone.files"
    public static let shared = FileDownloader()

    public typealias Progress = @Sendable (_ received: Int64, _ expected: Int64) -> Void

    /// 앱을 다시 띄운 뒤 넘겨받은 전송의 소식. `context`는 받기를 시작할 때 넘긴 값이다.
    public enum OrphanEvent: @unchecked Sendable {
        case progress(key: String, context: Data?, received: Int64, expected: Int64)
        case finished(key: String, context: Data?, result: Result<(URL, HTTPURLResponse), any Error>)
    }

    /// 진행 중인 전송 하나.
    public struct Transfer: Sendable {
        public var key: String
        public var context: Data?
        public var received: Int64
        public var expected: Int64
    }

    private struct Description: Codable {
        var key: String
        var context: Data?
    }

    private var orphanHandler: (@Sendable (OrphanEvent) -> Void)?
    private var pendingOrphans: [OrphanEvent] = []

    private struct Waiter {
        var key: String
        var continuation: CheckedContinuation<(URL, HTTPURLResponse), any Error>
        var progress: Progress
        var file: URL?
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]
    /// 받을 쪽이 없는 전송이 내려받은 파일(완료 알림까지 둔다).
    private var orphanFiles: [Int: URL] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private var backgroundCompletion: (@Sendable () -> Void)?
    private var _session: URLSession?

    private var session: URLSession {
        lock.withLock {
            if let _session { return _session }
            let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
            config.sessionSendsLaunchEvents = true
            config.isDiscretionary = false
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 6 * 60 * 60
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let made = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            _session = made
            return made
        }
    }

    /// `key`는 받는 대상의 이름(파일 id)이다. 같은 `key`의 이어받기 데이터가 있으면 이어 받는다.
    public func download(_ request: URLRequest, key: String, context: Data? = nil, progress: @escaping Progress) async throws -> (URL, HTTPURLResponse) {
        let session = self.session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    let task = resumeData.removeValue(forKey: key).map { session.downloadTask(withResumeData: $0) }
                        ?? session.downloadTask(with: request)
                    task.taskDescription = Self.describe(key: key, context: context)
                    waiters[task.taskIdentifier] = Waiter(key: key, continuation: continuation, progress: progress)
                    tasks[key] = task
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel(key: key)
        }
    }

    /// 받는 중인 전송을 멈춘다. 이어받기 데이터를 남긴다.
    public func cancel(key: String) {
        let task = lock.withLock { tasks[key] }
        task?.cancel { [weak self] data in
            guard let self, let data else { return }
            self.lock.withLock { self.resumeData[key] = data }
        }
    }

    /// 이 키의 이어받기 데이터를 버린다(목록에서 파일이 바뀌었을 때).
    public func discardResumeData(key: String) {
        lock.withLock { _ = resumeData.removeValue(forKey: key) }
    }

    public func hasResumeData(key: String) -> Bool {
        lock.withLock { resumeData[key] != nil }
    }

    /// 받을 쪽이 없는 전송(앱을 다시 띄운 뒤 넘겨받은 전송)을 처리할 곳을 붙이고, 지금 진행 중인 전송을 돌려준다.
    public func attach(_ handler: @escaping @Sendable (OrphanEvent) -> Void) async -> [Transfer] {
        let queued = lock.withLock { () -> [OrphanEvent] in
            orphanHandler = handler
            defer { pendingOrphans = [] }
            return pendingOrphans
        }
        queued.forEach(handler)
        let tasks = await session.allTasks
        return tasks.compactMap { task -> Transfer? in
            guard task.state == .running || task.state == .suspended, let d = Self.parse(task.taskDescription) else { return nil }
            return Transfer(key: d.key, context: d.context, received: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive)
        }
    }

    private static func describe(key: String, context: Data?) -> String {
        (try? String(decoding: JSONEncoder().encode(Description(key: key, context: context)), as: UTF8.self)) ?? key
    }

    private static func parse(_ text: String?) -> Description? {
        guard let text else { return nil }
        return (try? JSONDecoder().decode(Description.self, from: Data(text.utf8))) ?? Description(key: text, context: nil)
    }

    private func deliverOrphan(_ event: OrphanEvent) {
        let handler = lock.withLock { () -> (@Sendable (OrphanEvent) -> Void)? in
            if orphanHandler == nil { pendingOrphans.append(event) }
            return orphanHandler
        }
        handler?(event)
    }

    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`에서 부른다.
    /// 이 세션의 식별자면 완료 처리기를 맡고 `true`를 돌려준다.
    public func handleBackgroundEvents(identifier: String, completion: @escaping @Sendable () -> Void) -> Bool {
        guard identifier == Self.identifier else { return false }
        lock.withLock { backgroundCompletion = completion }
        _ = session
        return true
    }
}

extension FileDownloader: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = lock.withLock { waiters[downloadTask.taskIdentifier]?.progress }
        if let progress {
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        } else if let d = Self.parse(downloadTask.taskDescription) {
            deliverOrphan(.progress(key: d.key, context: d.context, received: totalBytesWritten, expected: totalBytesExpectedToWrite))
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 이 메서드가 끝나면 시스템이 파일을 지우므로 바로 옮긴다.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("rd-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
        } catch {
            return
        }
        lock.withLock {
            if waiters[downloadTask.taskIdentifier] != nil {
                waiters[downloadTask.taskIdentifier]?.file = kept
            } else {
                orphanFiles[downloadTask.taskIdentifier] = kept
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let description = Self.parse(task.taskDescription)
        let (waiter, orphanFile) = lock.withLock { () -> (Waiter?, URL?) in
            let waiter = waiters.removeValue(forKey: task.taskIdentifier)
            if let key = waiter?.key ?? description?.key, tasks[key] === task { tasks[key] = nil }
            if let error, let key = description?.key,
               let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                resumeData[key] = data
            }
            return (waiter, orphanFiles.removeValue(forKey: task.taskIdentifier))
        }
        guard let waiter else {
            guard let description else {
                if let orphanFile { try? FileManager.default.removeItem(at: orphanFile) }
                return
            }
            let result: Result<(URL, HTTPURLResponse), any Error>
            if let error {
                if let orphanFile { try? FileManager.default.removeItem(at: orphanFile) }
                result = .failure((error as? URLError)?.code == .cancelled ? CancellationError() : error)
            } else if let orphanFile, let response = task.response as? HTTPURLResponse {
                result = .success((orphanFile, response))
            } else {
                if let orphanFile { try? FileManager.default.removeItem(at: orphanFile) }
                result = .failure(URLError(.badServerResponse))
            }
            deliverOrphan(.finished(key: description.key, context: description.context, result: result))
            return
        }
        if let error {
            if let file = waiter.file { try? FileManager.default.removeItem(at: file) }
            if (error as? URLError)?.code == .cancelled {
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                waiter.continuation.resume(throwing: error)
            }
            return
        }
        guard let file = waiter.file, let response = task.response as? HTTPURLResponse else {
            if let file = waiter.file { try? FileManager.default.removeItem(at: file) }
            waiter.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        waiter.continuation.resume(returning: (file, response))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        guard let completion else { return }
        DispatchQueue.main.async { completion() }
    }
}
