import Foundation
import NetworkExtension
import PhoneClientKit
import RDModels

/// `NEVPNStatus` + 확장 응답 → `TunnelState`. 부작용 없는 함수라 단위 테스트한다.
enum TunnelStateMapping {
    static let simulatorUnavailableMessage = "이 기기에서는 VPN 확장을 쓸 수 없습니다(시뮬레이터)."
    static let machineAuthMessage = "tailnet 관리자가 이 기기를 승인해야 합니다. 관리 콘솔에서 기기를 승인하면 자동으로 연결됩니다."
    /// VPN은 켜져 있고 tailnet 쪽만 오류일 때. 카드에는 ‘다시 연결’(VPN을 끄고 다시 켬)과 ‘인증 키로 켜기’가 보인다.
    static let backendErrorMessage = "tailnet에 연결하지 못했습니다. ‘다시 연결’을 누르고, 계속되면 ‘인증 키로 켜기’로 다시 로그인하세요."
    static let droppedMessage = "VPN 연결이 끊겼습니다. 다시 연결하세요."

    /// 코어가 보낸 오류 문구(영어일 수 있다)는 복구 방법 뒤에 원인으로 붙인다. 인증 키는 확장이 이미 가렸다.
    static func backendErrorMessage(cause: String?) -> String {
        guard let cause = cause?.trimmingCharacters(in: .whitespacesAndNewlines), !cause.isEmpty else {
            return backendErrorMessage
        }
        return backendErrorMessage + "\n원인: " + cause
    }

    /// - Parameters:
    ///   - status: VPN 연결 상태.
    ///   - reply: 확장이 마지막으로 돌려준 상태. 연결 중·연결됨에서만 의미가 있다.
    ///   - disconnectMessage: 확장이 오류로 끝난 경우의 안내. 있으면 `disconnected`를 `failed`로 올린다.
    static func state(status: NEVPNStatus, reply: TunnelStatusReply?, disconnectMessage: String?) -> TunnelState {
        switch status {
        case .invalid:
            return .off
        case .disconnected:
            if let disconnectMessage { return .failed(message: disconnectMessage) }
            return .off
        case .disconnecting:
            return .disconnecting
        case .connecting, .reasserting:
            return .connecting
        case .connected:
            return connectedState(reply)
        @unknown default:
            return .off
        }
    }

    /// VPN은 연결됐다. tailnet 쪽 상태는 확장 응답으로 정한다.
    static func connectedState(_ reply: TunnelStatusReply?) -> TunnelState {
        guard let reply else { return .connecting }
        if reply.phase == .failed {
            return .failed(message: reply.lastError ?? backendErrorMessage)
        }
        guard let status = reply.status else { return .connecting }
        switch status.backendState {
        case .running:
            return .connected
        case .needsLogin:
            return .needsLogin(authURL: loginURL(status.authURL))
        case .needsMachineAuth:
            return .failed(message: machineAuthMessage)
        case .error:
            return .failed(message: backendErrorMessage(cause: status.errorMessage))
        default:
            return .connecting
        }
    }

    /// `fetchLastDisconnectError()`의 결과를 안내 문구로 바꾼다.
    /// 오류가 없거나(설정 앱·제어 센터에서 끔) 시작 중에 꺼진 경우는 `nil`(꺼짐으로 보인다).
    /// 확장이 보낸 오류는 그 한국어 설명을, 그 밖의 오류는 `droppedMessage`를 쓴다.
    static func disconnectMessage(for error: (any Error)?) -> String? {
        guard let error else { return nil }
        // NE가 확장 오류를 감싸 돌려줘도(`NSUnderlyingErrorKey`) 같은 규칙으로 찾는다.
        if TunnelProviderError.kind(of: error) == .stoppedDuringStart { return nil }
        return TunnelProviderError.userMessage(for: error) ?? droppedMessage
    }

    /// VPN이 켜져 있거나 켜지거나 꺼지는 중인지(다시 켜기 전에 먼저 꺼야 하는 상태).
    static func isActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting: true
        case .disconnected, .invalid: false
        @unknown default: false
        }
    }

    /// 로그인 주소는 https만 연다.
    static func loginURL(_ text: String) -> URL? {
        guard !text.isEmpty, let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// 진단 화면에 보여 줄 VPN 상태 이름.
    static func label(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: "구성 없음"
        case .disconnected: "꺼짐"
        case .connecting: "연결 중"
        case .connected: "연결됨"
        case .reasserting: "다시 연결 중"
        case .disconnecting: "끄는 중"
        @unknown default: "알 수 없음"
        }
    }

    /// 확장 응답을 2초마다 물어야 하는 상태인지.
    static func shouldPoll(_ status: NEVPNStatus) -> Bool {
        status == .connecting || status == .connected || status == .reasserting
    }
}
