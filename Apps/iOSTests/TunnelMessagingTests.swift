import Foundation
import NetworkExtension
import PhoneClientKit
import RDModels
import Testing
@testable import RemoteDebug

@Suite("TunnelProviderConfig")
struct TunnelProviderConfigTests {
    @Test("인코드·디코드 왕복, authKey 키 없음")
    func roundTripWithoutAuthKey() throws {
        let config = TunnelProviderConfig(hostname: "rd-phone-0a1b2c3d", controlURL: "https://control.example.com", goMemLimitMiB: 28, logging: true)
        let dictionary = try config.providerConfiguration()
        let data = try #require(dictionary[TunnelProviderConfig.providerConfigurationKey] as? Data)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["hostname", "controlURL", "goMemLimitMiB", "logging"])
        #expect(json["authKey"] == nil)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("authkey"))
        #expect(TunnelProviderConfig(providerConfiguration: dictionary) == config)
    }

    @Test("기본값: 제어 서버 빈 값, 메모리 한도 28, 로그 끔")
    func defaults() throws {
        let data = Data(#"{"hostname":"rd-phone-12345678"}"#.utf8)
        let config = try #require(TunnelProviderConfig(providerConfiguration: [TunnelProviderConfig.providerConfigurationKey: data]))
        #expect(config == TunnelProviderConfig(hostname: "rd-phone-12345678", controlURL: "", goMemLimitMiB: 28, logging: false))
    }

    @Test("구성이 없거나 깨졌으면 nil")
    func missingOrCorrupt() {
        #expect(TunnelProviderConfig(providerConfiguration: nil) == nil)
        #expect(TunnelProviderConfig(providerConfiguration: [:]) == nil)
        #expect(TunnelProviderConfig(providerConfiguration: [TunnelProviderConfig.providerConfigurationKey: Data("{}".utf8)]) == nil)
    }

    @Test("호스트 이름은 rd-phone-<16진수 8자>")
    func hostname() {
        #expect(TunnelProviderConfig.hostname(nodeID: "0A1B2C3D4E5F") == "rd-phone-0a1b2c3d")
        #expect(TunnelProviderConfig.hostname(nodeID: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F") == "rd-phone-e621e1f8")
        #expect(TunnelProviderConfig.hostname(nodeID: "ab") == "rd-phone-ab000000")
    }

    @Test("인증 키는 시작 옵션으로만 전달된다")
    func authKeyOptions() {
        #expect(TunnelStartOptions.options(authKey: nil) == nil)
        #expect(TunnelStartOptions.options(authKey: "  ") == nil)
        let options = TunnelStartOptions.options(authKey: " tskey-auth-x ")
        #expect(TunnelStartOptions.authKey(from: options) == "tskey-auth-x")
        #expect(TunnelStartOptions.authKey(from: nil) == nil)
    }
}

@Suite("앱 ↔ 확장 메시지")
struct TunnelMessageTests {
    @Test("요청 JSON은 {\"cmd\":\"status\"}")
    func requestJSON() throws {
        let data = try TunnelAppRequest.status.encoded()
        #expect(String(decoding: data, as: UTF8.self) == #"{"cmd":"status"}"#)
        #expect(TunnelAppRequest.decode(Data(#"{"cmd":"status"}"#.utf8)) == .status)
        #expect(TunnelAppRequest.decode(Data(#"{"cmd":"reboot"}"#.utf8)) == nil)
        #expect(TunnelAppRequest.decode(Data("not json".utf8)) == nil)
    }

    @Test("응답은 rd_status + physFootprintMiB + 단계")
    func replyRoundTrip() throws {
        let status = CoreStatus(
            backendState: .needsLogin,
            authURL: "https://login.example.com/a/1",
            hostname: "rd-phone-0a1b2c3d",
            rssMiB: 27.5,
            tunnel: TunnelStatus(mtu: 1280)
        )
        let reply = TunnelStatusReply.make(phase: .running, status: status, physFootprintMiB: 31.5, lastError: nil)
        let data = try reply.encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["phase"] as? String == "running")
        #expect(json["physFootprintMiB"] as? Double == 31.5)
        let inner = try #require(json["status"] as? [String: Any])
        #expect(inner["backendState"] as? String == "NeedsLogin")
        #expect(inner["authURL"] as? String == "https://login.example.com/a/1")
        #expect(TunnelStatusReply.decode(data) == reply)
    }

    @Test("인증 키는 시작 옵션에만 있고, 코어 오류에 섞여도 응답·구성에 나가지 않는다")
    func noSecretInReplyOrConfig() throws {
        let secret = "tskey-auth-kQ3x9EXAMPLE-0123456789abcdefSECRET"
        // 앱이 보내는 것: 구성(디스크에 남음)과 시작 옵션(한 번만).
        let config = TunnelProviderConfig(hostname: "rd-phone-0a1b2c3d", controlURL: "https://control.example.com")
        let options = try #require(TunnelStartOptions.options(authKey: secret))
        #expect(TunnelStartOptions.authKey(from: options) == secret)
        let configData = try #require(try config.providerConfiguration()[TunnelProviderConfig.providerConfigurationKey] as? Data)
        let configText = String(decoding: configData, as: UTF8.self)
        #expect(!configText.contains(secret))
        #expect(!configText.lowercased().contains("tskey"))
        #expect(!configText.lowercased().contains("authkey"))

        // 코어가 오류 메시지에 키를 되풀이한 경우(확장의 lastError에도 그대로 들어온다).
        let status = CoreStatus(
            backendState: .error,
            authURL: "https://login.example.com/a/1",
            hostname: "rd-phone-0a1b2c3d",
            errorMessage: "backend error: invalid key \(secret) rejected"
        )
        let reply = TunnelStatusReply.make(
            phase: .running,
            status: status,
            physFootprintMiB: 30,
            lastError: "tailnet 연결을 시작하지 못했습니다: \(secret.uppercased())"
        )
        let text = String(decoding: try reply.encoded(), as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains("SECRET"))
        #expect(!text.lowercased().contains("tskey"))
        #expect(!text.lowercased().contains("authkey"))
        // 키 말고 진단에 필요한 내용은 남는다.
        #expect(reply.status?.errorMessage == "backend error: invalid key [인증 키 가림] rejected")
        #expect(reply.status?.authURL == "https://login.example.com/a/1")
        #expect(reply.lastError == "tailnet 연결을 시작하지 못했습니다: [인증 키 가림]")
    }

    @Test("키 가림: 키가 없으면 그대로, 여러 개면 모두")
    func redactor() {
        #expect(TunnelSecretRedactor.redact("연결 실패") == "연결 실패")
        #expect(TunnelSecretRedactor.redact("a tskey-1 b TSKEY-auth-2_x. c") == "a [인증 키 가림] b [인증 키 가림]. c")
        #expect(TunnelSecretRedactor.redact(nil as String?) == nil)
    }

    @Test("코어가 아직 없을 때의 응답")
    func replyWithoutStatus() throws {
        let decoded = TunnelStatusReply.decode(Data(#"{"phase":"starting"}"#.utf8))
        #expect(decoded == TunnelStatusReply(phase: .starting))
    }
}

@Suite("NEVPNStatus → TunnelState")
struct TunnelStateMappingTests {
    private func reply(_ state: BackendState, authURL: String = "", error: String? = nil, phase: TunnelExtensionPhase = .running) -> TunnelStatusReply {
        TunnelStatusReply(phase: phase, status: CoreStatus(backendState: state, authURL: authURL, errorMessage: error))
    }

    @Test("VPN 상태만으로 정해지는 값")
    func plainStatuses() {
        #expect(TunnelStateMapping.state(status: .invalid, reply: nil, disconnectMessage: nil) == .off)
        #expect(TunnelStateMapping.state(status: .disconnected, reply: nil, disconnectMessage: nil) == .off)
        #expect(TunnelStateMapping.state(status: .disconnecting, reply: nil, disconnectMessage: nil) == .disconnecting)
        #expect(TunnelStateMapping.state(status: .connecting, reply: nil, disconnectMessage: nil) == .connecting)
        #expect(TunnelStateMapping.state(status: .reasserting, reply: nil, disconnectMessage: nil) == .connecting)
    }

    @Test("사용자가 끄지 않았는데 끊기면 failed로 다시 연결을 제안한다")
    func unexpectedDisconnect() {
        let message = "TUN 장치가 닫혔습니다. 앱에서 VPN을 다시 켜세요."
        #expect(TunnelStateMapping.state(status: .disconnected, reply: nil, disconnectMessage: message) == .failed(message: message))
    }

    @Test("연결됨: 확장 응답이 없거나 코어가 시작 중이면 connecting")
    func connectedWaitingForCore() {
        #expect(TunnelStateMapping.state(status: .connected, reply: nil, disconnectMessage: nil) == .connecting)
        #expect(TunnelStateMapping.state(status: .connected, reply: TunnelStatusReply(phase: .starting), disconnectMessage: nil) == .connecting)
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.starting), disconnectMessage: nil) == .connecting)
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.stopped), disconnectMessage: nil) == .connecting)
    }

    @Test("연결됨 + Running → connected")
    func running() {
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.running), disconnectMessage: nil) == .connected)
    }

    @Test("NeedsLogin → needsLogin(authURL), https만 연다")
    func needsLogin() {
        let url = URL(string: "https://login.example.com/a/123")
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.needsLogin, authURL: "https://login.example.com/a/123"), disconnectMessage: nil) == .needsLogin(authURL: url))
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.needsLogin), disconnectMessage: nil) == .needsLogin(authURL: nil))
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.needsLogin, authURL: "javascript:alert(1)"), disconnectMessage: nil) == .needsLogin(authURL: nil))
    }

    @Test("Error → failed: 복구 방법 뒤에 코어의 원인을 붙이고, 원인이 없으면 복구 방법만")
    func backendError() {
        let cause = "invalid key [인증 키 가림] rejected"
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.error, error: cause), disconnectMessage: nil)
            == .failed(message: TunnelStateMapping.backendErrorMessage + "\n원인: " + cause))
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.error), disconnectMessage: nil) == .failed(message: TunnelStateMapping.backendErrorMessage))
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.error, error: "  \n"), disconnectMessage: nil) == .failed(message: TunnelStateMapping.backendErrorMessage))
        #expect(TunnelStateMapping.state(status: .connected, reply: reply(.needsMachineAuth), disconnectMessage: nil) == .failed(message: TunnelStateMapping.machineAuthMessage))
    }

    @Test("VPN이 켜진 채 tailnet만 오류일 때의 안내는 카드의 버튼 이름(‘다시 연결’, ‘인증 키로 켜기’)을 가리킨다")
    func backendErrorNamesTheButtons() {
        #expect(TunnelStateMapping.backendErrorMessage.contains("‘다시 연결’"))
        #expect(TunnelStateMapping.backendErrorMessage.contains("‘인증 키로 켜기’"))
        // 기기 승인은 관리자가 하면 자동으로 이어지므로 VPN을 다시 켜라고 하지 않는다.
        #expect(!TunnelStateMapping.machineAuthMessage.contains("다시 켜"))
        #expect(!TunnelStateMapping.machineAuthMessage.contains("다시 연결"))
    }

    @Test("확장이 failed 단계면 그 오류")
    func extensionFailed() {
        let failed = TunnelStatusReply(phase: .failed, lastError: "VPN 장치(utun)를 찾지 못했습니다. VPN을 다시 켜세요.")
        #expect(TunnelStateMapping.state(status: .connected, reply: failed, disconnectMessage: nil) == .failed(message: "VPN 장치(utun)를 찾지 못했습니다. VPN을 다시 켜세요."))
    }

    @Test("연결 중·연결됨·재연결 중에만 2초 상태 확인")
    func polling() {
        #expect(TunnelStateMapping.shouldPoll(.connecting))
        #expect(TunnelStateMapping.shouldPoll(.connected))
        #expect(TunnelStateMapping.shouldPoll(.reasserting))
        #expect(!TunnelStateMapping.shouldPoll(.disconnected))
        #expect(!TunnelStateMapping.shouldPoll(.disconnecting))
        #expect(!TunnelStateMapping.shouldPoll(.invalid))
    }

    @Test("제어 서버 URL은 빈 값이나 https만")
    func controlURLValidation() {
        #expect(TunnelSettingsStore.normalizedControlURL("") == "")
        #expect(TunnelSettingsStore.normalizedControlURL(" https://hs.example.com ") == "https://hs.example.com")
        #expect(TunnelSettingsStore.normalizedControlURL("http://hs.example.com") == nil)
        #expect(TunnelSettingsStore.normalizedControlURL("hs.example.com") == nil)
        #expect(TunnelSettingsStore.normalizedControlURL("https://user:pw@hs.example.com") == nil)
    }
}
