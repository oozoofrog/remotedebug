import Foundation
import RDModels

/// 공개 저장소에 올라갈 수 있는 글에서 사람이나 기기를 가리킬 수 있는 값을 가린다.
/// 이슈에 넣는 글(사용자가 쓴 글, 확인 목록의 제목·답·메모)은 모두 여기를 지난다.
public enum FeedbackScrubber {
    public static let mailMask = "[메일]"
    public static let urlMask = "[주소]"
    public static let hostMask = "[호스트]"
    public static let pathMask = "[경로]"
    public static let addressMask = "[IP]"
    public static let numberMask = "[번호]"

    public static func scrub(_ text: String) -> String {
        var text = text
        // 쿼리나 로그인 정보가 든 주소는 통째로 가린다(토큰, 세션 값이 여기에 실린다).
        text = replace(#"[a-z][a-z0-9+.\-]*://[^\s<>"'\])]+"#, in: text, with: urlMask) { found in
            guard let scheme = found.range(of: "://") else { return false }
            let authority = found[scheme.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            return found.contains("?") || authority.contains("@")
        }
        text = replace(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, in: text, with: mailMask)
        // tailnet 이름과 RemoteDebug 노드 이름.
        text = replace(#"[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.ts\.net"#, in: text, with: hostMask)
        text = replace(#"\brd-(?:mac|phone)-[a-z0-9]+\b"#, in: text, with: hostMask)
        // 사용자 폴더가 드러나는 경로.
        text = replace(#"(?:~|/Users|/home|/Volumes|/private/var|/var/mobile)/[^\s"'<>)]+"#, in: text, with: pathMask)
        // IPv6: 모양이 비슷한 것(시각 12:30:45 등)은 실제 주소일 때만 가린다.
        text = replace(#"(?<![0-9a-z:.])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![0-9a-z:])"#, in: text, with: addressMask) { found in
            var buffer = in6_addr()
            return inet_pton(AF_INET6, found, &buffer) == 1
        }
        text = replace(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?!\.?\d)"#, in: text, with: addressMask)
        // 전화번호처럼 보이는 숫자열(숫자 9개 이상, 사이에 빈칸·붙임표·점·괄호).
        text = replace(#"(?<![A-Za-z0-9_:.,/\-])(?:\+|\()?\d(?:[ ().\-]{0,2}\d){8,}(?![0-9:])"#, in: text, with: numberMask)
        // GitHub이 `@이름`으로 사람에게 알림을 보내지 않게 한다.
        text = replace(#"@(?=[A-Za-z0-9_])"#, in: text, with: "@\u{200B}")
        return text
    }

    private static func replace(_ pattern: String, in text: String, with mask: String,
                                where matches: (String) -> Bool = { _ in true }) -> String {
        // 패턴은 위의 상수뿐이고 시험이 모두 지난다.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return mask }
        let source = text as NSString
        var out = "", last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard matches(source.substring(with: match.range)) else { continue }
            out += source.substring(with: NSRange(location: last, length: match.range.location - last)) + mask
            last = match.range.location + match.range.length
        }
        return out + source.substring(from: last)
    }
}

/// 이슈를 올릴 GitHub 저장소(`owner/repo`).
public enum IssueTarget {
    /// `owner/repo` 모양으로 고친다. 저장소 주소(https, ssh)를 넣어도 된다. 모양이 아니면 `nil`.
    public static func normalized(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromURL = fromRemote(text) { return fromURL }
        return text.wholeMatch(of: /[A-Za-z0-9](?:[A-Za-z0-9\-]{0,38})\/[A-Za-z0-9._\-]{1,100}/) == nil ? nil : text
    }

    /// `git remote get-url origin`의 값이 github.com 저장소면 `owner/repo`. 다른 곳이면 `nil`.
    public static func fromRemote(_ remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:", "git://github.com/"]
        guard let prefix = prefixes.first(where: { text.lowercased().hasPrefix($0) }) else { return nil }
        text.removeFirst(prefix.count)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text.wholeMatch(of: /[A-Za-z0-9](?:[A-Za-z0-9\-]{0,38})\/[A-Za-z0-9._\-]{1,100}/) == nil ? nil : text
    }

    /// 프로젝트 폴더의 `origin` 주소. git 저장소가 아니거나 origin이 없으면 `nil`.
    public static let originURL: @Sendable (URL) async -> String? = { folder in
        let result = await PhoneAppTools.run("/usr/bin/git", ["-C", folder.path, "remote", "get-url", "origin"], log: nil)
        let line = result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return result.code == 0 && !line.isEmpty ? line : nil
    }
}

/// 이슈로 올릴 제목과 본문.
public struct FeedbackIssueDraft: Sendable, Hashable, Codable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// 받은 피드백 하나에서 이슈의 제목과 본문을 만든다.
///
/// 저장소가 공개일 수 있어 넣을 것만 정해 둔다: 사용자가 쓴 글, 앱 버전과 빌드, OS 버전, 기기 종류, 받은 시각,
/// 확인 목록의 답(제목, 고른 답, 메모), 첨부 수와 로그가 붙었는지. 로그 줄, 첨부 파일과 그 이름, 기기 이름,
/// 번들 ID, 기록의 파일 경로는 넣지 않는다.
public enum FeedbackIssue {
    public static let titleLimit = 80
    public static let messageLimit = 4000
    static let noteLimit = 800
    public static let emptyTitle = "앱에서 온 피드백"
    public static let emptyMessage = "(글 없이 보낸 피드백입니다.)"
    public static let footer = "RemoteDebug가 앱 안 피드백에서 등록했습니다. 로그와 첨부 파일은 개발자의 Mac에만 있고 여기에는 올리지 않습니다."
    /// 있으면 붙이는 라벨. 저장소에 없으면 라벨 없이 올린다.
    public static let label = "feedback"

    /// 기록의 원문에서 읽어 낸 것.
    struct Facts: Equatable {
        var message = ""
        var system = ""
        var device = ""
        var hasLogs = false
        var checks: [Answer] = []
    }

    struct Answer: Equatable {
        var title: String
        var answer: String
        var note: String
    }

    public static func draft(item: CrashLogStore.Item, text: String) -> FeedbackIssueDraft {
        let facts = item.isImported ? importedFacts(text) : directFacts(item: item, text: text)
        let message = clip(FeedbackScrubber.scrub(facts.message.trimmingCharacters(in: .whitespacesAndNewlines)), messageLimit)
        let version = plain(item.appVersion)
        let firstLine = message.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let title = firstLine.isEmpty ? (version.isEmpty ? emptyTitle : "\(emptyTitle) · \(version)") : clip(firstLine, titleLimit)

        let attachments = (item.attachments?.count ?? 0) + (item.imageFile == nil ? 0 : 1)
        var lines = [message.isEmpty ? emptyMessage : message, "", "## 환경"]
        if !version.isEmpty { lines.append("- 앱 버전: \(version)") }
        let system = plain(facts.system), device = plain(facts.device)
        if !system.isEmpty { lines.append("- OS: \(system)") }
        if !device.isEmpty { lines.append("- 기기: \(device)") }
        lines.append("- 받은 시각: \(item.receivedAt.formatted(Date.ISO8601FormatStyle()))")
        lines.append("- 첨부: \(attachments)개")
        lines.append("- 로그: \(facts.hasLogs ? "붙어 있음" : "없음")")
        let answered = facts.checks.filter { !$0.answer.isEmpty || !$0.note.isEmpty }
        if !answered.isEmpty {
            lines += ["", "## 확인 목록의 답"]
            for check in answered {
                let answer = oneLine(check.answer, 120), title = oneLine(check.title, 200), note = oneLine(check.note, noteLimit)
                lines.append("- [\(answer.isEmpty ? "답 없음" : answer)] \(title)")
                if !note.isEmpty { lines.append("  - 메모: \(note)") }
            }
        }
        lines += ["", "---", footer]
        return FeedbackIssueDraft(title: title, body: lines.joined(separator: "\n") + "\n")
    }

    /// Debug 빌드가 Mac으로 바로 보낸 기록: `글`, 빈 줄, `---`, `앱:`·`기기:`·`보낸 시각:`·`첨부:` 줄, 그 아래 로그.
    static func directFacts(item: CrashLogStore.Item, text: String) -> Facts {
        var facts = Facts()
        let parts = text.range(of: "\n\n---\n").map { (String(text[..<$0.lowerBound]), String(text[$0.upperBound...])) } ?? (text, "")
        facts.message = parts.0.trimmingCharacters(in: .whitespacesAndNewlines) == "(글 없이 보냄)" ? "" : parts.0
        // 끝에 붙인 확인 목록의 답은 기록의 `checks`로 읽는다.
        let info = parts.1.range(of: "\n---\n확인 목록의 답").map { String(parts.1[..<$0.lowerBound]) } ?? parts.1
        let known = ["앱: ", "기기: ", "보낸 시각: ", "첨부: "]
        for line in info.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("기기: "), facts.device.isEmpty, !facts.hasLogs {
                // `iPhone16,2, iOS 18.1`
                let value = line.dropFirst(4)
                if let comma = value.range(of: ", ") {
                    facts.device = String(value[..<comma.lowerBound])
                    facts.system = String(value[comma.upperBound...])
                } else {
                    facts.device = String(value)
                }
            } else if !known.contains(where: { line.hasPrefix($0) }), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                facts.hasLogs = true
            }
        }
        facts.checks = (item.checks ?? []).map { Answer(title: $0.title, answer: $0.answer, note: $0.note) }
        return facts
    }

    /// 메일에 붙어 온 진단 파일을 푼 기록: `{"format":1,"diagnostics":{"app":{…},…},"checklist":[…]}`.
    /// 사용자가 쓴 글은 메일 본문에 있어 이 기록에는 없다.
    static func importedFacts(_ text: String) -> Facts {
        var facts = Facts()
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return facts }
        let diagnostics = object["diagnostics"] as? [String: Any] ?? [:]
        if let app = diagnostics["app"] as? [String: Any] {
            facts.system = app["os"] as? String ?? ""
            facts.device = app["device"] as? String ?? ""
        }
        facts.hasLogs = diagnostics.keys.contains { $0 != "app" }
        let names = ["passed": "통과", "failed": "실패", "untested": "확인 못함"]
        facts.checks = (object["checklist"] as? [[String: Any]] ?? []).map { check in
            let choice = check["choice"] as? String ?? ""
            return Answer(title: check["title"] as? String ?? "",
                          answer: choice.isEmpty ? names[check["answer"] as? String ?? ""] ?? "" : choice,
                          note: check["note"] as? String ?? "")
        }
        return facts
    }

    /// 기기가 알려 준 짧은 값(버전, 모델). 글자, 숫자, 빈칸과 `.,()_+-`만 남기고 40자에서 자른다.
    static func plain(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .,()_+-"))
        return String(String(String.UnicodeScalarView(value.unicodeScalars.filter(allowed.contains))).prefix(40))
            .trimmingCharacters(in: .whitespaces)
    }

    static func oneLine(_ value: String, _ limit: Int) -> String {
        clip(FeedbackScrubber.scrub(value.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)), limit)
    }

    static func clip(_ value: String, _ limit: Int) -> String {
        value.count > limit ? value.prefix(limit - 1) + "…" : value
    }
}

public struct IssueFailure: Error, Sendable, Hashable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// 이슈를 올리는 곳. 시험에서는 가짜로 바꿔 넣어 `gh`를 돌리지 않는다.
public protocol IssueFiling: Sendable {
    /// 올린 이슈의 주소를 돌려준다.
    func create(repo: String, title: String, body: String) async -> Result<String, IssueFailure>
}

/// GitHub CLI(`gh issue create`)로 이슈를 올린다. 본문은 임시 파일로 넘기고 끝나면 지운다.
public struct GHIssueFiler: IssueFiling {
    public typealias Run = @Sendable (_ executable: String, _ arguments: [String]) async -> (code: Int32, output: String)

    var tool: @Sendable () -> String?
    var run: Run
    var tempDirectory: URL

    public init() {
        self.init(tool: Self.findTool, run: { await PhoneAppTools.run($0, $1, log: nil) },
                  tempDirectory: FileManager.default.temporaryDirectory)
    }

    init(tool: @escaping @Sendable () -> String?, run: @escaping Run, tempDirectory: URL) {
        self.tool = tool
        self.run = run
        self.tempDirectory = tempDirectory
    }

    /// 앱은 터미널의 PATH를 물려받지 않아, `gh`가 놓이는 흔한 자리를 직접 본다.
    static let findTool: @Sendable () -> String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh", "/usr/bin/gh",
                "\(home)/.local/bin/gh", "\(home)/bin/gh", "/run/current-system/sw/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func create(repo: String, title: String, body: String) async -> Result<String, IssueFailure> {
        guard let gh = tool() else {
            return .failure(IssueFailure(String(localized: "gh 명령을 찾지 못했습니다. GitHub CLI를 설치하고(brew install gh) gh auth login으로 로그인하세요.")))
        }
        let file = tempDirectory.appendingPathComponent("rd-issue-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            return .failure(IssueFailure(String(localized: "이슈 본문을 임시 파일에 쓰지 못했습니다.")))
        }
        let arguments = ["issue", "create", "--repo", repo, "--title", title, "--body-file", file.path]
        var result = await run(gh, arguments + ["--label", FeedbackIssue.label])
        // 라벨이 저장소에 없으면 라벨 없이 한 번 더 올린다.
        if result.code != 0, result.output.localizedCaseInsensitiveContains("label") {
            result = await run(gh, arguments)
        }
        guard result.code == 0 else { return .failure(IssueFailure(Self.explain(result.output, repo: repo))) }
        guard let url = Self.issueURL(in: result.output) else {
            return .failure(IssueFailure(String(localized: "gh가 이슈 주소를 돌려주지 않았습니다. 저장소 \(repo)의 이슈 목록에서 올라갔는지 확인하세요.")))
        }
        return .success(url)
    }

    /// `gh`의 출력에서 이슈 주소(`https://github.com/owner/repo/issues/12`)를 찾는다.
    static func issueURL(in output: String) -> String? {
        output.matches(of: /https:\/\/github\.com\/[A-Za-z0-9\-]+\/[A-Za-z0-9._\-]+\/issues\/\d+/).last.map { String($0.output) }
    }

    /// 실패한 `gh` 출력에서 사람이 할 일을 고른다.
    static func explain(_ output: String, repo: String) -> String {
        let text = output.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("gh auth login", "not logged in", "authentication", "bad credentials", "http 401") {
            return String(localized: "gh에 로그인되어 있지 않습니다. 터미널에서 gh auth login을 실행한 뒤 다시 시도하세요.")
        }
        if has("could not resolve to a repository", "http 404", "repository not found") {
            return String(localized: "저장소 \(repo)를 찾지 못했습니다. 이름이 맞는지, gh로 로그인한 계정이 이 저장소를 볼 수 있는지 확인하세요.")
        }
        if has("issues are disabled", "has disabled issues", "issues disabled") {
            return String(localized: "저장소 \(repo)는 이슈를 받지 않습니다. 저장소 설정에서 Issues를 켜세요.")
        }
        if has("http 403", "resource not accessible", "must have", "permission") {
            return String(localized: "저장소 \(repo)에 이슈를 쓸 권한이 없습니다.")
        }
        if has("dial tcp", "no such host", "timeout", "timed out", "connection", "network", "could not connect") {
            return String(localized: "GitHub에 연결하지 못했습니다. 네트워크를 확인한 뒤 다시 시도하세요.")
        }
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !line.isEmpty else { return String(localized: "이슈를 등록하지 못했습니다.") }
        return String(localized: "이슈를 등록하지 못했습니다: \(FeedbackIssue.clip(FeedbackScrubber.scrub(line), 200))")
    }
}
