import Foundation
import JavaScriptCore
import Testing

/// install.js의 요소 도움 함수를 가짜 DOM으로 검사한다. 글자는 textContent로만 들어가야 하고
/// innerHTML 같은 마크업 해석 경로는 쓰지 않아야 한다.
@Suite struct PageRenderTests {
    private static let fakeDOM = #"""
    var violations = [];
    function FakeNode(tag) { this.tagName = tag; this.children = []; this.attributes = {}; this.listeners = {}; this._text = ""; }
    FakeNode.prototype.appendChild = function (c) { this.children.push(c); return c; };
    FakeNode.prototype.setAttribute = function (k, v) { this.attributes[k] = String(v); };
    FakeNode.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; };
    FakeNode.prototype.addEventListener = function (t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); };
    FakeNode.prototype.click = function () { (this.listeners.click || []).forEach(function (f) { f({}); }); };
    Object.defineProperty(FakeNode.prototype, "textContent", {
      get: function () { return this._text + this.children.map(function (c) { return c.textContent; }).join(""); },
      set: function (v) { this._text = String(v); this.children = []; }
    });
    ["innerHTML", "outerHTML"].forEach(function (p) {
      Object.defineProperty(FakeNode.prototype, p, {
        get: function () { violations.push("get " + p); return ""; },
        set: function (v) { violations.push("set " + p); }
      });
    });
    FakeNode.prototype.insertAdjacentHTML = function () { violations.push("insertAdjacentHTML"); };
    var fakeDocument = { createElement: function (t) { return new FakeNode(t); }, write: function () { violations.push("write"); } };
    function all(node) { var out = [node]; node.children.forEach(function (c) { out = out.concat(all(c)); }); return out; }
    function byTag(node, tag) { return all(node).filter(function (n) { return n.tagName === tag; }); }
    var calls = [];
    var handlers = {
      install: function (b) { calls.push("install:" + b.id); },
      open: function (b) { calls.push("open:" + b.id); },
      cancel: function (b) { calls.push("cancel:" + b.id); },
      clear: function (b) { calls.push("clear:" + b.id); }
    };
    var hostile = "<img src=x onerror=alert(1)>";
    var build = {
      id: "b_9f3a1c2e", bundleId: "com.example.<script>", displayName: hostile, version: "1.4.0", buildNumber: "128",
      signing: { profileExpires: "2020-01-01T00:00:00Z" }, ipa: { size: 52428800 }
    };
    """#

    private func page() throws -> JSHarness {
        let js = try JSHarness(withPage: true)
        js.eval(Self.fakeDOM)
        try js.checkNoException()
        return js
    }

    /// RD_NO_AUTOSTART는 document와 fetch가 있어도 앱 시작을 막고, 없으면 시작해 document를 건드린다.
    @Test func autostartFollowsTheFlag() throws {
        let environment = """
        var touched = [];
        var document = { readyState: "complete",
          getElementById: function (id) { touched.push(id); return null; },
          addEventListener: function () { touched.push("listener"); } };
        var fetch = function () { touched.push("fetch"); return new Promise(function () {}); };
        var location = { hostname: "h", hash: "", pathname: "/", search: "", origin: "https://h" };
        """
        let source = try String(contentsOf: JSHarness.webDirectory.appending(path: "install.js"), encoding: .utf8)
        func touches(flag: Bool) throws -> Int32 {
            let js = try JSHarness()
            js.eval(environment + (flag ? "var RD_NO_AUTOSTART = true;" : ""))
            // 켜지 않으면 가짜 문서에 요소가 없어 시작 도중 예외가 난다. 시작했는지만 본다.
            js.eval("try {\n" + source + "\n} catch (e) {}")
            try js.checkNoException()
            return js.eval("touched.length").toInt32()
        }
        #expect(try touches(flag: true) == 0)
        #expect(try touches(flag: false) > 0)
    }

    @Test func exposesTheElementHelpers() throws {
        let js = try page()
        #expect(js.eval("typeof RDPage.buildItem").toString() == "function")
        #expect(js.eval("typeof RDPage.installArea").toString() == "function")
        #expect(js.eval("typeof RDPage.el").toString() == "function")
    }

    @Test func buildTextIsNotMarkup() throws {
        let js = try page()
        js.eval("var item = RDPage.buildItem(fakeDocument, build, null, Date.now(), handlers);")
        try js.checkNoException()
        #expect(js.eval("item.tagName").toString() == "li")
        #expect(js.eval("byTag(item, 'h3')[0].textContent").toString() == "<img src=x onerror=alert(1)>")
        #expect(js.eval("byTag(item, 'img').length").toInt32() == 0)
        #expect(js.eval("all(item).some(function (n) { return n.textContent === 'com.example.<script>'; })").toBool())
        #expect(js.eval("all(item).some(function (n) { return /프로비저닝 프로파일이 2020. 1. 1.에 만료/.test(n._text); })").toBool())
        #expect(js.eval("violations.length").toInt32() == 0, "\(js.eval("violations.join(',')").toString() ?? "")")
        // 설치 버튼: 실제 버튼이고, 읽기 이름에 빌드 이름이 들어가며, 누르면 install을 부른다.
        let button = "byTag(item, 'button')[0]"
        #expect(js.eval("\(button).textContent").toString() == "설치")
        #expect(js.eval("\(button).type").toString() == "button")
        #expect(js.eval("\(button).getAttribute('aria-label')").toString() == "<img src=x onerror=alert(1)> 설치")
        js.eval("\(button).click()")
        #expect(js.eval("calls.join()").toString() == "install:b_9f3a1c2e")
    }

    @Test func waitingOffersARealLink() throws {
        let js = try page()
        js.eval("""
        var href = "itms-services://?action=download-manifest&url=https%3A%2F%2Fh.ts.net%2Fi%2Ft%2Fmanifest.plist";
        var nodes = RDPage.installArea(fakeDocument, build, { kind: "waiting", sessionId: "s_1", href: href, opened: false, deadline: 1 }, handlers);
        var root = RDPage.el(fakeDocument, "div", null, nodes);
        var link = byTag(root, "a")[0];
        """)
        try js.checkNoException()
        #expect(js.eval("link.getAttribute('href') === href").toBool())
        #expect(js.eval("link.textContent").toString() == "설치 창 열기")
        #expect(js.eval("root.textContent.indexOf('설치 창에서 ‘설치’를 누르세요') >= 0").toBool())
        #expect(js.eval("byTag(root, 'button').map(function (b) { return b.textContent; }).join()").toString() == "취소")
        js.eval("link.click(); byTag(root, 'button')[0].click();")
        #expect(js.eval("calls.join()").toString() == "open:b_9f3a1c2e,cancel:b_9f3a1c2e")
        js.eval("""
        var again = RDPage.el(fakeDocument, "div", null, RDPage.installArea(fakeDocument, build, { kind: "waiting", sessionId: "s_1", href: href, opened: true, deadline: 1 }, handlers));
        """)
        #expect(js.eval("byTag(again, 'a')[0].textContent").toString() == "다시 열기")
        #expect(js.eval("violations.length").toInt32() == 0)
    }

    @Test func otherStates() throws {
        let js = try page()
        func render(_ state: String) -> String {
            js.eval("RDPage.el(fakeDocument, 'div', null, RDPage.installArea(fakeDocument, build, \(state), handlers)).textContent").toString()
        }
        #expect(render("{ kind: 'preparing' }") == "Mac이 빌드를 확인하는 중")
        #expect(render("{ kind: 'transferring', bytesServed: 10485760, size: 52428800 }") == "전송 중 10.5 MB / 52.4 MB")
        let done = render("{ kind: 'completed' }")
        #expect(done.contains("전송 완료"))
        #expect(done.contains(js.message("developerModeHint")))
        #expect(done.hasSuffix("확인"))
        let failed = render("{ kind: 'failed', message: '<b>x</b>' }")
        #expect(failed == "<b>x</b>다시 설치닫기")
        #expect(js.eval("violations.length").toInt32() == 0)
        try js.checkNoException()
    }
}
