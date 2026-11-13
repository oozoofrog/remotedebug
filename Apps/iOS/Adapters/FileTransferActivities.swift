@preconcurrency import ActivityKit
import Foundation
import PhoneClientKit
import UIKit
import UserNotifications

/// 파일 받기를 라이브 액티비티(잠금 화면, Dynamic Island)로 보여 준다.
///
/// 앱이 멈춰 있는 동안에는 iOS가 백그라운드에서 전송만 이어 가고 진행을 알려 주지 않는다.
/// 그래서 백그라운드로 간 뒤에는 마지막 진행에 머물다가, 전송이 끝나 iOS가 앱을 깨우면 완료·실패로 바뀐다.
@MainActor
final class FileTransferActivities {
    private var activities: [String: Activity<FileTransferAttributes>] = [:]
    private var startedAt: [String: Date] = [:]
    /// 백그라운드로 간 직후 잠시 더 진행을 갱신하려고 받는 시간.
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

    /// 앱이 다시 시작되기 전에 띄운 라이브 액티비티를 이어받는다.
    init() {
        for activity in Activity<FileTransferAttributes>.activities {
            let id = activity.attributes.resourceID
            if activities[id] == nil {
                activities[id] = activity
                startedAt[id] = activity.content.state.startedAt
            } else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    /// 이어받은 전송이 없는 라이브 액티비티를 끝낸다(앱이 종료된 사이에 전송이 사라졌다).
    func endStale(keeping active: Set<String>) {
        for (id, activity) in activities where !active.contains(id) && activity.content.state.phase == .receiving {
            activities[id] = nil
            startedAt[id] = nil
            var state = activity.content.state
            state.phase = .failed
            state.message = "앱이 다시 시작되어 받기가 끊겼습니다. 다시 받으세요."
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 5 * 60)) }
        }
    }

    func handle(_ update: FileTransferUpdate) {
        let id = update.resourceID
        let start = startedAt[id] ?? Date()
        startedAt[id] = start
        let phase: FileTransferAttributes.ContentState.Phase
        var message: String?
        switch update.phase {
        case .receiving: phase = .receiving
        case .received: phase = .received
        case .failed(let text):
            phase = .failed
            message = text
        case .cancelled: phase = .cancelled
        }
        let state = FileTransferAttributes.ContentState(received: update.progress.received, total: update.progress.total,
                                                        phase: phase, message: message, startedAt: start)
        let content = ActivityContent(state: state, staleDate: nil)

        if phase == .receiving {
            beginBackgroundTime(id)
            if let activity = activities[id] {
                Task { await activity.update(content) }
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                let attributes = FileTransferAttributes(resourceID: id, name: update.name, total: update.progress.total)
                activities[id] = try? Activity.request(attributes: attributes, content: content, pushType: nil)
            }
            return
        }
        endBackgroundTime(id)
        startedAt[id] = nil
        guard let activity = activities.removeValue(forKey: id) else { return }
        // 끝난 상태는 잠시 보여 준 뒤 내린다.
        let dismissal: ActivityUIDismissalPolicy = phase == .cancelled ? .immediate : .after(.now + 15 * 60)
        Task { await activity.end(content, dismissalPolicy: dismissal) }
    }

    private func beginBackgroundTime(_ id: String) {
        guard backgroundTasks[id] == nil else { return }
        backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "file-\(id)") { [weak self] in
            Task { @MainActor in self?.endBackgroundTime(id) }
        }
    }

    private func endBackgroundTime(_ id: String) {
        guard let task = backgroundTasks.removeValue(forKey: id) else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// 백그라운드 다운로드가 끝나 iOS가 앱을 깨울 때 받는 쪽. 원격 알림 등록 결과도 여기로 온다.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 알림을 눌러 앱이 시작된 경우에도 받도록 시작이 끝나기 전에 대리자를 둔다.
        UNUserNotificationCenter.current().delegate = PushNotifications.shared
        PushNotifications.shared.registerCategories()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.receive(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushNotifications.shared.registrationFailed(error)
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        let completion = UncheckedCompletion(run: completionHandler)
        if !FileDownloader.shared.handleBackgroundEvents(identifier: identifier, completion: { completion.run() }) {
            completionHandler()
        }
    }
}

private struct UncheckedCompletion: @unchecked Sendable {
    let run: () -> Void
}
