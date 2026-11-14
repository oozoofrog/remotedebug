import AppKit
import CoreGraphics
import Network
import WebKit

/// 화면 밖 NSWindow 안의 WKWebView 하나(390×844, 모바일 Safari UA, 저장하지 않는 데이터 저장소).
///
/// 문서 시작 때 넣는 사용자 스크립트가 페이지의 JS 오류, 처리되지 않은 Promise 거부, console.error, CSP 위반,
/// 페이지가 부른 fetch(요청·응답 상태·본문 앞부분)를 Swift로 보낸다. 새로고침해도 기록은 이어진다.
@MainActor
final class Browser: NSObject, WKNavigationDelegate {
    static let viewport = NSSize(width: 390, height: 844)
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

    /// 페이지 세계에서 일어난 일 하나.
    struct Event {
        var kind: String
        var fields: [String: Any]
        var detail: String { fields["detail"] as? String ?? "" }
    }

    /// fetch 하나(요청과 그 결과).
    struct Fetch {
        var method: String
        var url: String
        var path: String
        var body: String?
        var status: Int?
        var protocolHeader: String?
        var text: String?
        var failure: String?

        var json: [String: Any]? { text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
        var errorCode: String? { (json?["error"] as? [String: Any])?["code"] as? String }
    }

    let window: NSWindow
    let webView: WKWebView
    let label: String
    private(set) var events: [Event] = []
    private(set) var mainResponses: [HTTPURLResponse] = []
    private(set) var navigationFailures: [String] = []
    private(set) var finishedNavigations = 0
    private let trampoline = MessageTrampoline()
    private var closed = false

    /// 페이지가 스스로 보고하는 문제(JS 오류, 거부, console.error, CSP 위반, 리소스 실패). `eval` 탐침의 CSP 위반은 뺀다.
    var problems: [String] {
        events.compactMap { e in
            switch e.kind {
            case "csp" where (e.fields["blockedURI"] as? String) == "eval": return nil
            case "js-error", "unhandledrejection", "console-error", "csp", "resource-error": return "\(e.kind): \(e.detail)"
            default: return nil
            }
        }
    }

    var cspEvalViolations: Int {
        events.filter { $0.kind == "csp" && ($0.fields["blockedURI"] as? String) == "eval" }.count
    }

    /// 지금까지 페이지가 부른 fetch. 응답이 오면 같은 항목을 채운다.
    private(set) var fetches: [Fetch] = []
    private var pendingFetch: [String: Int] = [:]

    init(label: String, proxy: NWEndpoint?) {
        self.label = label
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        if let proxy {
            store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: proxy)]
        }
        configuration.websiteDataStore = store
        // 화면에 보이지 않는 창이어도 타이머(1초 폴링·남은 시간)를 늦추지 않는다.
        configuration.preferences.inactiveSchedulingPolicy = .none
        let content = WKUserContentController()
        // 페이지는 브라우저의 선호 언어로 글자를 바꾼다. 이 시험은 한국어 문구를 비교하므로 Mac의 언어 설정과 상관없이 한국어로 고정한다.
        content.addUserScript(WKUserScript(source: Self.koreanLanguageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        content.addUserScript(WKUserScript(source: Self.recorderScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        content.add(trampoline, contentWorld: .page, name: "rdRecorder")
        configuration.userContentController = content
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.viewport), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        // 화면 밖 좌표의 테두리 없는 창. 사용자의 화면에 나타나지 않는다.
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: Self.viewport),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        trampoline.owner = self
        window.orderFrontRegardless()
    }

    func close() {
        guard !closed else { return }
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        window.contentView = nil
        window.orderOut(nil)
        window.close()
        trampoline.owner = nil
    }

    // MARK: 탐색

    /// 주소를 열고 탐색이 끝날 때까지 기다린다.
    func load(_ url: URL, timeout: Duration = .seconds(30)) async throws {
        let before = finishedNavigations
        let failures = navigationFailures.count
        webView.load(URLRequest(url: url))
        try await until("\(label): \(url) 탐색이 끝난다", timeout: timeout) {
            self.finishedNavigations > before || self.navigationFailures.count > failures
        }
        if navigationFailures.count > failures { throw E2EError("\(label): \(url) 탐색 실패: \(navigationFailures.last!)") }
    }

    func reload(timeout: Duration = .seconds(30)) async throws {
        let before = finishedNavigations
        let failures = navigationFailures.count
        webView.reload()
        try await until("\(label): 새로고침이 끝난다", timeout: timeout) {
            self.finishedNavigations > before || self.navigationFailures.count > failures
        }
        if navigationFailures.count > failures { throw E2EError("\(label): 새로고침 실패: \(navigationFailures.last!)") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedNavigations += 1
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailures.append(String(describing: error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailures.append(String(describing: error))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            mainResponses.append(http)
        }
        return .allow
    }

    /// 페이지가 스스로 다른 곳(예: itms-services)으로 가려 하면 기록한다. 이 시험의 사용자는 링크를 누르지 않는다.
    private(set) var navigationRequests: [String] = []

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url?.absoluteString ?? ""
        navigationRequests.append(url)
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        return scheme == "http" || scheme == "https" || scheme == "about" ? .allow : .cancel
    }

    // MARK: 스크립트

    /// 시험 전용 격리 세계에서 함수 본문을 돌린다. DOM은 같고 페이지의 전역·CSP와는 섞이지 않는다.
    @discardableResult
    func js(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    /// 페이지 세계(페이지의 CSP가 적용되는 곳)에서 돌린다.
    @discardableResult
    func pageJS(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    func string(_ body: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let value = try await js(body, arguments)
        return value as? String ?? (value.map { String(describing: $0) } ?? "")
    }

    func bool(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Bool {
        let value = try await js(body, arguments)
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }

    /// 조건(JS 본문이 true를 돌려줌)이 될 때까지 기다린다.
    func waitFor(_ what: String, timeout: Duration = .seconds(20), _ body: String, _ arguments: [String: Any] = [:]) async throws {
        try await until("\(label): \(what)", timeout: timeout) {
            (try? await self.bool(body, arguments)) ?? false
        }
    }

    /// 보이는 화면(section) id. 하나가 아니면 쉼표로 잇는다.
    func visibleView() async throws -> String {
        try await string("return Array.from(document.querySelectorAll('main > section')).filter(s => !s.hidden).map(s => s.id).join(',')")
    }

    func waitForView(_ id: String, timeout: Duration = .seconds(20)) async throws {
        do {
            try await waitFor("\(id)만 보인다", timeout: timeout,
                              "return Array.from(document.querySelectorAll('main > section')).filter(s => !s.hidden).map(s => s.id).join(',') === id",
                              ["id": id])
        } catch {
            let shown = (try? await visibleView()) ?? "?"
            let text = (try? await string("return document.body ? document.body.innerText : ''")) ?? ""
            throw E2EError("\(error) (보이는 화면: \(shown), 본문: \(text.prefix(600)))")
        }
    }

    // MARK: 스크린숏

    func snapshot(to url: URL) async throws {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: Self.viewport)
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw E2EError("\(label): 스크린숏을 PNG로 바꾸지 못했다")
        }
        try png.write(to: url)
    }

    // MARK: 기록

    fileprivate func receive(_ body: Any) {
        guard let object = body as? [String: Any], let kind = object["kind"] as? String else { return }
        events.append(Event(kind: kind, fields: object))
        guard kind == "fetch", let seq = (object["seq"] as? NSNumber)?.intValue else { return }
        let key = "\(object["doc"] as? String ?? "")/\(seq)"
        switch object["phase"] as? String {
        case "request":
            let url = object["url"] as? String ?? ""
            let path = URLComponents(string: url).map { $0.percentEncodedPath } ?? url
            pendingFetch[key] = fetches.count
            fetches.append(Fetch(method: object["method"] as? String ?? "GET", url: url, path: path.isEmpty ? url : path,
                                 body: object["body"] as? String))
        case "response":
            guard let index = pendingFetch.removeValue(forKey: key) else { return }
            fetches[index].status = (object["status"] as? NSNumber)?.intValue
            fetches[index].protocolHeader = object["protocol"] as? String
            fetches[index].text = object["text"] as? String
        case "failure":
            guard let index = pendingFetch.removeValue(forKey: key) else { return }
            fetches[index].failure = object["detail"] as? String ?? "?"
        default:
            break
        }
    }

    func fetches(_ method: String, _ path: (String) -> Bool) -> [Fetch] {
        fetches.filter { $0.method == method && path($0.path) }
    }

    /// 사용자 스크립트. navigator.languages·language를 한국어로 둔다(페이지의 언어 고르기가 한국어를 고른다).
    static let koreanLanguageScript = #"""
    (function () {
      try {
        Object.defineProperty(navigator, "languages", { configurable: true, get: function () { return ["ko-KR"]; } });
        Object.defineProperty(navigator, "language", { configurable: true, get: function () { return "ko-KR"; } });
      } catch (e) {}
    })();
    """#

    /// 사용자 스크립트. 페이지 세계에서 문서보다 먼저 돈다(페이지의 CSP는 사용자 스크립트를 막지 않는다).
    static let recorderScript = #"""
    (function () {
      "use strict";
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rdRecorder;
      var doc = Math.random().toString(36).slice(2) + Date.now().toString(36);
      function post(o) { try { o.page = String(location.href); o.doc = doc; handler.postMessage(o); } catch (e) {} }
      window.addEventListener("error", function (e) {
        if (e.target && e.target !== window) {
          post({ kind: "resource-error", detail: String(e.target.tagName) + " " + String(e.target.src || e.target.href || "") });
          return;
        }
        post({ kind: "js-error", detail: String(e.message) + " @" + String(e.filename) + ":" + String(e.lineno) });
      }, true);
      window.addEventListener("unhandledrejection", function (e) {
        var r = e.reason;
        post({ kind: "unhandledrejection", detail: String(r && (r.stack || r.message) || r) });
      });
      document.addEventListener("securitypolicyviolation", function (e) {
        post({ kind: "csp", detail: String(e.violatedDirective) + " blocked " + String(e.blockedURI) + " in " + String(e.sourceFile) + ":" + String(e.lineNumber),
               blockedURI: String(e.blockedURI), directive: String(e.violatedDirective) });
      });
      // 읽기 도구가 알릴 영역(aria-live, role=status/alert)의 글자가 바뀌면 그 글자를 남긴다.
      new MutationObserver(function (records) {
        var seen = [];
        records.forEach(function (r) {
          var el = r.target && (r.target.nodeType === 1 ? r.target : r.target.parentElement);
          var region = el && el.closest && el.closest("[aria-live], [role=status], [role=alert]");
          if (!region || region.getAttribute("aria-live") === "off" || seen.indexOf(region) >= 0) return;
          seen.push(region);
          var text = String(region.textContent || "").trim();
          if (text) post({ kind: "live", detail: text, id: String(region.id || region.className || region.tagName), hidden: !!region.closest("[hidden]") });
        });
      }).observe(document, { childList: true, subtree: true, characterData: true });
      var consoleError = console.error;
      console.error = function () {
        post({ kind: "console-error", detail: Array.prototype.map.call(arguments, String).join(" ") });
        return consoleError.apply(console, arguments);
      };
      var originalFetch = window.fetch;
      var seq = 0;
      window.fetch = function (input, init) {
        var n = ++seq;
        var method = String((init && init.method) || (input && input.method) || "GET").toUpperCase();
        var url = new URL(String((input && input.url) || input), location.href).href;
        var body = init && typeof init.body === "string" ? init.body : null;
        post({ kind: "fetch", phase: "request", seq: n, method: method, url: url, body: body });
        return originalFetch.apply(this, arguments).then(function (res) {
          res.clone().text().then(function (text) {
            post({ kind: "fetch", phase: "response", seq: n, status: res.status, protocol: res.headers.get("X-RD-Protocol"), text: text.slice(0, 8192) });
          }, function () {
            post({ kind: "fetch", phase: "response", seq: n, status: res.status, protocol: res.headers.get("X-RD-Protocol"), text: null });
          });
          return res;
        }, function (err) {
          post({ kind: "fetch", phase: "failure", seq: n, detail: String(err) });
          throw err;
        });
      };
    })();
    """#
}

/// WKUserContentController는 처리기를 강하게 붙잡는다. 순환을 끊으려고 약한 참조로 넘긴다.
@MainActor
private final class MessageTrampoline: NSObject, WKScriptMessageHandler {
    weak var owner: Browser?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message.body)
    }
}

/// 이 프로세스가 창 서버(GUI 로그인 세션)에 닿는지. 닿지 않으면 WKWebView는 그리지 못한다.
enum GUISession {
    static func check() throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            throw E2EError("GUI 로그인 세션이 없습니다(CGSessionCopyCurrentDictionary가 nil). WKWebView 시험은 로그인한 Mac의 GUI 세션에서 돌려야 합니다. SSH·launchd 백그라운드에서는 돌릴 수 없습니다.")
        }
        if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole {
            throw E2EError("이 GUI 세션이 콘솔에 있지 않습니다(빠른 사용자 전환 뒤 등). 화면 앞의 사용자 세션에서 돌리세요.")
        }
    }
}
