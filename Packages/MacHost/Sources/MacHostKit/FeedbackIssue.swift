import Foundation
import RDModels

/// 공개 저장소에 올라갈 수 있는 글에서 사람이나 기기를 가리킬 수 있는 값을 가린다.
/// 이슈에 넣는 글(사용자가 쓴 글, 확인 목록의 제목·답·메모)은 모두 여기를 지난다.
///
/// 규칙(위에서 아래 차례로 적용한다. 앞 규칙이 가린 자리는 뒤 규칙이 다시 쪼개지 않는다):
/// 1. `file:` 주소와 사용자 폴더·시스템 폴더 경로는 그 줄의 끝까지 가린다(경로에 빈칸이 있을 수 있다).
/// 2. 주소(`스킴://…`)는 모두 가린다. 남기는 것은 `https://github.com/<owner>/<repo>`와 그 아래의
///    `/issues`, `/issues/<번호>`, `/pull/<번호>`뿐이다(쿼리, 조각, 포트, 로그인 정보가 붙으면 가린다).
/// 3. 토큰: `Bearer …`, JWT(`eyJ….….…`), `ghp_`·`gho_`·`ghs_`·`ghu_`·`ghr_`·`github_pat_`, `sk-…`, `xox?-…`, `AKIA…`.
/// 4. `@`의 앞뒤에 글자가 붙은 것은 메일 주소로 보고 가린다(한글 주소, 최상위 도메인이 없는 주소 포함).
/// 5. 기기 UDID, MAC 주소, IPv6(IPv4 대응 주소와 `%영역` 포함), IPv4.
/// 6. 호스트 이름: `….ts.net`, `rd-mac-…`·`rd-phone-…`, `tail` 뒤에 16진수 4자 이상, `….local`.
/// 7. 전화번호처럼 보이는 숫자열(숫자 9개 이상), 그다음 `호스트:포트`.
/// 8. 16진수·base64 글자가 32자 이상 이어진 것은 토큰으로 보고 가린다.
/// 9. 남은 `@이름`은 GitHub이 알림을 보내지 않게 `@` 뒤에 폭 없는 빈칸을 넣는다.
public enum FeedbackScrubber {
    public static let mailMask = "[메일]"
    public static let urlMask = "[주소]"
    public static let hostMask = "[호스트]"
    public static let pathMask = "[경로]"
    public static let addressMask = "[IP]"
    public static let numberMask = "[번호]"
    public static let tokenMask = "[토큰]"
    public static let deviceMask = "[기기]"

    /// 그대로 남기는 주소의 모양(규칙 2).
    static let allowedURL = #"^https://github\.com/[A-Za-z0-9](?:[A-Za-z0-9\-]{0,38})/[A-Za-z0-9._\-]{1,100}(?:/issues(?:/\d+)?|/pull/\d+)?/?$"#

    public static func scrub(_ text: String) -> String {
        // 남길 주소를 잠깐 바꿔 두는 표시로 쓰는 글자(사용자 영역)는 입력에서 먼저 뺀다.
        var text = String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0xE000...0xF8FF).contains($0.value) }))
        var kept: [String] = []

        // 1. 경로. 빈칸이 든 경로를 반만 가리지 않게 줄 끝까지 가린다.
        text = replace(#"file:[^\n]*"#, in: text, with: pathMask)
        text = replace(#"(?<![A-Za-z0-9._\-/\]])(?:~|/Users|/home|/Volumes|/private|/var|/tmp|/Library|/Applications)/[^\n]*"#, in: text, with: pathMask)
        // 2. 주소. 끝의 마침표·쉼표는 주소에 넣지 않는다.
        text = replace(#"[a-z][a-z0-9+.\-]*://[^\s<>"'\])]*[^\s<>"'\]).,;:!?]"#, in: text) { found in
            guard found.range(of: allowedURL, options: .regularExpression) != nil else { return urlMask }
            kept.append(found)
            return "\u{E000}\(kept.count - 1)\u{E001}"
        }
        // 3. 토큰.
        text = replace(#"\bBearer\s+[A-Za-z0-9._~+/=\-]{8,}"#, in: text, with: tokenMask)
        text = replace(#"\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*"#, in: text, with: tokenMask)
        text = replace(#"\b(?:gh[pousr]_[A-Za-z0-9]{10,}|github_pat_[A-Za-z0-9_]{10,}|sk-[A-Za-z0-9_\-]{16,}|xox[a-z]-[A-Za-z0-9\-]{8,}|AKIA[0-9A-Z]{16})"#, in: text, with: tokenMask)
        // 4. 메일: `@`의 앞뒤에 빈칸이 아닌 글자가 붙어 있으면 통째로.
        text = replace(#"[^\s<>()\[\]"]+@[^\s<>()\[\]"]*[^\s<>()\[\]".,;:!?]"#, in: text, with: mailMask)
        // 5. 기기와 네트워크 주소.
        text = replace(#"(?<![0-9a-z])(?:[0-9a-f]{8}-[0-9a-f]{16}|[0-9a-f]{40})(?![0-9a-z])"#, in: text, with: deviceMask)
        text = replace(#"(?<![0-9a-z:\-])(?:[0-9a-f]{2}[:\-]){5}[0-9a-f]{2}(?![0-9a-z:\-])"#, in: text, with: deviceMask)
        // IPv6: 모양이 비슷한 것(시각 12:30:45 등)은 실제 주소일 때만 가린다. `%영역`과 IPv4 대응 주소의 뒷부분까지 함께 가린다.
        text = replace(#"(?<![0-9a-z:.])(?:[0-9a-f]{0,4}:){2,7}(?:(?:\d{1,3}\.){3}\d{1,3}|[0-9a-f]{0,4})(?:%[A-Za-z0-9_\-]+)?(?![0-9a-z:])"#, in: text) { found in
            var buffer = in6_addr()
            let address = found.split(separator: "%", maxSplits: 1).first.map(String.init) ?? found
            return inet_pton(AF_INET6, address, &buffer) == 1 ? addressMask : nil
        }
        text = replace(#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?!\.?\d)"#, in: text, with: addressMask)
        // 6. 호스트 이름.
        text = replace(#"[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.ts\.net"#, in: text, with: hostMask)
        text = replace(#"\brd-(?:mac|phone)-[A-Za-z0-9._\-]*[A-Za-z0-9_]"#, in: text, with: hostMask)
        text = replace(#"\btail[0-9a-f]{4,}\b"#, in: text, with: hostMask)
        text = replace(#"[^\s<>()\[\]"'/:@=,]+\.local(?![A-Za-z0-9\-])"#, in: text, with: hostMask)
        // 7. 전화번호처럼 보이는 숫자열(숫자 9개 이상, 사이에 빈칸·붙임표·점·괄호). `tel:`이나 문장 부호 바로 뒤에 와도 가린다.
        text = replace(#"(?<![A-Za-z0-9_])(?:\+|\()?\d(?:[ ().\-]{0,2}\d){8,}(?![0-9:])"#, in: text, with: numberMask)
        // `호스트:포트`는 전화번호 뒤에 본다(`이름:010-…`의 앞부분을 포트로 잘못 가리지 않게).
        text = replace(#"(?<![A-Za-z0-9.\-])(?=[A-Za-z0-9.\-]*[A-Za-z])[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?:\d{2,5}(?![\d:])"#, in: text, with: hostMask)
        // 8. 길게 이어진 16진수·base64 글자.
        text = replace(#"[A-Za-z0-9+/_\-]{32,}={0,2}"#, in: text, with: tokenMask)
        // 9. GitHub이 `@이름`으로 사람에게 알림을 보내지 않게 한다.
        text = replace(#"@(?=[A-Za-z0-9_])"#, in: text, with: "@\u{200B}")
        for (index, url) in kept.enumerated() { text = text.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: url) }
        return text
    }

    private static func replace(_ pattern: String, in text: String, with mask: String) -> String {
        replace(pattern, in: text) { _ in mask }
    }

    /// 찾은 자리마다 `mask`가 돌려준 글로 바꾼다. `nil`이면 그대로 둔다.
    private static func replace(_ pattern: String, in text: String, mask: (String) -> String?) -> String {
        // 패턴은 위의 상수뿐이고 시험이 모두 지난다. 읽지 못하면 아무것도 내보내지 않는다.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
        let source = text as NSString
        var out = "", last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let masked = mask(source.substring(with: match.range)) else { continue }
            out += source.substring(with: NSRange(location: last, length: match.range.location - last)) + masked
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
        /// 원문에서 사용자가 쓴 글과 그 아래(환경, 로그)를 나눌 수 없었다. 이때 `message`는 비어 있고 원문은 어디에도 넣지 않는다.
        var unsplit = false
    }

    struct Answer: Equatable {
        var title: String
        var answer: String
        var note: String
    }

    /// 이 기록에서 사용자가 쓴 글을 가려낼 수 있는가. 못 하면 저절로 올리지 않고, 사람이 미리보기에서 글을 직접 적는다.
    public static func hasSeparableMessage(item: CrashLogStore.Item, text: String) -> Bool {
        item.isImported || !directFacts(item: item, text: text).unsplit
    }

    public static func draft(item: CrashLogStore.Item, text: String) -> FeedbackIssueDraft {
        let facts = item.isImported ? importedFacts(text) : directFacts(item: item, text: text)
        let message = clip(FeedbackScrubber.scrub(facts.message.trimmingCharacters(in: .whitespacesAndNewlines)), messageLimit)
        let version = plain(item.appVersion)
        let firstLine = message.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let title = firstLine.isEmpty ? (version.isEmpty ? emptyTitle : "\(emptyTitle) · \(version)") : clip(firstLine, titleLimit)

        let attachments = (item.attachments?.count ?? 0) + (item.imageFile == nil ? 0 : 1)
        // 글을 가려내지 못한 기록은 첫 줄을 비워 둔다(사람이 적는다). 원문은 로그가 섞여 있을 수 있어 넣지 않는다.
        var lines = [facts.unsplit ? "" : (message.isEmpty ? emptyMessage : message), "", "## 환경"]
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
    ///
    /// 사용자가 쓴 글은 보낸 쪽이 따로 적어 보낸 값(`item.message`)에서 읽는다. 그 값이 없는 옛 기록은 원문의 첫 `---` 줄 앞을
    /// 글로 본다. 그 줄도 없으면 어디까지가 글인지 알 수 없으므로 `unsplit`으로 두고 원문을 글로 쓰지 않는다(로그가 섞여 있을 수 있다).
    static func directFacts(item: CrashLogStore.Item, text: String) -> Facts {
        var facts = Facts()
        let split = text.range(of: "\n\n---\n").map { (String(text[..<$0.lowerBound]), String(text[$0.upperBound...])) }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let below: String
        if let message = item.message {
            facts.message = message
            below = split?.1 ?? ""
            facts.hasLogs = split == nil && hasText
        } else if let split {
            facts.message = split.0.trimmingCharacters(in: .whitespacesAndNewlines) == "(글 없이 보냄)" ? "" : split.0
            below = split.1
        } else {
            facts.unsplit = true
            below = ""
            facts.hasLogs = hasText
        }
        // 끝에 붙인 확인 목록의 답은 기록의 `checks`로 읽는다.
        let info = below.range(of: "\n---\n확인 목록의 답").map { String(below[..<$0.lowerBound]) } ?? below
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

    /// `gh` 한 번이 끝나기를 기다리는 시간(초). 넘으면 멈추고 실패로 돌려준다.
    public static let timeout: TimeInterval = 60

    public init() {
        self.init(tool: Self.findTool, run: { await PhoneAppTools.run($0, $1, log: nil, timeout: Self.timeout) },
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
        if result.code != 0, result.code != PhoneAppTools.timedOutCode, result.output.localizedCaseInsensitiveContains("label") {
            result = await run(gh, arguments)
        }
        guard result.code != PhoneAppTools.timedOutCode else {
            // 멈추기 전에 올라갔을 수도 있다. 다시 올리기 전에 확인하게 한다.
            return .failure(IssueFailure(String(localized: "gh가 \(Int(Self.timeout))초 안에 끝나지 않아 멈췄습니다. 저장소 \(repo)의 이슈 목록에 올라갔는지 확인한 뒤 다시 시도하세요.")))
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
