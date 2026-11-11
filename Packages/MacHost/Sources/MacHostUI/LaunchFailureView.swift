import AppKit
import MacHostKit
import SwiftUI

/// 앱이 시작하지 못한 이유와 다음 행동.
public enum LaunchFailure: Sendable, Hashable {
    /// Application Support 폴더를 만들거나 잠그지 못했다.
    case storageUnavailable(String)
    /// 다른 RemoteDebug가 같은 저장 폴더를 쓰고 있다.
    case alreadyRunning

    var title: String {
        switch self {
        case .storageUnavailable: "저장 폴더를 열 수 없음"
        case .alreadyRunning: "RemoteDebug가 이미 실행 중"
        }
    }

    var message: String {
        switch self {
        case .storageUnavailable(let detail):
            "Application Support 폴더를 열지 못했습니다: \(detail) 디스크 공간과 폴더 권한을 확인한 뒤 RemoteDebug를 다시 실행하세요."
        case .alreadyRunning:
            "이미 실행 중인 RemoteDebug가 같은 폴더를 쓰고 있습니다. 실행 중인 앱을 쓰거나, 그 앱을 종료한 뒤 다시 실행하세요."
        }
    }
}

/// 시작 실패 화면: 원인, 고치는 방법, 종료(그리고 이미 실행 중이면 그 앱으로 전환).
public struct LaunchFailureView: View {
    let failure: LaunchFailure
    let switchToRunningApp: (() -> Void)?
    let quit: () -> Void

    public init(failure: LaunchFailure, switchToRunningApp: (() -> Void)? = nil, quit: @escaping () -> Void) {
        self.failure = failure
        self.switchToRunningApp = switchToRunningApp
        self.quit = quit
    }

    public var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
                .textSelection(.enabled)
        } actions: {
            if let switchToRunningApp {
                Button("실행 중인 앱으로 전환", action: switchToRunningApp)
                    .buttonStyle(.borderedProminent)
            }
            Button("종료", action: quit)
                .keyboardShortcut(.defaultAction)
        }
    }
}

#if DEBUG
#Preview("시작 실패: 저장 폴더") {
    LaunchFailureView(failure: .storageUnavailable("디스크에 남은 공간이 없습니다."), quit: {})
        .frame(width: 760, height: 520)
}

#Preview("시작 실패: 이미 실행 중") {
    LaunchFailureView(failure: .alreadyRunning, switchToRunningApp: {}, quit: {})
        .frame(width: 760, height: 520)
}
#endif
