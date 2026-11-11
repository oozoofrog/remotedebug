import PhoneClientKit
import UIKit

/// `ClientModel`이 설치 창(`itms-services://`)과 로그인 페이지를 열 때 쓴다.
@MainActor
final class UIKitURLOpener: URLOpening {
    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
}
