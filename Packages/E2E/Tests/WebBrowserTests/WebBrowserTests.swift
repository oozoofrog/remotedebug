import AppKit
import Foundation
import MacHostKit
import Network
import RDModels
import WebKit
import XCTest

/// 설치 웹 페이지(docs/protocol-addenda.md E)를 WebKit(WKWebView)으로 띄워 실제 Mac 호스트와 사용자 흐름을 시험한다.
///
/// 경로: WKWebView → `http://127.0.0.1:<forward 포트>/` → `rdtestenv forward`(가짜 tailnet의 iPhone 노드) → tailnet →
/// Mac 코어(`HostModel` + `RDCoreHost`)의 평문 리스너(8080). 설치 링크가 실제로 만들어지는 경로(같은 출처)는
/// 시험 프로세스의 CONNECT 프록시(`ConnectProxy`)로 브라우저가 `http://<fqdn>:8080/`을 방문하게 해서 확인한다.
///
/// 이 시험이 대신하는 것: TLS(평문 8080, protocol §11), iPhone Safari(macOS WebKit + 모바일 UA, 390×844),
/// 사용자의 탭(`focus()` 뒤 `click()`), iOS 설치기(링크는 누르지 않는다).
///
/// XCTest로 쓴 까닭: scripts/e2e-full.sh는 이 패키지의 Swift Testing 시험 수(1개)를 확인한다. RD_E2E_WEB=1이 아니면
/// 이 시험은 아무것도 하지 않고 끝나며, scripts/e2e-web.sh가 단계 결과 수로 실제로 돌았는지 확인한다.
@MainActor
final class WebBrowserTests: XCTestCase {
    static let expectedSteps = 10

    func testInstallPageInWebKit() async throws {
        guard WebEnv.enabled else {
            print("e2e-web: RD_E2E_WEB=1이 아니라서 WebBrowserTests를 돌리지 않습니다. scripts/e2e-web.sh로 돌리세요.")
            return
        }
        HardLimit.arm(seconds: E2EEnv.hardLimitSeconds, label: "e2e-web")
        // GUI 세션이 없으면 WKWebView가 그리지 못한다. 건너뛰지 않고 실패한다.
        try GUISession.check()
        _ = NSApplication.shared
        let binary = try E2EEnv.rdtestenv()
        let tmp = try E2EEnv.directory("RD_E2E_TMPDIR")
        let logs = try E2EEnv.directory("RD_E2E_LOG_DIR")
        let shots = try WebEnv.shots()
        let report = StepReport(directory: logs)
        defer { ChildRegistry.terminateAll() }

        let world = try await WebWorld.start(binary: binary, tmp: tmp, logs: logs)
        let flow = WebFlow(world: world, report: report, shots: shots)
        report.problemSource = { flow.pageProblems }
        do {
            try await flow.run()
        } catch is StepReport.Aborted {
            XCTFail("단계가 중단되어 뒤 단계를 돌리지 않았다")
        } catch {
            XCTFail("예기치 못한 오류: \(error)")
        }
        flow.closeBrowsers()
        await world.finish()
        flow.writeLogs(to: logs)
    }
}

/// 단계들이 차례로 쌓아 가는 상태.
@MainActor
final class WebFlow {
    let world: WebWorld
    let report: StepReport
    let shots: URL
    var mac: HostModel { world.mac }

    /// 루프백 출처(forward 포트)로 연 브라우저 탭. 1~6, 9단계.
    private var phone: Browser?
    /// CONNECT 프록시로 `http://<fqdn>:8080/`을 연 탭. 7단계.
    private var tailnetTab: Browser?
    private var proxy: ConnectProxy?
    private var seenRequests: Set<String> = []
    private var focusResults: [(String, Bool, String)] = []
    private var audits: [(String, [String])] = []
    private var sessionFromRefusal: String?

    init(world: WebWorld, report: StepReport, shots: URL) {
        self.world = world
        self.report = report
        self.shots = shots
    }

    var pageProblems: [String] {
        (phone.map { $0.problems.map { "[루프백 탭] \($0)" } } ?? []) + (tailnetTab.map { $0.problems.map { "[tailnet 탭] \($0)" } } ?? [])
    }

    func run() async throws {
        try await world.importFixtures()
        let browser = Browser(label: "루프백 탭", proxy: nil)
        phone = browser
        try await report.run(1, "페어링 전: 페어링 입력만 보이고 목록 요청은 403 not_paired") { try await unpaired($0, browser) }
        try await report.run(2, "#code= 링크: 코드를 미리 넣고 조각을 지우며 아무것도 보내지 않는다") { try await codeLink($0, browser) }
        try await report.run(3, "페어링 요청: Mac에 요청이 뜨고 페이지는 대기, 새로고침해도 이어 간다") { try await waiting($0, browser) }
        try await report.run(4, "Mac 거절: 안내가 보이고 새 코드로 다시 요청한다") { try await denied($0, browser) }
        try await report.run(5, "Mac 승인: 수락된 빌드만 목록에 보인다") { try await approved($0, browser) }
        try await report.run(6, "설치: 설치 주소의 출처가 페이지와 다르면 링크를 만들지 않는다") { try await refusedInstall($0, browser) }
        try await report.run(7, "설치: 같은 출처(http://<fqdn>:8080)면 설치 창 링크를 보여 준다") { try await trustedInstall($0) }
        try await report.run(8, "접근성: 이름, 알림 영역, 초점") { try await accessibility($0) }
        try await report.run(9, "어두운 모양") { try await dark($0, browser) }
        try await report.run(10, "정리") { try await cleanup($0) }
    }

    // MARK: 도우미

    private func shot(_ name: String, _ browser: Browser, _ s: Step) async {
        let url = shots.appendingPathComponent(name)
        do {
            try await browser.snapshot(to: url)
            report.write("W\(s.number) 스크린숏 \(url.path)")
        } catch {
            s.fail("스크린숏 \(name): \(error)")
        }
    }

    /// 보이는 버튼·입력·링크마다 접근 가능한 이름이 있는지 본다. 이름이 없는 요소의 설명 목록을 돌려준다.
    private func audit(_ stage: String, _ browser: Browser) async throws {
        let value = try await browser.js(#"""
        const visible = el => !el.closest('[hidden]') && el.getClientRects().length > 0;
        const text = el => (el ? String(el.textContent || '') : '').replace(/\s+/g, ' ').trim();
        const missing = [];
        for (const el of document.querySelectorAll('button, input, select, textarea, a[href], [role=button], [tabindex]:not([tabindex="-1"])')) {
          if (!visible(el)) continue;
          let name = (el.getAttribute('aria-label') || '').trim();
          if (!name && el.getAttribute('aria-labelledby')) name = el.getAttribute('aria-labelledby').split(/\s+/).map(id => text(document.getElementById(id))).join(' ').trim();
          if (!name && el.id) name = text(document.querySelector('label[for="' + CSS.escape(el.id) + '"]'));
          if (!name && el.closest('label')) name = text(el.closest('label'));
          if (!name && el.tagName !== 'INPUT') name = text(el);
          if (!name) name = (el.getAttribute('title') || '').trim();
          if (!name) missing.push(el.outerHTML.slice(0, 120));
        }
        for (const el of document.querySelectorAll('[aria-describedby]')) {
          for (const id of el.getAttribute('aria-describedby').split(/\s+/)) if (!document.getElementById(id)) missing.push('aria-describedby 대상 없음: ' + id);
        }
        if (!document.querySelector('main')) missing.push('main 영역 없음');
        if (!document.documentElement.lang) missing.push('html lang 없음');
        return missing;
        """#)
        audits.append((stage, value as? [String] ?? ["감사 결과를 읽지 못했다"]))
    }

    /// 화면이 바뀐 뒤 초점이 기대한 요소(선택자)에 있는지 기록한다. 8단계에서 판정한다.
    private func focus(_ what: String, _ browser: Browser, selector: String) async throws {
        let ok = try await browser.bool("const a = document.activeElement; return !!a && a !== document.body && a.matches(sel)", ["sel": selector])
        let actual = try await browser.string("const a = document.activeElement; return a ? (a.id ? '#' + a.id : a.outerHTML.slice(0, 80)) : '(없음)'")
        focusResults.append((what, ok, actual))
    }

    /// 사용자의 탭처럼 요소에 초점을 주고 누른다.
    private func tap(_ browser: Browser, _ selector: String, text: String? = nil, within: String? = nil) async throws {
        let ok = try await browser.bool(#"""
        const scope = within ? document.querySelector(within) : document;
        if (!scope) return false;
        const list = Array.from(scope.querySelectorAll(sel)).filter(el => !el.closest('[hidden]') && el.getClientRects().length > 0);
        const el = text == null ? list[0] : list.find(e => e.textContent.trim() === text);
        if (!el || el.disabled) return false;
        el.focus();
        el.click();
        return true;
        """#, ["sel": selector, "text": text ?? NSNull(), "within": within ?? NSNull()])
        if !ok { throw E2EError("\(browser.label): 누를 요소가 없다: \(selector) \(text ?? "")") }
    }

    private func setValue(_ browser: Browser, id: String, _ value: String) async throws {
        try await browser.js(#"""
        const el = document.getElementById(id);
        el.focus();
        el.value = value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        """#, ["id": id, "value": value])
    }

    private func probeElements(_ browser: Browser) async throws -> Int {
        let value = try await browser.js("return document.getElementsByClassName(cls).length", ["cls": WebWorld.probeClass])
        return (value as? NSNumber)?.intValue ?? -1
    }

    /// 조건이 시간 동안 계속 참인지 본다(‘보내지 않는다’ 같은 부재를 확인할 때). 거짓이 되면 바로 실패한다.
    private func holds(_ what: String, for duration: Duration, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            guard await condition() else { throw E2EError("계속 참이어야 하는데 거짓이 됐다: \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 페이지의 안내 문구(logic.js RDLogic.messages). 페이지 세계에서 읽는다. 없으면 던진다(빈 문구로 비교하면 무엇이든 지나간다).
    private func pageMessage(_ browser: Browser, _ key: String) async throws -> String {
        let value = try await browser.pageJS("return globalThis.RDLogic && RDLogic.messages ? String(RDLogic.messages['\(key)'] || '') : ''") as? String ?? ""
        guard !value.isEmpty else { throw E2EError("\(browser.label): RDLogic.messages.\(key)가 없다") }
        return value
    }

    /// 이 경로의 마지막 요청이 응답까지 기록될 때까지 기다린다(페이지의 처리와 기록 메시지는 순서가 정해져 있지 않다).
    private func answered(_ browser: Browser, _ method: String, _ path: String) async throws -> Browser.Fetch {
        try await until("\(browser.label): \(method) \(path) 응답이 기록된다") {
            browser.fetches(method) { $0 == path }.last.map { $0.status != nil || $0.failure != nil } ?? false
        }
        return browser.fetches(method) { $0 == path }.last!
    }

    private func apiFetches(_ browser: Browser) -> [Browser.Fetch] {
        browser.fetches.filter { $0.path.hasPrefix("/v1/") || $0.path.hasPrefix("/i/") }
    }

    // MARK: 1

    private func unpaired(_ s: Step, _ browser: Browser) async throws {
        let build = try world.descriptor()
        try await browser.load(URL(string: world.loopbackOrigin + "/")!)
        try await browser.waitForView("view-pair")

        // 문서 응답의 보안 헤더(addenda E.1).
        let response = browser.mainResponses.last
        s.equal(response?.statusCode, 200, "GET / 상태")
        s.equal(response?.value(forHTTPHeaderField: "Content-Security-Policy"),
                "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
                "Content-Security-Policy")
        s.equal(response?.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8", "Content-Type")
        s.equal(response?.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff", "X-Content-Type-Options")
        s.equal(response?.value(forHTTPHeaderField: "X-Frame-Options"), "DENY", "X-Frame-Options")
        s.equal(response?.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer", "Referrer-Policy")
        s.equal(response?.value(forHTTPHeaderField: "Cache-Control"), "no-store", "Cache-Control")
        // 브라우저가 CSP를 실제로 적용하는지: 페이지 세계의 eval은 막혀야 한다.
        let evalResult = try await browser.pageJS("try { eval('1'); return 'allowed'; } catch (e) { return String(e && e.name); }") as? String
        s.equal(evalResult, "EvalError", "페이지 세계의 eval이 CSP로 막힌다")

        // 코드 입력란: 한 번 쓰는 영숫자 코드에 맞는 속성.
        let attrs = try await browser.js(#"""
        const c = document.getElementById('code');
        const label = document.querySelector('label[for="code"]');
        return { inputmode: c.getAttribute('inputmode'), autocomplete: c.getAttribute('autocomplete'),
                 autocapitalize: c.getAttribute('autocapitalize'), autocorrect: c.getAttribute('autocorrect'),
                 spellcheck: c.getAttribute('spellcheck'), type: c.type, label: label ? label.textContent.trim() : null,
                 name: document.getElementById('device-name').value,
                 nameLabel: (document.querySelector('label[for="device-name"]') || {}).textContent,
                 submit: document.getElementById('pair-submit').textContent.trim(),
                 submitType: document.getElementById('pair-submit').type,
                 code: c.value };
        """#) as? [String: Any] ?? [:]
        s.equal(attrs["autocomplete"] as? String, "one-time-code", "코드 autocomplete")
        s.equal(attrs["autocapitalize"] as? String, "characters", "코드 autocapitalize")
        s.equal(attrs["autocorrect"] as? String, "off", "코드 autocorrect")
        s.equal(attrs["spellcheck"] as? String, "false", "코드 spellcheck")
        s.equal(attrs["type"] as? String, "text", "코드 type")
        let inputmode = attrs["inputmode"] as? String ?? ""
        s.check(!["numeric", "decimal", "tel", "none"].contains(inputmode), "코드 inputmode가 영숫자를 막지 않는다(\(inputmode))")
        s.equal(attrs["label"] as? String, "페어링 코드", "코드 레이블")
        s.equal(attrs["code"] as? String, "", "코드 입력란이 비어 있다")
        s.equal(attrs["name"] as? String, "iPhone(Safari)", "기기 이름 기본값")
        s.equal(attrs["submit"] as? String, "페어링 요청", "버튼 글자")
        s.equal(attrs["submitType"] as? String, "submit", "버튼이 폼을 보낸다")

        // 빌드 정보가 DOM 어디에도 없다.
        let html = try await browser.string("return document.documentElement.outerHTML")
        s.check(!html.contains(build.bundleId) && !html.contains(build.id), "DOM에 빌드 id·번들 id가 없다")
        s.check(!(try await browser.string("return document.body.innerText")).contains(build.displayName), "화면에 빌드 이름이 없다")
        s.equal(try await browser.string("return String(document.getElementById('build-list').children.length)"), "0", "목록 항목 수")
        s.equal(try await browser.string("return document.getElementById('notice').hidden ? 'hidden' : 'shown'"), "hidden", "처음 화면에는 오류 안내가 없다")

        // 페이지가 부른 API: GET /v1/builds 하나, 403 not_paired.
        _ = try await answered(browser, "GET", "/v1/builds")
        let calls = apiFetches(browser)
        s.equal(calls.map { "\($0.method) \($0.path)" }, ["GET /v1/builds"], "페이지의 API 요청")
        s.equal(calls.first?.status, 403, "GET /v1/builds 상태")
        s.equal(calls.first?.errorCode, "not_paired", "GET /v1/builds 오류 코드")
        s.equal(calls.first?.protocolHeader, "1", "GET /v1/builds X-RD-Protocol")
        try await until("Mac 활동에 denied(not_paired, /v1/builds)가 온다") { world.hasDenied(path: "/v1/builds", reason: "not_paired") }
        s.check(true, "Mac 활동에 denied(not_paired)가 남았다")
        s.check(mac.devices.isEmpty, "Mac 허용 목록이 비어 있다")
        try await audit("페어링 입력", browser)
        await shot("01-unpaired-form.png", browser, s)
    }

    // MARK: 2

    private func codeLink(_ s: Step, _ browser: Browser) async throws {
        await mac.beginPairing()
        s.equal(mac.lastError, nil, "beginPairing 오류")
        guard let code = mac.pairingCode?.code else { throw E2EError("Mac 페어링 코드가 없다: \(mac.pairingState)") }
        // 사용자가 받은 링크처럼 소문자·하이픈으로 쓴다. 페이지는 입력란에 대문자로 넣는다.
        let typed = (code.prefix(4) + "-" + code.dropFirst(4)).lowercased()
        let before = browser.fetches.count
        // 같은 문서의 조각 이동이 아니라 새 문서로 열리게 빈 문서를 거친다(링크를 새로 연 것과 같다).
        try await browser.load(URL(string: "about:blank")!)
        try await browser.load(URL(string: world.loopbackOrigin + "/#code=" + typed)!)
        try await browser.waitForView("view-pair")
        s.equal(try await browser.string("return document.getElementById('code').value"), typed.uppercased(), "코드 입력란에 미리 넣었다")
        s.equal(try await browser.string("return location.hash"), "", "location.hash가 비었다")
        s.equal(try await browser.string("return location.href"), world.loopbackOrigin + "/", "주소에 조각이 없다")
        s.equal(browser.webView.backForwardList.currentItem?.url.absoluteString, world.loopbackOrigin + "/", "방문 기록의 현재 항목에 조각이 없다")
        s.check(!browser.webView.backForwardList.backList.contains { $0.url.absoluteString.contains("#code=") }, "방문 기록에 코드가 든 주소가 남지 않는다")

        // 사용자가 누르기 전에는 페어링 요청을 보내지 않는다.
        try await holds("페어링 요청을 보내지 않는다", for: .seconds(2)) {
            !browser.fetches.dropFirst(before).contains { $0.method == "POST" } && mac.pendingPairRequests.isEmpty && mac.pairingCode?.code == code
        }
        let after = Array(browser.fetches.dropFirst(before)).filter { $0.path.hasPrefix("/v1/") }
        s.equal(after.map { "\($0.method) \($0.path)" }, ["GET /v1/builds"], "링크로 연 뒤 페이지의 API 요청")
        s.check(mac.pendingPairRequests.isEmpty, "Mac에 페어링 요청이 없다")
        s.check(mac.pairingCode?.code == code, "Mac의 코드가 아직 쓰이지 않았다")

        // 이미 열려 있는 탭에 새 링크가 들어오면(조각만 바뀐다) 같은 문서에서 코드를 채우고 조각을 지운다. 보내지는 않는다.
        let posts = browser.fetches.filter { $0.method == "POST" }.count
        try await browser.js("document.getElementById('code').value = ''; location.hash = '#code=' + c", ["c": code])
        try await browser.waitFor("조각이 바뀌면 코드를 채운다", "return document.getElementById('code').value === c", ["c": code])
        s.equal(try await browser.string("return location.href"), world.loopbackOrigin + "/", "조각이 바뀐 뒤 주소에 조각이 없다")
        s.check(!browser.webView.backForwardList.backList.contains { $0.url.absoluteString.contains("#code=") }, "조각이 바뀐 뒤 방문 기록에 코드가 든 주소가 없다")
        try await holds("조각이 바뀌어도 요청을 보내지 않는다", for: .seconds(1)) {
            browser.fetches.filter { $0.method == "POST" }.count == posts && mac.pendingPairRequests.isEmpty
        }
    }

    // MARK: 3

    private func waiting(_ s: Step, _ browser: Browser) async throws {
        guard let code = mac.pairingCode?.code else { throw E2EError("Mac 페어링 코드가 없다") }
        try await tap(browser, "#pair-submit")
        let request = try await world.waitForPairRequest(excluding: seenRequests)
        seenRequests.insert(request.requestId)
        s.equal(request.deviceName, "iPhone(Safari)", "Mac의 기기 이름")
        s.equal(request.nodeName, WebWorld.node, "Mac의 노드 이름")
        s.equal(mac.pairingState, .requestReceived(requestId: request.requestId), "Mac 페어링 단계")

        let post = browser.fetches("POST") { $0 == "/v1/pair/request" }.last
        let body = post?.body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        s.equal(body.map { Set($0.keys) }, ["code", "deviceName", "platform", "clientVersion"], "페어링 요청 본문 키")
        s.equal(body?["code"] as? String, code, "보낸 코드(정규화)")
        s.equal(body?["deviceName"] as? String, "iPhone(Safari)", "보낸 기기 이름")
        s.equal(body?["platform"] as? String, "Web", "보낸 플랫폼")
        s.equal(body?["clientVersion"] as? String, "web-1", "보낸 버전")
        s.equal(try await answered(browser, "POST", "/v1/pair/request").status, 202, "POST /v1/pair/request 상태")

        try await browser.waitForView("view-waiting")
        let waitingText = try await browser.string("return document.getElementById('waiting-text').textContent")
        s.check(waitingText.contains("iPhone(Safari)"), "대기 문구에 기기 이름: \(waitingText)")
        let countdown = try await browser.string("return document.getElementById('countdown').textContent")
        s.check(countdown.wholeMatch(of: /[0-2]:[0-5]\d/) != nil, "남은 시간 m:ss: \(countdown)")
        s.check((try await browser.string("return document.getElementById('countdown').getAttribute('aria-label') || ''")).hasPrefix("남은 시간"), "남은 시간의 읽기용 이름")
        s.check(try await browser.bool("const b = document.getElementById('pair-cancel'); return !!b && !b.closest('[hidden]') && b.textContent.trim() === '페어링 취소'"), "‘페어링 취소’ 버튼이 보인다")
        try await focus("대기 화면으로 바뀐 뒤", browser, selector: "#waiting-title")
        try await until("남은 시간이 줄어든다", timeout: .seconds(5)) {
            ((try? await browser.string("return document.getElementById('countdown').textContent")) ?? countdown) != countdown
        }
        s.check(true, "남은 시간이 줄어든다")
        try await audit("승인 대기", browser)
        await shot("02-waiting.png", browser, s)

        // 새로고침: sessionStorage의 요청 id로 대기를 이어 간다. 새 요청을 보내지 않는다.
        let stored = try await browser.string("return sessionStorage.getItem('rd.pairing') || ''")
        s.check(stored.contains(request.requestId), "sessionStorage에 요청 id가 있다")
        let before = browser.fetches.count
        try await browser.reload()
        try await browser.waitForView("view-waiting")
        try await until("새로고침 뒤 요청 상태를 묻는다") {
            browser.fetches.dropFirst(before).contains { $0.method == "GET" && $0.path == "/v1/pair/request/\(request.requestId)" && $0.status == 200 }
        }
        let afterReload = browser.fetches.dropFirst(before).filter { $0.path.hasPrefix("/v1/") }
        s.check(!afterReload.contains { $0.method == "POST" }, "새로고침 뒤 새 페어링 요청을 보내지 않는다")
        s.check(!afterReload.contains { $0.path == "/v1/builds" }, "새로고침 뒤 목록을 묻지 않고 대기를 잇는다")
        s.check(afterReload.allSatisfy { $0.path == "/v1/pair/request/\(request.requestId)" }, "새로고침 뒤 요청: \(afterReload.map(\.path))")
        s.check((try await browser.string("return document.getElementById('waiting-text').textContent")).contains("iPhone(Safari)"), "새로고침 뒤 대기 문구")
        s.equal(mac.pendingPairRequests.map(\.requestId), [request.requestId], "Mac의 대기 요청은 하나 그대로다")
    }

    // MARK: 4

    private func denied(_ s: Step, _ browser: Browser) async throws {
        guard let request = mac.pendingPairRequests.first(where: { seenRequests.contains($0.requestId) }) else {
            throw E2EError("거절할 요청이 없다")
        }
        await mac.deny(request.requestId)
        s.equal(mac.lastError, nil, "deny 오류")
        try await browser.waitForView("view-pair", timeout: .seconds(10))
        let expected = try await pageMessage(browser, "pairingDenied")
        s.check(expected.contains("거절"), "거절 문구: \(expected)")
        let notice = try await browser.js("const n = document.getElementById('notice'); return { text: n.textContent, hidden: n.hidden, role: n.getAttribute('role'), live: n.getAttribute('aria-live') }") as? [String: Any] ?? [:]
        s.equal(notice["text"] as? String, expected, "거절 안내")
        s.equal(notice["hidden"] as? Bool, false, "거절 안내가 보인다")
        s.check(notice["role"] is NSNull && notice["live"] is NSNull, "알림은 live region이 아니라 초점으로 알린다")
        s.equal(try await browser.string("return sessionStorage.getItem('rd.pairing') || ''"), "", "거절 뒤 저장한 대기 기록을 지웠다")
        try await focus("거절 뒤 페어링 화면으로 돌아왔을 때(안내로)", browser, selector: "#notice")
        try await audit("거절 안내", browser)
        await shot("03-denied.png", browser, s)

        // 같은 폼으로 새 코드를 넣어 다시 요청한다. 기기 이름에는 마크업 탐침을 넣는다(글자로만 보여야 한다).
        s.check(mac.pairingCode == nil, "쓰인 코드는 Mac에 더 보이지 않는다")
        await mac.beginPairing()
        guard let code = mac.pairingCode?.code else { throw E2EError("새 페어링 코드가 없다: \(mac.lastError ?? "")") }
        let probeName = "iPhone <b class=\"\(WebWorld.probeClass)\">웹</b>"
        try await setValue(browser, id: "code", (code.prefix(4) + " " + code.dropFirst(4)).lowercased())
        try await setValue(browser, id: "device-name", probeName)
        s.equal(try await browser.string("return document.getElementById('code').value"), (code.prefix(4) + " " + code.dropFirst(4)).uppercased(), "입력한 코드를 대문자로 바꾼다")
        try await tap(browser, "#pair-submit")
        let second = try await world.waitForPairRequest(excluding: seenRequests)
        seenRequests.insert(second.requestId)
        s.equal(second.deviceName, probeName, "Mac의 기기 이름(글자 그대로)")
        s.equal(second.nodeName, WebWorld.node, "Mac의 노드 이름")
        try await browser.waitForView("view-waiting")
        let waitingText = try await browser.string("return document.getElementById('waiting-text').textContent")
        s.check(waitingText.contains(probeName), "대기 문구에 기기 이름이 글자 그대로: \(waitingText)")
        s.equal(try await probeElements(browser), 0, "기기 이름이 마크업으로 해석되지 않는다")
        s.equal(try await browser.string("return document.getElementById('notice').hidden ? 'hidden' : 'shown'"), "hidden", "다시 요청하면 거절 안내를 지운다")
    }

    // MARK: 5

    private func approved(_ s: Step, _ browser: Browser) async throws {
        let build = try world.descriptor()
        guard let request = mac.pendingPairRequests.first(where: { seenRequests.contains($0.requestId) }) else {
            throw E2EError("승인할 요청이 없다")
        }
        await mac.approve(request.requestId)
        s.equal(mac.lastError, nil, "approve 오류")
        try await browser.waitForView("view-builds", timeout: .seconds(15))
        s.equal(mac.devices.map(\.nodeName), [WebWorld.node], "Mac 허용 목록")

        let items = try await browser.js(#"""
        return Array.from(document.querySelectorAll('#build-list > li')).map(li => ({
          id: li.getAttribute('data-build'),
          name: (li.querySelector('h3') || {}).textContent,
          detail: (li.querySelector('.detail') || {}).textContent,
          bundle: (li.querySelector('.bundle') || {}).textContent,
          warn: li.querySelector('.warn') ? li.querySelector('.warn').textContent : null }));
        """#) as? [[String: Any]] ?? []
        s.equal(world.notRejected, [], "Mac이 비디버그·배포·만료·무서명 픽스처를 모두 거부했다")
        s.equal(mac.builds.map(\.id), [build.id], "Mac의 게시 목록")
        s.equal(items.count, 1, "목록 항목 수")
        s.equal(items.first?["id"] as? String, build.id, "항목의 빌드 id")
        s.equal(items.first?["name"] as? String, build.displayName, "이름")
        s.equal(items.first?["detail"] as? String, "버전 \(build.version) (\(build.buildNumber)) · \(Self.pageSize(build.ipa.size))", "버전·크기")
        s.equal(items.first?["bundle"] as? String, build.bundleId, "번들 id")
        s.check(items.first?["warn"] is NSNull || items.first?["warn"] == nil, "만료 경고가 없다")

        let text = try await browser.string("return document.body.innerText")
        for refused in world.rejected {
            let name = URL(fileURLWithPath: refused.sourcePath).lastPathComponent
            if let bundle = refused.bundleId, bundle != build.bundleId {
                s.check(!text.contains(bundle), "거부된 \(name)의 번들 id가 화면에 없다")
            }
        }
        let list: Browser.Fetch? = try await answered(browser, "GET", "/v1/builds")
        s.equal(list?.status, 200, "승인 뒤 GET /v1/builds 상태")
        s.equal((list?.json?["builds"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [build.id], "호스트가 보낸 목록")

        // 아래쪽 Mac 이름(/v1/info). 호스트 이름에 넣은 마크업 탐침은 글자로만 보여야 한다.
        try await browser.waitFor("아래쪽에 Mac 이름이 보인다", "return document.getElementById('host-line').textContent.includes(' · ')")
        s.equal(try await browser.string("return document.getElementById('host-line').textContent"), "\(WebWorld.hostName) · \(world.fqdn)", "아래쪽 Mac 이름·주소")
        s.equal(try await probeElements(browser), 0, "서버가 보낸 글자가 마크업으로 해석되지 않는다")
        s.equal(try await browser.string("return sessionStorage.getItem('rd.pairing') || ''"), "", "승인 뒤 대기 기록을 지웠다")
        try await focus("승인 뒤 목록으로 바뀌었을 때", browser, selector: "#builds-title")
        try await audit("빌드 목록", browser)
        await shot("04-build-list.png", browser, s)
    }

    /// logic.js formatSize와 같은 규칙(1000 단위).
    static func pageSize(_ bytes: Int64) -> String {
        let b = max(bytes, 0)
        if b < 1000 { return "\(b)바이트" }
        if b < 1_000_000 { return "\(Int((Double(b) / 1000).rounded())) KB" }
        if b < 1_000_000_000 { return String(format: "%.1f MB", Double(b) / 1e6) }
        return String(format: "%.2f GB", Double(b) / 1e9)
    }

    // MARK: 6

    private func refusedInstall(_ s: Step, _ browser: Browser) async throws {
        let build = try world.descriptor()
        let item = "#build-list > li[data-build=\"\(build.id)\"]"
        try await tap(browser, "button", text: "설치", within: item)
        let expected = try await pageMessage(browser, "untrustedInstallURL")
        s.check(expected.contains("설치 주소"), "설치 주소 안내 문구: \(expected)")
        try await browser.waitFor("설치 주소를 믿지 않는다는 안내", timeout: .seconds(30),
                                  "const li = document.querySelector(sel); return !!li && li.querySelector('.install').textContent.includes(msg)",
                                  ["sel": item, "msg": expected])
        s.check(true, "안내: \(expected)")

        // 호스트는 세션을 만들었다(거절은 페이지의 확인에서 나왔다).
        let created: Browser.Fetch? = try await answered(browser, "POST", "/v1/builds/\(build.id)/sessions")
        s.equal(created?.status, 201, "POST /v1/builds/{id}/sessions 상태")
        let installUrl = created?.json?["installUrl"] as? String ?? ""
        let manifestUrl = created?.json?["manifestUrl"] as? String ?? ""
        s.check(installUrl.hasPrefix("itms-services://?action=download-manifest&url="), "호스트의 설치 주소 꼴")
        s.check(manifestUrl.hasPrefix(world.tailnetOrigin + "/i/"), "호스트의 매니페스트 출처는 tailnet 주소: \(manifestUrl.prefix(60))")
        let origin = try await browser.string("return location.origin")
        s.equal(origin, world.loopbackOrigin, "페이지 출처는 루프백(forward)")
        let sessionId = created?.json?["sessionId"] as? String ?? ""
        sessionFromRefusal = sessionId
        try await until("Mac 활동에 세션이 보인다") { world.session(sessionId) != nil }
        s.equal(world.session(sessionId)?.buildId, build.id, "Mac이 만든 세션의 빌드")
        s.equal(world.session(sessionId)?.nodeName, WebWorld.node, "Mac이 만든 세션의 노드")

        // itms-services 링크가 DOM 어디에도 없고, 페이지가 스스로 이동하지도 않았다.
        s.equal(try await browser.string("return String(document.querySelectorAll('a[href^=\"itms-services\" i], [href*=\"itms-services\" i]').length)"), "0", "itms-services 링크 수")
        s.check(!(try await browser.string("return document.documentElement.outerHTML")).contains("itms-services"), "DOM 글자에 itms-services가 없다")
        s.check(!browser.navigationRequests.contains { $0.lowercased().hasPrefix("itms-services") }, "itms-services로 이동하지 않았다")
        s.check(browser.events.contains { $0.kind == "live" && $0.detail.contains(expected) }, "설치 영역(aria-live)에 안내가 들어갔다")
        try await focus("설치가 거부된 뒤", browser, selector: "\(item) .install button")
        try await audit("설치 거부", browser)
        await shot("05-install-refused.png", browser, s)
    }

    // MARK: 7

    private func trustedInstall(_ s: Step) async throws {
        let build = try world.descriptor()
        let proxy = try ConnectProxy(allowedTarget: "\(world.fqdn):\(WebWorld.macPort)", upstreamPort: world.forwarder.port)
        self.proxy = proxy
        let tab = Browser(label: "tailnet 탭", proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!))
        tailnetTab = tab
        try await tab.load(URL(string: world.tailnetOrigin + "/")!)
        try await tab.waitForView("view-builds", timeout: .seconds(20))
        let origin = try await tab.string("return location.origin")
        s.equal(origin, world.tailnetOrigin, "페이지 출처는 Mac의 설치 주소 출처")
        let item = "#build-list > li[data-build=\"\(build.id)\"]"
        try await tap(tab, "button", text: "설치", within: item)
        try await tab.waitFor("‘설치 창 열기’ 링크가 보인다", timeout: .seconds(30),
                              "const a = document.querySelector(sel + ' a[href]'); return !!a && a.textContent.trim() === '설치 창 열기'", ["sel": item])
        let anchor = try await tab.js("const a = document.querySelector(sel + ' a[href]'); return { href: a.getAttribute('href'), label: a.getAttribute('aria-label') }", ["sel": item]) as? [String: Any] ?? [:]
        let href = anchor["href"] as? String ?? ""
        let prefix = "itms-services://?action=download-manifest&url="
        s.check(href.hasPrefix(prefix), "링크 꼴: \(href.prefix(60))")
        let manifest = String(href.dropFirst(prefix.count)).removingPercentEncoding ?? ""
        let created: Browser.Fetch? = try await answered(tab, "POST", "/v1/builds/\(build.id)/sessions")
        s.equal(created?.status, 201, "POST /v1/builds/{id}/sessions 상태")
        s.equal(created?.json?["installUrl"] as? String, href, "링크는 호스트가 준 설치 주소 그대로")
        s.equal(created?.json?["manifestUrl"] as? String, manifest, "링크의 매니페스트는 호스트의 manifestUrl")
        let base = origin + "/i/"
        let suffix = "/manifest.plist"
        let token = manifest.hasPrefix(base) && manifest.hasSuffix(suffix) ? String(manifest.dropFirst(base.count).dropLast(suffix.count)) : ""
        s.check(token.wholeMatch(of: /[A-Za-z0-9_-]{43}/) != nil, "매니페스트 주소 = location.origin + /i/<43자 토큰>/manifest.plist")
        s.equal(anchor["label"] as? String, "\(build.displayName) 설치 창 열기", "링크의 읽기용 이름")
        s.check(!tab.navigationRequests.contains { $0.lowercased().hasPrefix("itms-services") }, "링크를 누르지 않았고 페이지도 스스로 이동하지 않았다")
        s.check(proxy.records.count >= 1 && proxy.records.allSatisfy(\.allowed), "프록시의 CONNECT는 모두 \(world.fqdn):8080: \(proxy.records.map(\.requestLine))")
        if let id = created?.json?["sessionId"] as? String {
            try await until("Mac 활동에 세션이 보인다") { world.session(id) != nil }
            s.equal(world.session(id)?.nodeName, WebWorld.node, "Mac이 만든 세션의 노드")
        }
        try await focus("설치 링크가 생긴 뒤", tab, selector: "\(item) a[data-primary]")
        try await audit("설치 링크", tab)
        await shot("06-install-ready.png", tab, s)
        // 폴링을 멈춘다(설치 창을 기다리는 동안 ‘취소’).
        try await tap(tab, "button", text: "취소", within: item)
        try await tab.waitFor("취소하면 ‘설치’ 버튼으로 돌아간다", "const li = document.querySelector(sel); return !!li && !li.querySelector('a[href]') && Array.from(li.querySelectorAll('button')).some(b => b.textContent.trim() === '설치')", ["sel": item])

        // 설치 창을 기다리는 동안 Mac에서 이 기기를 제거하면 페이지는 페어링 화면으로 돌아가 이유를 알린다.
        try await tap(tab, "button", text: "설치", within: item)
        try await tab.waitFor("‘설치 창 열기’ 링크가 다시 보인다", timeout: .seconds(30), "return !!document.querySelector(sel + ' a[href]')", ["sel": item])
        guard let device = mac.devices.first else { throw E2EError("제거할 허용 기기가 없다") }
        await mac.removeDevice(device.id)
        try await tab.waitForView("view-pair", timeout: .seconds(20))
        s.equal(try await tab.string("return document.getElementById('notice').textContent"), try await pageMessage(tab, "not_paired"), "기기 제거 뒤 안내")
        try await focus("기기 제거 뒤 페어링 화면으로 돌아왔을 때(안내로)", tab, selector: "#notice")
        s.equal(try await tab.string("return String(document.querySelectorAll('#build-list > li').length)"), "0", "기기 제거 뒤 목록을 비웠다")
    }

    // MARK: 8

    private func accessibility(_ s: Step) async throws {
        s.check(audits.count >= 6, "접근성 확인을 한 화면 수: \(audits.map(\.0))")
        for (stage, missing) in audits {
            s.check(missing.isEmpty, "\(stage): 이름 없는 컨트롤·빠진 참조 없음 \(missing)")
        }
        for (what, ok, actual) in focusResults {
            s.check(ok, "초점: \(what) (실제 \(actual))")
        }
        guard let browser = phone else { return }
        // 페이지 알림(#notice)과 새로고침 실패 안내(#refresh-error)는 live region이 아니라 초점으로 알린다.
        // 보이게 되는 순간 글자를 넣은 live region은 읽히지 않는다.
        let focusable = try await browser.js("return ['notice', 'refresh-error'].map(id => { const e = document.getElementById(id); return !!e && e.getAttribute('tabindex') === '-1' && !e.hasAttribute('aria-live') && !e.hasAttribute('role'); })") as? [Bool] ?? []
        s.equal(focusable, [true, true], "#notice·#refresh-error는 초점으로 알린다(tabindex=-1, live 아님)")
        let announced = browser.events.filter { $0.kind == "live" }.map(\.detail)
        s.check(Set(announced).count >= 2, "상태가 바뀔 때 설치 영역 글자가 바뀌었다: \(announced.count)번")
        let fromHidden = browser.events.filter { $0.kind == "live" && ($0.fields["hidden"] as? Bool) == true }.map(\.detail)
        s.check(fromHidden.isEmpty, "숨겨져 있다가 글자와 함께 보이게 된 live region이 없다: \(fromHidden.prefix(3))")
    }

    // MARK: 9

    private func dark(_ s: Step, _ browser: Browser) async throws {
        let light = try await browser.string("return getComputedStyle(document.body).backgroundColor")
        browser.window.appearance = NSAppearance(named: .darkAqua)
        try await browser.waitFor("prefers-color-scheme: dark", timeout: .seconds(10), "return matchMedia('(prefers-color-scheme: dark)').matches")
        let darkColor = try await browser.string("return getComputedStyle(document.body).backgroundColor")
        s.check(darkColor != light, "어두운 모양에서 배경색이 바뀐다(\(light) → \(darkColor))")
        await shot("07-dark-build-list.png", browser, s)
        browser.window.appearance = NSAppearance(named: .aqua)
    }

    // MARK: 10

    func closeBrowsers() {
        phone?.close()
        tailnetTab?.close()
        proxy?.stop()
    }

    private func cleanup(_ s: Step) async throws {
        closeBrowsers()
        s.check(phone.map { !$0.window.isVisible } ?? true, "루프백 탭 창을 닫았다")
        s.check(tailnetTab.map { !$0.window.isVisible } ?? true, "tailnet 탭 창을 닫았다")
        if let proxy {
            let probe = await rawHTTPProbe(port: proxy.port, timeout: .seconds(2))
            s.check(probe != .timedOut && { if case .responded = probe { false } else { true } }(), "프록시 포트가 닫혔다: \(probe)")
        }
        await world.finish()
        s.check(!mac.isRunning, "Mac 공유가 멈췄다")
        s.check(!world.childrenRunning, "rdtestenv control·forward가 끝났다")
    }

    func writeLogs(to logs: URL) {
        var lines: [String] = []
        for (label, browser) in [("loopback", phone), ("tailnet", tailnetTab)] {
            guard let browser else { continue }
            for f in browser.fetches {
                lines.append("\(label) \(f.method) \(redactedToken(f.path)) → \(f.status.map(String.init) ?? f.failure ?? "?") \(f.errorCode ?? "")")
            }
            for e in browser.events where e.kind != "fetch" {
                lines.append("\(label) [\(e.kind)] \(e.detail.prefix(300))")
            }
        }
        if let proxy { lines += proxy.records.map { "proxy \($0.allowed ? "allow" : "deny") \($0.requestLine)" } }
        try? lines.joined(separator: "\n").write(to: logs.appendingPathComponent("browser.log"), atomically: true, encoding: .utf8)
    }

    private func redactedToken(_ path: String) -> String {
        path.hasPrefix("/i/") ? "/i/…" : path
    }
}
