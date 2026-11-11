import Foundation
import JavaScriptCore
import RDModels
import Testing

@testable import PhoneClientKit

private let fqdn = "rd-mac-ab12cd34.example-tailnet.ts.net"
private let origin = "https://\(fqdn)"
private let token = "Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmE"  // 43자
private let manifest = "\(origin)/i/\(token)/manifest.plist"

/// Go url.QueryEscape와 같은 인코딩(영숫자와 -_.~만 그대로).
private func queryEscape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"))!
}

/// 호스트(sessions.go)가 만드는 설치 주소.
private func installURL(_ manifest: String) -> String {
    "itms-services://?action=download-manifest&url=" + queryEscape(manifest)
}

// MARK: - 페어링 코드

@Suite struct PairingCodeTests {
    /// iPhone 앱의 PairingCode.parse와 결과가 같은지 입력 묶음으로 비교한다.
    @Test(arguments: [
        "K7M29QXD", "k7m2-9qxd", "K7M2 9QXD", "K7M2\t9QXD", " K7M29QXD ", "k7m2 - 9qxd",
        "U7M29QXD", "u7m29qxd", "K7M2-9QXU", "ABCDEFGHU", "UUUU",
        "O0IlLoil", "oooooooo", "iiiiLLLL", "ıııııııı", "K7M29Qß", "ﬀﬀﬀﬀ",
        "K7M2-9QX", "K7M29QXDA", "", "----", "        ",
        "K7M2_9QXD", "K7M2.9QXD", "K7M2９QXD", "ÄBCDEFGH", "K7M2\n9QXD", "K7M2–9QXD", "🙂K7M29QXD", "K7M2/9QXD",
        "0123456789", "ZZZZZZZZ", "A1B2C3D4",
    ])
    func parityWithIPhoneApp(_ input: String) throws {
        let js = try JSHarness()
        let result = js.call("normalizeCode", input)
        let swift: Result<String, PairingLinkError>
        do {
            swift = .success(try PairingCode.parse(input).normalized)
        } catch {
            swift = .failure(error)
        }
        switch swift {
        case .success(let code):
            #expect(result.string("code") == code, "input \(input.debugDescription)")
            #expect(result.string("error") == nil)
            #expect(js.call("isValidCode", input).toBool())
        case .failure(let error):
            #expect(result.string("code") == nil, "input \(input.debugDescription)")
            let expected = error == .invalidCodeCharacters ? "invalidCodeCharacters" : "invalidCodeLength"
            #expect(result.string("error") == expected, "input \(input.debugDescription)")
            #expect(!js.call("isValidCode", input).toBool())
            #expect(js.message(expected) == error.userMessage)
        }
    }

    @Test func rules() throws {
        let js = try JSHarness()
        #expect(js.call("normalizeCode", "k7m2-9qxd").string("code") == "K7M29QXD")
        #expect(js.call("normalizeCode", "U7M29QXD").string("error") == "invalidCodeCharacters")
        #expect(js.call("normalizeCode", "u7m2-9qxd").string("error") == "invalidCodeCharacters")
        #expect(js.call("normalizeCode", "O1L0I0OL").string("code") == "01101001")
        #expect(js.call("normalizeCode", "K7M2-9QX").string("error") == "invalidCodeLength")
        #expect(js.call("displayCode", "k7m29qxd").toString() == "K7M2-9QXD")
        #expect(js.call("displayCode", "k7m29qx").toString() == "")
    }

    @Test func pairRequestBody() throws {
        let js = try JSHarness()
        let ok = js.call("pairRequestBody", "k7m2 9qxd", "  ").value("body")
        #expect(ok.string("code") == "K7M29QXD")
        #expect(ok.string("deviceName") == "iPhone(Safari)")
        #expect(ok.string("platform") == "Web")
        #expect(ok.string("clientVersion") == "web-1")
        #expect(js.call("pairRequestBody", "U7M29QXD", "x").string("error") == "invalidCodeCharacters")
        #expect(js.call("pairRequestBody", "K7M2", "x").string("error") == "invalidCodeLength")
        // 기기 이름은 UTF-8 200바이트 안에서 글자 경계로 자른다(HostAPI.truncated).
        let long = String(repeating: "가", count: 80)  // 240바이트
        let name = js.call("pairRequestBody", "K7M29QXD", long).value("body").string("deviceName")!
        #expect(name == String(repeating: "가", count: 66))
        #expect(name == HostAPI.truncated(long, maxBytes: HostAPI.maxDeviceNameBytes))
        let emoji = String(repeating: "👩‍👩‍👧", count: 20)
        #expect(js.call("truncateUTF8", emoji, 200).toString() == HostAPI.truncated(emoji, maxBytes: 200))
    }
}

// MARK: - URL 조각

@Suite struct FragmentTests {
    @Test func parse() throws {
        let js = try JSHarness()
        func code(_ hash: String) -> String? { js.call("parseFragment", hash).string("code") }
        #expect(code("#code=K7M2-9QXD") == "K7M2-9QXD")
        #expect(code("code=k7m29qxd") == "k7m29qxd")
        #expect(code("#x=1&code=K7M2%209QXD") == "K7M2 9QXD")
        #expect(code("#code=%20K7M29QXD%20") == "K7M29QXD")
        #expect(code("") == nil)
        #expect(code("#") == nil)
        #expect(code("#code=") == nil)
        #expect(code("#codex=K7M29QXD") == nil)
        #expect(code("#code=A&code=B") == nil)
        #expect(code("#code=%E0%A4%A") == nil)
        #expect(code("#code=" + String(repeating: "A", count: 33)) == nil)
        #expect(js.call("parseFragment", NSNull()).string("code") == nil)
    }
}

// MARK: - 설치 주소

@Suite struct InstallURLTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var install: String
        var manifestURL: String
        var origin: String
        var trusted: Bool
        var testDescription: String { name }
    }

    static let otherToken = String(token.reversed())
    static let cases: [Case] = [
        Case(name: "host shape", install: installURL(manifest), manifestURL: manifest, origin: origin, trusted: true),
        Case(name: "url first", install: "itms-services://?url=\(queryEscape(manifest))&action=download-manifest", manifestURL: manifest, origin: origin, trusted: true),
        Case(name: "unencoded url value", install: "itms-services://?action=download-manifest&url=\(manifest)", manifestURL: manifest, origin: origin, trusted: true),
        Case(name: "other origin", install: installURL(manifest), manifestURL: manifest, origin: "https://other-mac.example-tailnet.ts.net", trusted: false),
        Case(name: "manifest on other host", install: installURL("https://evil.example-tailnet.ts.net/i/\(token)/manifest.plist"), manifestURL: "https://evil.example-tailnet.ts.net/i/\(token)/manifest.plist", origin: origin, trusted: false),
        Case(name: "http manifest, https page", install: installURL("http://\(fqdn)/i/\(token)/manifest.plist"), manifestURL: "http://\(fqdn)/i/\(token)/manifest.plist", origin: origin, trusted: false),
        Case(name: "https manifest, http page", install: installURL(manifest), manifestURL: manifest, origin: "http://\(fqdn)", trusted: false),
        Case(name: "explicit port 443", install: installURL("https://\(fqdn):443/i/\(token)/manifest.plist"), manifestURL: "https://\(fqdn):443/i/\(token)/manifest.plist", origin: origin, trusted: false),
        Case(name: "extra query item", install: installURL(manifest) + "&x=1", manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "duplicate url", install: installURL(manifest) + "&url=" + queryEscape(manifest), manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "duplicate action", install: "itms-services://?action=download-manifest&action=download-manifest", manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "wrong action", install: "itms-services://?action=download&url=" + queryEscape(manifest), manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "userinfo", install: installURL("https://user@\(fqdn)/i/\(token)/manifest.plist"), manifestURL: "https://user@\(fqdn)/i/\(token)/manifest.plist", origin: origin, trusted: false),
        Case(name: "origin as userinfo", install: installURL("https://\(fqdn)@evil.example/i/\(token)/manifest.plist"), manifestURL: "https://\(fqdn)@evil.example/i/\(token)/manifest.plist", origin: origin, trusted: false),
        Case(name: "short token", install: installURL("\(origin)/i/\(token.dropLast())/manifest.plist"), manifestURL: "\(origin)/i/\(token.dropLast())/manifest.plist", origin: origin, trusted: false),
        Case(name: "long token", install: installURL("\(origin)/i/\(token)A/manifest.plist"), manifestURL: "\(origin)/i/\(token)A/manifest.plist", origin: origin, trusted: false),
        Case(name: "token with +", install: installURL("\(origin)/i/\(token.dropLast())+/manifest.plist"), manifestURL: "\(origin)/i/\(token.dropLast())+/manifest.plist", origin: origin, trusted: false),
        Case(name: "ipa path", install: installURL("\(origin)/i/\(token)/app.ipa"), manifestURL: "\(origin)/i/\(token)/app.ipa", origin: origin, trusted: false),
        Case(name: "extra path segment", install: installURL("\(origin)/x/i/\(token)/manifest.plist"), manifestURL: "\(origin)/x/i/\(token)/manifest.plist", origin: origin, trusted: false),
        Case(name: "manifest query", install: installURL(manifest + "?a=1"), manifestURL: manifest + "?a=1", origin: origin, trusted: false),
        Case(name: "manifest fragment", install: installURL(manifest + "#a"), manifestURL: manifest + "#a", origin: origin, trusted: false),
        Case(name: "differs from manifestUrl", install: installURL(manifest), manifestURL: "\(origin)/i/\(otherToken)/manifest.plist", origin: origin, trusted: false),
        Case(name: "authority", install: "itms-services://evil/?action=download-manifest&url=" + queryEscape(manifest), manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "path", install: "itms-services:///x?action=download-manifest&url=" + queryEscape(manifest), manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "install fragment", install: installURL(manifest) + "#x", manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "upper-case scheme", install: "ITMS-SERVICES://?action=download-manifest&url=" + queryEscape(manifest), manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "https scheme", install: "https://?action=download-manifest&url=" + queryEscape(manifest), manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "space", install: installURL(manifest) + " ", manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "bad percent encoding", install: "itms-services://?action=download-manifest&url=%E0%A4%A", manifestURL: manifest, origin: origin, trusted: false),
        Case(name: "null origin", install: installURL(manifest), manifestURL: manifest, origin: "null", trusted: false),
        Case(name: "origin with path", install: installURL(manifest), manifestURL: manifest, origin: origin + "/", trusted: false),
    ]

    @Test(arguments: cases)
    func trusted(_ c: Case) throws {
        let js = try JSHarness()
        let got = js.call("trustedInstallURL", c.install, c.manifestURL, c.origin).toBool()
        #expect(got == c.trusted)
        // 페이지는 iPhone 앱보다 느슨하지 않다: 페이지가 받으면 앱도 받는다.
        if got, let url = URL(string: c.install) {
            let host = URLComponents(string: c.origin)?.host ?? ""
            #expect(ClientModel.isTrustedInstallURL(url, manifestURL: URL(string: c.manifestURL), host: host, policy: .tailnetOnly))
        }
    }

    @Test func fakeTailnetOrigin() throws {
        let js = try JSHarness()
        let base = "http://rd-mac-00000001.rd-test.ts.net:8080"
        let m = "\(base)/i/\(token)/manifest.plist"
        #expect(js.call("trustedInstallURL", installURL(m), m, base).toBool())
        #expect(!js.call("trustedInstallURL", installURL(m), m, "http://rd-mac-00000001.rd-test.ts.net:8081").toBool())
        #expect(!js.call("trustedInstallURL", installURL(m), m, "http://rd-mac-00000001.rd-test.ts.net").toBool())
    }

    @Test func nonStrings() throws {
        let js = try JSHarness()
        #expect(!js.call("trustedInstallURL", NSNull(), manifest, origin).toBool())
        #expect(!js.call("trustedInstallURL", installURL(manifest), NSNull(), origin).toBool())
        #expect(!js.call("trustedInstallURL", installURL(manifest), manifest).toBool())
    }
}

// MARK: - 오류 문구

@Suite struct MessageTests {
    /// 앱과 같은 문구를 쓰는 코드. 페이지가 볼 수 있는 프로토콜 코드와 클라이언트 판정 코드를 모두 담는다.
    static let sameAsApp = [
        "not_paired", "pair_code_invalid", "too_many_attempts", "token_invalid", "session_expired",
        "build_not_found", "build_changed", "not_debug_build", "internal",
        "connection_failed", "timed_out", "invalid_response", "something_new",
    ]

    @Test(arguments: sameAsApp)
    func sameWordingAsApp(_ code: String) throws {
        let js = try JSHarness()
        let page = js.call("messageForError", 403, code).toString()
        #expect(page == HostAPIError(status: 403, code: code, message: "").userMessage)
    }

    /// 앱은 "iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요"라고 한다. 페이지는 Mac 앱이 직접 내주므로 Mac 앱 업데이트만 안내한다.
    @Test(arguments: ["not_found", "method_not_allowed", "bad_request", "protocol_mismatch"])
    func macOnlyUpdateWording(_ code: String) throws {
        let js = try JSHarness()
        let page = js.call("messageForError", 400, code).toString()!
        let app = HostAPIError(status: 400, code: code, message: "").userMessage
        #expect(page.contains("Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요."))
        #expect(!page.contains("iPhone 앱"))
        #expect(page.components(separatedBy: ". ").first == app.components(separatedBy: ". ").first)
    }

    @Test func clientModelWording() throws {
        let js = try JSHarness()
        #expect(js.message("pairingDenied") == ClientModel.pairingDeniedMessage)
        #expect(js.message("pairingExpired") == ClientModel.pairingExpiredMessage)
        #expect(js.message("sessionFailed") == ClientModel.sessionFailedMessage)
        #expect(js.message("installTimeout") == ClientModel.installTimeoutMessage)
        #expect(js.message("createSessionTimeout") == ClientModel.createSessionTimeoutMessage)
        #expect(js.message("expired") == InstallState.expiredMessage)
        #expect(js.message("developerModeHint") == InstallState.developerModeHint)
        #expect(js.message("completedSent") + " " + js.message("developerModeHint") == InstallState.completedMessage)
        #expect(js.message("invalidCodeLength") == PairingLinkError.invalidCodeLength.userMessage)
        #expect(js.message("invalidCodeCharacters") == PairingLinkError.invalidCodeCharacters.userMessage)
    }

    @Test func classifyResponse() throws {
        let js = try JSHarness()
        func cls(_ status: Int, _ proto: Any, _ body: String) -> JSValue { js.call("classifyResponse", status, proto, body) }
        let ok = cls(200, "1", #"{"builds":[]}"#)
        #expect(ok.value("ok").toBool())
        #expect(ok.value("data").value("builds").isArray)
        #expect(cls(403, "1", #"{"error":{"code":"not_paired","message":"x"}}"#).string("code") == "not_paired")
        #expect(cls(502, NSNull(), "bad gateway").string("code") == "connection_failed")
        // X-RD-Protocol이 없는 응답은 400부터가 중간에서 끊긴 연결이다(HostAPI.call). 프록시·캡티브 포털의 403·407도 포함한다.
        for status in [400, 403, 407, 499, 500, 599] {
            #expect(cls(status, NSNull(), "").string("code") == "connection_failed", "\(status)")
        }
        for status in [200, 204, 301, 399] {
            #expect(cls(status, NSNull(), "").string("code") == "protocol_mismatch", "\(status)")
        }
        #expect(cls(200, NSNull(), "{}").string("code") == "protocol_mismatch")
        #expect(cls(200, "2", "{}").string("code") == "protocol_mismatch")
        #expect(cls(200, " 1 ", "{}").value("ok").toBool())
        #expect(cls(500, "1", "oops").string("code") == "invalid_response")
        #expect(cls(200, "1", "not json").string("code") == "invalid_response")
        #expect(cls(200, "1", "42").string("code") == "invalid_response")
        #expect(!cls(403, "1", #"{"error":{"code":"not_paired"}}"#).value("ok").toBool())
    }
}

// MARK: - 진행·폴링·표시

@Suite struct ProgressTests {
    @Test func progressText() throws {
        let js = try JSHarness()
        func text(_ s: [String: Any]) -> String { js.call("progressText", s).toString() }
        #expect(text(["state": "created"]) == "설치 창에서 ‘설치’를 누르세요")
        #expect(text(["state": "manifest_served"]) == "설치 창에서 ‘설치’를 누르세요")
        #expect(text(["state": "downloading", "bytesServed": 10_485_760, "size": 52_428_800]) == "전송 중 10.5 MB / 52.4 MB")
        #expect(text(["state": "downloading", "bytesServed": 512_000, "size": 0]) == "전송 중 512 KB")
        #expect(text(["state": "completed"]) == InstallState.completedMessage)
        #expect(text(["state": "expired"]) == InstallState.expiredMessage)
        #expect(text(["state": "failed"]) == ClientModel.sessionFailedMessage)
        #expect(text(["state": "bogus"]) == HostAPIError(status: 0, code: "x", message: "").userMessage)
    }

    @Test func pollDelay() throws {
        let js = try JSHarness()
        #expect(js.logic.value("POLL_INTERVAL_MS").toInt32() == 1000)
        #expect(js.call("nextPollDelay", 0, 120_000).toInt32() == 1000)
        #expect(js.call("nextPollDelay", 119_500, 120_000).toInt32() == 500)
        #expect(js.call("nextPollDelay", 120_000, 120_000).isNull)
        #expect(js.call("nextPollDelay", 130_000, 120_000).isNull)
        #expect(js.call("nextPollDelay", 0, Double.nan).isNull)
    }

    @Test func deadlines() throws {
        let js = try JSHarness()
        let now = 1_794_387_600_000.0  // 2026-11-11T09:00:00Z
        #expect(js.call("pairingDeadline", now, "2026-11-11T09:01:00Z").toDouble() == now + 60_000)
        #expect(js.call("pairingDeadline", now, "2026-11-11T09:05:00Z").toDouble() == now + 120_000)
        #expect(js.call("pairingDeadline", now, "2026-11-11T08:59:00Z").toDouble() == now + 120_000)
        #expect(js.call("pairingDeadline", now, NSNull()).toDouble() == now + 120_000)
        let r = js.call("remainingText", 61_200)
        #expect(r.string("text") == "1:02")
        #expect(r.string("label") == "남은 시간 1분 2초")
        #expect(!r.value("low").toBool())
        #expect(js.call("remainingText", 30_000).value("low").toBool())
        #expect(js.call("remainingText", -5).string("text") == "0:00")
    }

    @Test func storedPairing() throws {
        let js = try JSHarness()
        let p = js.call("parseStoredPairing", #"{"requestId":"pr_7c1e55d0","deadline":1794387720000,"deviceName":"내 iPhone"}"#)
        #expect(p.string("requestId") == "pr_7c1e55d0")
        #expect(p.value("deadline").toDouble() == 1_794_387_720_000)
        #expect(p.string("deviceName") == "내 iPhone")
        #expect(js.call("parseStoredPairing", #"{"requestId":"../x","deadline":1}"#).isNull)
        #expect(js.call("parseStoredPairing", #"{"requestId":"pr_1","deadline":"1"}"#).isNull)
        #expect(js.call("parseStoredPairing", "{").isNull)
        #expect(js.call("parseStoredPairing", "null").isNull)
        let round = js.call("serializePairing", p).toString()!
        #expect(js.call("parseStoredPairing", round).string("requestId") == "pr_7c1e55d0")
    }

    @Test func buildSummary() throws {
        let js = try JSHarness()
        let build: [String: Any] = [
            "id": "b_9f3a1c2e", "bundleId": "com.example.app.Sample", "displayName": "<b>Sample</b>",
            "version": "1.4.0", "buildNumber": "128",
            "signing": ["profileExpires": "2026-05-01T00:00:00Z"], "ipa": ["size": 52_428_800],
        ]
        let now = 1_794_387_600_000.0
        let s = js.call("buildSummary", build, now)
        #expect(s.string("name") == "<b>Sample</b>")
        #expect(s.string("detail") == "버전 1.4.0 (128) · 52.4 MB")
        #expect(s.string("bundleId") == "com.example.app.Sample")
        #expect(s.string("warning") == "프로비저닝 프로파일이 2026. 5. 1.에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.")
        var valid = build
        valid["signing"] = ["profileExpires": "2027-05-01T00:00:00Z"]
        #expect(js.call("buildSummary", valid, now).string("warning") == nil)
        #expect(js.call("formatSize", 999).toString() == "999바이트")
        #expect(js.call("formatSize", 1_500).toString() == "2 KB")
        #expect(js.call("formatSize", 2_500_000_000).toString() == "2.50 GB")
    }

    @Test func safeIDs() throws {
        let js = try JSHarness()
        for ok in ["b_9f3a1c2e", "s_52d9a07e", "pr_7c1e55d0", "A-z_0"] { #expect(js.call("isSafeID", ok).toBool()) }
        for bad in ["", "../x", "a/b", "a b", "a%2F", String(repeating: "a", count: 129)] { #expect(!js.call("isSafeID", bad).toBool()) }
    }
}

// MARK: - 설치 상태

@Suite struct InstallReducerTests {
    private func reduce(_ js: JSHarness, _ state: Any, _ event: [String: Any]) -> JSValue {
        js.call("installReducer", state, event)
    }

    private func created(_ js: JSHarness, install: String = installURL(manifest), manifestURL: String = manifest) -> JSValue {
        let preparing = reduce(js, NSNull(), ["type": "start"])
        return reduce(js, preparing, [
            "type": "created", "sessionId": "s_52d9a07e", "installUrl": install, "manifestUrl": manifestURL,
            "origin": origin, "now": 1000,
        ])
    }

    @Test func flow() throws {
        let js = try JSHarness()
        let preparing = reduce(js, NSNull(), ["type": "start"])
        #expect(preparing.string("kind") == "preparing")
        let waiting = created(js)
        #expect(waiting.string("kind") == "waiting")
        #expect(waiting.string("href") == installURL(manifest))
        #expect(!waiting.value("opened").toBool())
        #expect(waiting.value("deadline").toDouble() == 1000 + 600_000)
        let opened = reduce(js, waiting, ["type": "opened"])
        #expect(opened.value("opened").toBool())
        let served = reduce(js, waiting, ["type": "status", "state": "manifest_served", "bytesServed": 0, "size": 100])
        #expect(served.string("kind") == "waiting")
        #expect(served.value("opened").toBool())
        let moving = reduce(js, served, ["type": "status", "state": "downloading", "bytesServed": 40, "size": 100])
        #expect(moving.string("kind") == "transferring")
        #expect(moving.value("bytesServed").toInt32() == 40)
        #expect(moving.string("sessionId") == "s_52d9a07e")
        let done = reduce(js, moving, ["type": "status", "state": "completed"])
        #expect(done.string("kind") == "completed")
        #expect(!js.call("isInProgress", done).toBool())
        #expect(reduce(js, done, ["type": "clear"]).isNull)
    }

    /// 진행 중인 설치가 있으면 같은 빌드에 새 세션을 만들지 않는다(ClientModel.install).
    @Test func noSecondSession() throws {
        let js = try JSHarness()
        let preparing = reduce(js, NSNull(), ["type": "start"])
        let waiting = created(js)
        let moving = reduce(js, waiting, ["type": "status", "state": "downloading", "bytesServed": 1, "size": 2])
        for st in [preparing, waiting, moving] {
            #expect(!js.call("canStartInstall", st).toBool())
            let again = reduce(js, st, ["type": "start"])
            #expect(again.string("kind") == st.string("kind"))
            #expect(again.string("sessionId") == st.string("sessionId"))
        }
        for terminal in ["completed", "expired", "failed"] {
            let st = reduce(js, waiting, ["type": "status", "state": terminal])
            #expect(js.call("canStartInstall", st).toBool())
            #expect(reduce(js, st, ["type": "start"]).string("kind") == "preparing")
        }
        #expect(js.call("canStartInstall", NSNull()).toBool())
    }

    @Test func untrustedAddressIsNotOffered() throws {
        let js = try JSHarness()
        let evil = "https://evil.example-tailnet.ts.net/i/\(token)/manifest.plist"
        let st = created(js, install: installURL(evil), manifestURL: evil)
        #expect(st.string("kind") == "failed")
        #expect(st.string("href") == nil)
        #expect(st.string("message") == js.message("untrustedInstallURL"))
        let badID = reduce(js, reduce(js, NSNull(), ["type": "start"]), [
            "type": "created", "sessionId": "../x", "installUrl": installURL(manifest), "manifestUrl": manifest, "origin": origin, "now": 0,
        ])
        #expect(badID.string("kind") == "failed")
    }

    @Test func errorsAndDeadline() throws {
        let js = try JSHarness()
        let waiting = created(js)
        // 진행 확인 중 연결 실패는 일시적인 것으로 보고 상태를 바꾸지 않는다.
        #expect(reduce(js, waiting, ["type": "error", "code": "connection_failed"]).string("kind") == "waiting")
        #expect(reduce(js, waiting, ["type": "error", "code": "timed_out"]).string("kind") == "waiting")
        #expect(reduce(js, waiting, ["type": "error", "code": "session_expired"]).string("kind") == "expired")
        let tokenInvalid = reduce(js, waiting, ["type": "error", "code": "token_invalid"])
        #expect(tokenInvalid.string("kind") == "failed")
        #expect(tokenInvalid.string("message") == HostAPIError(status: 403, code: "token_invalid", message: "").userMessage)
        let timeout = reduce(js, waiting, ["type": "deadline"])
        #expect(timeout.string("message") == ClientModel.installTimeoutMessage)
        // 세션 생성 실패.
        let preparing = reduce(js, NSNull(), ["type": "start"])
        #expect(reduce(js, preparing, ["type": "error", "code": "timed_out", "creating": true]).string("message") == ClientModel.createSessionTimeoutMessage)
        #expect(reduce(js, preparing, ["type": "error", "code": "connection_failed", "creating": true]).string("message") == HostAPIError(status: 0, code: "connection_failed", message: "").userMessage)
        #expect(reduce(js, preparing, ["type": "error", "code": "build_changed", "creating": true]).string("message") == HostAPIError(status: 409, code: "build_changed", message: "").userMessage)
    }

    @Test func cancelAndClear() throws {
        let js = try JSHarness()
        let waiting = created(js)
        #expect(reduce(js, waiting, ["type": "cancel"]).isNull)
        let moving = reduce(js, waiting, ["type": "status", "state": "downloading", "bytesServed": 1, "size": 2])
        #expect(reduce(js, moving, ["type": "cancel"]).string("kind") == "transferring")
        #expect(reduce(js, moving, ["type": "clear"]).string("kind") == "transferring")
        #expect(js.call("needsSessionPoll", moving).toBool())
        #expect(!js.call("needsSessionPoll", reduce(js, NSNull(), ["type": "start"])).toBool())
    }

    @Test func pairingOutcome() throws {
        let js = try JSHarness()
        #expect(js.call("pairingOutcome", "pending").toString() == "wait")
        #expect(js.call("pairingOutcome", "approved").toString() == "approved")
        #expect(js.call("pairingOutcome", "denied").string("message") == ClientModel.pairingDeniedMessage)
        #expect(js.call("pairingOutcome", "expired").string("message") == ClientModel.pairingExpiredMessage)
    }
}
