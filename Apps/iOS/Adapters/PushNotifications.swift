import Observation
import PhoneClientKit
import UIKit
import UserNotifications

/// 새 빌드·파일 알림(docs/protocol-addenda.md P)의 iOS 쪽: 권한, 원격 알림 등록, 알림 대리자.
///
/// 앱 대리자가 받은 기기 토큰과 알림을 누른 목적지를 들고 있다가, 화면과 모델이 준비되면 넘긴다
/// (앱이 꺼진 상태에서 알림을 눌러 시작하면 화면보다 먼저 온다).
@MainActor
@Observable
final class PushNotifications: NSObject {
    static let shared = PushNotifications()

    /// 알림을 눌러 가야 할 곳. 화면이 받아 처리하면 `nil`로 돌린다.
    var pendingTarget: PushTarget?
    /// 받은 기기 토큰(16진수). 받는 쪽이 정해지기 전에 오면 들고 있다.
    @ObservationIgnored private var pendingToken: String?
    /// 기기 토큰을 받을 곳(모델).
    @ObservationIgnored var onToken: (@MainActor (String) -> Void)? {
        didSet { deliverToken() }
    }
    /// 앱이 앞에 있을 때 알림이 왔다.
    @ObservationIgnored var onForeground: (@MainActor () -> Void)?
    /// 진단 로그에 남길 줄.
    @ObservationIgnored var onLog: (@MainActor (String) -> Void)?

    /// 알림 권한을 묻는다. 이미 정해졌으면 묻지 않고 그 값을 돌려준다. 허용(임시 허용 포함)이면 `true`.
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    /// 권한을 묻지 않고 지금 허용돼 있는지만 본다.
    func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// 사용자가 iOS 설정에서 알림을 거부했다.
    func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// iOS에 원격 알림 등록을 요청한다. 토큰은 앱 대리자로 온다(앱을 시작할 때마다 바뀔 수 있다).
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// 앱 대리자가 받은 기기 토큰.
    func receive(deviceToken: Data) {
        pendingToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        deliverToken()
    }

    /// iOS가 원격 알림 등록에 실패했다(시뮬레이터, 프로비저닝에 알림 권한이 없음 등). 진단 로그에만 남긴다.
    func registrationFailed(_ error: any Error) {
        onLog?("원격 알림 등록 실패: \(error.localizedDescription)")
    }

    private func deliverToken() {
        guard let token = pendingToken, let onToken else { return }
        pendingToken = nil
        onToken(token)
    }

    fileprivate func open(_ target: PushTarget) {
        pendingTarget = target
    }

    fileprivate func arrivedInForeground() {
        onForeground?()
    }
}

extension PushNotifications: UNUserNotificationCenterDelegate {
    // 완료 처리기 형태를 쓴다. `async` 형태는 Swift가 완료 처리기를 메인 스레드 밖에서 불러 UIKit이 앱을 종료시킨다.

    /// 앱이 앞에 있어도 배너·알림 목록·소리를 띄우고 목록을 새로 받는다.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            self.arrivedInForeground()
            done([.banner, .list, .sound])
        }
    }

    /// 알림을 눌렀다. `rd.kind`에 맞는 탭으로 간다.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let target = PushTarget(userInfo: response.notification.request.content.userInfo)
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            self.open(target)
            done()
        }
    }
}
