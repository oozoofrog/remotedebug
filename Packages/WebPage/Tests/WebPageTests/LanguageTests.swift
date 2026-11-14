import Foundation
import JavaScriptCore
import Testing

/// 설치 페이지의 언어 고르기, 번역 찾기(고른 언어 → 영어 → 한국어 원문), 자리표시 채우기, 정적 문구 바꾸기.
@Suite struct LanguageTests {
    struct Pick: CustomTestStringConvertible, Sendable {
        let list: String  // JS 식
        let want: String
        var testDescription: String { "\(list) → \(want)" }
    }

    static let picks: [Pick] = [
        Pick(list: #"["ko-KR"]"#, want: "ko"),
        Pick(list: #"["ko"]"#, want: "ko"),
        Pick(list: #"["en-US"]"#, want: "en"),
        Pick(list: #"["ja-JP"]"#, want: "ja"),
        Pick(list: #"["zh-CN"]"#, want: "zh-Hans"),
        Pick(list: #"["zh-Hans-CN"]"#, want: "zh-Hans"),
        Pick(list: #"["zh"]"#, want: "zh-Hans"),
        Pick(list: #"["zh-TW"]"#, want: "zh-Hant"),
        Pick(list: #"["zh-HK"]"#, want: "zh-Hant"),
        Pick(list: #"["zh-MO"]"#, want: "zh-Hant"),
        Pick(list: #"["zh-Hant-TW"]"#, want: "zh-Hant"),
        Pick(list: #"["ZH_hant"]"#, want: "zh-Hant"),
        Pick(list: #"["EN_gb"]"#, want: "en"),
        Pick(list: #"["fr-FR"]"#, want: "en"),
        Pick(list: #"["fr", "ja"]"#, want: "ja"),
        Pick(list: #"["fr", "de", "ko-KR", "en"]"#, want: "ko"),
        Pick(list: #"["", null, "ja"]"#, want: "ja"),
        Pick(list: #"[]"#, want: "ko"),
        Pick(list: "undefined", want: "ko"),
        Pick(list: "null", want: "ko"),
    ]

    @Test(arguments: picks)
    func pickLanguage(_ p: Pick) throws {
        let js = try JSHarness()
        #expect(js.eval("RDLogic.pickLanguage(\(p.list))").toString() == p.want)
        try js.checkNoException()
    }

    @Test func setLanguageAcceptsOnlyKnownCodes() throws {
        let js = try JSHarness()
        #expect(js.eval("RDLogic.getLanguage()").toString() == "ko")
        #expect(js.eval("RDLogic.setLanguage('en')").toString() == "en")
        #expect(js.eval("RDLogic.setLanguage('fr')").toString() == "en")
        #expect(js.eval("RDLogic.setLanguage('zh-Hant')").toString() == "zh-Hant")
        #expect(js.eval("RDLogic.LANGUAGES.join()").toString() == "ko,en,ja,zh-Hans,zh-Hant")
    }

    /// 표 안의 번역을 바꾼 logic.js를 불러온다(시험용 번역 값). 표 밖의 코드는 그대로다.
    private func harness(patching edits: [String: [String: String]]) throws -> JSContext {
        let url = JSHarness.webDirectory.appending(path: "logic.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        let begin = try #require(source.range(of: "// RD-STRINGS-BEGIN\n"))
        let end = try #require(source.range(of: "// RD-STRINGS-END"))
        let block = String(source[begin.upperBound..<end.lowerBound])
        let open = try #require(block.firstIndex(of: "{"))
        let close = try #require(block.lastIndex(of: "}"))
        var table = try #require(JSONSerialization.jsonObject(with: Data(block[open...close].utf8)) as? [String: [String: String]])
        for (lang, values) in edits {
            for (key, value) in values {
                #expect(table[lang]?[key] != nil, "시험할 키가 표에 없다: \(key)")
                table[lang]?[key] = value
            }
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: table), as: UTF8.self)
        let patched = source.replacingCharacters(in: begin.upperBound..<end.lowerBound, with: "  var STRINGS = \(json);\n  ")
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, value in failure = value?.toString() }
        context.evaluateScript(patched, withSourceURL: url)
        #expect(failure == nil, "\(failure ?? "")")
        return context
    }

    @Test func fallbackChain() throws {
        let ctx = try harness(patching: [
            "ja": ["새로고침": "再読み込み"],
            "en": ["새로고침": "Refresh", "다시 시도": "Try again", "닫기": ""],
        ])
        func t(_ lang: String, _ key: String) -> String {
            ctx.evaluateScript("RDLogic.setLanguage('\(lang)'); RDLogic.t('\(key)')").toString()
        }
        #expect(t("ja", "새로고침") == "再読み込み")  // 고른 언어
        #expect(t("ja", "다시 시도") == "Try again")  // 영어
        #expect(t("ja", "닫기") == "닫기")  // 한국어 원문
        #expect(t("zh-Hans", "새로고침") == "Refresh")
        #expect(t("ko", "새로고침") == "새로고침")  // 한국어는 표를 보지 않는다
        #expect(t("en", "표에 없는 글자") == "표에 없는 글자")
        #expect(t("en", "constructor") == "constructor")
    }

    @Test func placeholders() throws {
        let js = try JSHarness()
        func t(_ expr: String) -> String { js.eval("RDLogic.t(\(expr))").toString() }
        #expect(t(#""{name} 설치", { name: "앱" }"#) == "앱 설치")
        #expect(t(#""{name} 설치", { name: "$& <b>" }"#) == "$& <b> 설치")
        #expect(t(#""{name} 설치", {}"#) == "{name} 설치")
        #expect(t(#""{a}{a} {b}", { a: 1, b: 0 }"#) == "11 0")
        #expect(t(#""{year}. {month}. {day}.", { year: 2020, month: 1, day: 1 }"#) == "2020. 1. 1.")
        js.eval("RDLogic.setLanguage('en')")
        #expect(t(#""{name} 설치", { name: "App" }"#) == "Install App")
        #expect(t(#""남은 시간 {minutes}분 {seconds}초", { minutes: 1, seconds: 5 }"#) == "1 min 5 s left")
        #expect(t(#""{name} 설치 취소", { name: "App" }"#) == "App 설치 취소")
    }

    /// 영어에서는 번역한 글자만 영어로, 나머지는 한국어로 보인다. 다른 언어(fr)는 영어와 같다.
    @Test func englishAndUnknownLanguages() throws {
        func render(_ languages: String?) throws -> [String] {
            let js = try JSHarness(withPage: true)
            if let languages {
                js.eval("RDPage.chooseLanguage({ languages: \(languages) })")
            } else {
                js.eval("RDPage.chooseLanguage(undefined)")
            }
            return [
                js.eval("RDLogic.getLanguage()").toString(),
                js.eval("RDLogic.remainingText(65000).label").toString(),
                js.eval("RDLogic.t('새로고침')").toString(),
                js.message("expired"),
                js.eval("RDLogic.formatSize(5)").toString(),
            ]
        }
        let english = try render(#"["en-US"]"#)
        #expect(english == ["en", "1 min 5 s left", "Refresh", "설치 세션이 만료되었습니다. 다시 설치하세요.", "5바이트"])
        var french = try render(#"["fr-FR"]"#)
        #expect(french.removeFirst() == "en")
        #expect(french == Array(english.dropFirst()))
        #expect(try render(nil) == ["ko", "남은 시간 1분 5초", "새로고침", "설치 세션이 만료되었습니다. 다시 설치하세요.", "5바이트"])
        #expect(try render(#"[]"#).first == "ko")
        // navigator.languages가 없으면 navigator.language를 본다.
        let js = try JSHarness(withPage: true)
        #expect(js.eval("RDPage.chooseLanguage({ language: 'ja-JP' })").toString() == "ja")
    }

    /// 화면 그리기 도움 함수도 언어를 따른다.
    @Test func installButtonFollowsLanguage() throws {
        let js = try JSHarness(withPage: true)
        js.eval("""
        function N(tag) { this.tagName = tag; this.children = []; this.attributes = {}; this.textContent = ""; }
        N.prototype.appendChild = function (c) { this.children.push(c); return c; };
        N.prototype.setAttribute = function (k, v) { this.attributes[k] = String(v); };
        N.prototype.addEventListener = function () {};
        var d = { createElement: function (t) { return new N(t); } };
        RDLogic.setLanguage('en');
        var b = RDPage.installArea(d, { id: "b_1", displayName: "Demo" }, null, {})[0];
        """)
        try js.checkNoException()
        #expect(js.eval("b.textContent").toString() == "Install")
        #expect(js.eval("b.attributes['aria-label']").toString() == "Install Demo")
    }

    /// index.html의 글자·속성 중 표에 있는 것만 바꾸고, 공백과 noscript·표에 없는 글자는 그대로 둔다.
    @Test func localizeStaticText() throws {
        let js = try JSHarness(withPage: true)
        js.eval("""
        function T(v) { this.nodeType = 3; this.nodeValue = v; }
        function E(tag, attrs, kids) { this.nodeType = 1; this.tagName = tag; this.attrs = attrs || {}; this.childNodes = kids || []; }
        E.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
        E.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
        var refresh = new T("  새로고침\\n");
        var plain = new T("빌드");
        var other = new T("RemoteDebug");
        var hidden = new T("다시 시도");
        var labelled = new E("button", { "aria-label": "다시 시도", "data-x": "다시 시도" }, [refresh]);
        var tree = new E("html", {}, [new E("main", {}, [labelled, new E("h2", {}, [plain]), new E("h1", {}, [other])]),
                                     new E("noscript", {}, [hidden])]);
        RDLogic.setLanguage('en');
        RDPage.localize(tree);
        """)
        try js.checkNoException()
        #expect(js.eval("refresh.nodeValue").toString() == "  Refresh\n")
        #expect(js.eval("plain.nodeValue").toString() == "빌드")
        #expect(js.eval("other.nodeValue").toString() == "RemoteDebug")
        #expect(js.eval("hidden.nodeValue").toString() == "다시 시도")
        #expect(js.eval("labelled.attrs['aria-label']").toString() == "Try again")
        #expect(js.eval("labelled.attrs['data-x']").toString() == "다시 시도")
    }
}
