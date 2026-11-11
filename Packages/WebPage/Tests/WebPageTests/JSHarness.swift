import Foundation
import JavaScriptCore
import Testing

/// core/internal/host/web 아래 파일을 불러 둔 JavaScriptCore 문맥. 테스트마다 새로 만든다.
final class JSHarness {
    let context: JSContext
    private let errors = ErrorBox()

    private final class ErrorBox { var messages: [String] = [] }

    static let webDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // WebPageTests, Tests, WebPage, Packages, 파일 이름
        return url.appending(path: "core/internal/host/web", directoryHint: .isDirectory)
    }()

    /// logic.js를 불러온다. `withPage`면 RD_NO_AUTOSTART를 켠 뒤 install.js도 불러온다.
    init(withPage: Bool = false) throws {
        context = JSContext()!
        let box = errors
        context.exceptionHandler = { _, value in
            box.messages.append(value?.toString() ?? "exception")
        }
        try load("logic.js")
        if withPage {
            context.evaluateScript("var RD_NO_AUTOSTART = true;")
            try load("install.js")
        }
    }

    func load(_ name: String) throws {
        let url = Self.webDirectory.appending(path: name)
        let source = try String(contentsOf: url, encoding: .utf8)
        context.evaluateScript(source, withSourceURL: url)
        try checkNoException()
    }

    func checkNoException(sourceLocation: SourceLocation = #_sourceLocation) throws {
        if !errors.messages.isEmpty {
            let text = errors.messages.joined(separator: "\n")
            errors.messages = []
            Issue.record("JavaScript exception: \(text)", sourceLocation: sourceLocation)
            throw JSError.exception(text)
        }
    }

    enum JSError: Error { case exception(String) }

    var logic: JSValue { context.objectForKeyedSubscript("RDLogic") }

    /// RDLogic의 함수를 부른다.
    @discardableResult
    func call(_ name: String, _ args: Any...) -> JSValue {
        let fn = logic.objectForKeyedSubscript(name)!
        precondition(!fn.isUndefined, "RDLogic.\(name) is missing")
        return fn.call(withArguments: args)
    }

    func message(_ key: String) -> String {
        logic.objectForKeyedSubscript("messages").objectForKeyedSubscript(key).toString()
    }

    @discardableResult
    func eval(_ script: String) -> JSValue {
        context.evaluateScript(script)
    }
}

extension JSValue {
    /// 객체의 문자열 속성. 없거나 null이면 nil.
    func string(_ key: String) -> String? {
        let v = objectForKeyedSubscript(key)!
        return v.isUndefined || v.isNull ? nil : v.toString()
    }

    func value(_ key: String) -> JSValue { objectForKeyedSubscript(key) }
}
