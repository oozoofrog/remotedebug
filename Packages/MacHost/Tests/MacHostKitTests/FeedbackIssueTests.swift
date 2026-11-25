import Foundation
import RDModels
import Testing
@testable import MacHostKit

/// 받은 피드백을 GitHub 이슈로 올리기: 가리기, 본문에 넣는 것, 어느 프로젝트 것인지, 자동과 수동, 한 번만 올리기, 실패, 에이전트 명령.
@MainActor
@Suite struct FeedbackIssueTests {
    /// `gh` 대신 쓰는 가짜. 부른 것을 적어 두고 정해 둔 답을 준다.
    private final class FakeFiler: IssueFiling, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(repo: String, title: String, body: String)] = []
        private var answer: Result<String, IssueFailure> = .success("https://github.com/example/app/issues/12")

        private var running = 0
        private var mostRunning = 0
        private var delay: Duration?

        var calls: [(repo: String, title: String, body: String)] { lock.withLock { stored } }
        /// 한꺼번에 돌던 `create`의 가장 큰 수.
        var peak: Int { lock.withLock { mostRunning } }
        func fail(_ message: String) { lock.withLock { answer = .failure(IssueFailure(message)) } }
        func succeed(_ url: String) { lock.withLock { answer = .success(url) } }
        func slow(_ duration: Duration) { lock.withLock { delay = duration } }

        func create(repo: String, title: String, body: String) async -> Result<String, IssueFailure> {
            let wait = lock.withLock { () -> Duration? in
                stored.append((repo, title, body))
                running += 1
                mostRunning = max(mostRunning, running)
                return delay
            }
            if let wait { try? await Task.sleep(for: wait) }
            return lock.withLock {
                running -= 1
                return answer
            }
        }
    }

    private struct World {
        let tmp: TempDir
        let store: CrashLogStore
        let filer: FakeFiler
        let model: ProjectsModel
        var project: ConnectedProject
    }

    private let start = Date(timeIntervalSince1970: 1_794_478_500)
    private let bundle = "com.example.sample"

    /// 프로젝트 하나를 연결하고 그 프로젝트가 `com.example.sample`을 게시한 것으로 해 둔다.
    /// `auto`가 true면 주인이 화면에서 자동 등록을 켠 것으로 해 둔다(`setIssueAuto`는 화면만 부른다).
    private func world(target: String? = "example/app", auto: Bool = true, origin: String? = nil) async throws -> World {
        let tmp = try TempDir("issue")
        let store = CrashLogStore(directory: tmp.path("state/CrashLogs"), now: { [start] in start })
        let filer = FakeFiler()
        let model = ProjectsModel(root: tmp.path("state"), builder: AdviceBuilder(app: tmp.path("p/App.app")),
                                  scanner: DerivedDataScanner(root: tmp.path("DerivedData")),
                                  now: { [start] in start }, crashLogs: store, issueFiler: filer, originURL: { _ in origin }) { _, _ in nil }
        var project = try #require(await model.connect(tmp.path("p/App.xcodeproj")))
        model.notePublished(bundle, by: project)
        if let target { project = try model.setIssueTarget(target, for: project).get() }
        if target != nil, auto { project = try #require(model.setIssueAuto(true, for: project)) }
        return World(tmp: tmp, store: store, filer: filer, model: model, project: project)
    }

    /// 패키지가 Debug 빌드에서 Mac으로 바로 보내는 모양의 기록. 올라가면 안 되는 것을 일부러 넣었다.
    private func direct(_ message: String = "결제 단추가 안 눌려요. dev@example.com 으로 알려 주세요\n두 번 눌러도 같습니다",
                        bundleId: String? = nil, checks: [CrashReport.Check] = []) -> DeviceCrashEvent {
        let text = """
        \(message)

        ---
        앱: \(bundleId ?? bundle) 1.2 (7)
        기기: iPhone16,2, iOS 18.1
        보낸 시각: 2026-11-13T05:05:01.000Z
        첨부: secret-photo.jpg, notes.txt

        최근 로그
        05:04:59 결제 화면 열림 token=abcdef123456
        05:05:00 GET https://rd-mac-1a2b3c4d.tail0001.ts.net/v1/builds /Users/someone/Library/x

        """
        var report = CrashReport(kind: .feedback, name: "feedback-20261113T050501.txt", bundleId: bundleId ?? bundle, appVersion: "1.2 (7)",
                                 crashedAt: start, text: text,
                                 attachments: [.init(name: "secret-photo.jpg", type: "image/jpeg", data: Data("jpeg".utf8)),
                                               .init(name: "notes.txt", type: "text/plain", data: Data("memo".utf8))])
        report.checks = checks
        return DeviceCrashEvent(deviceId: "d_1", deviceName: "민수의 iPhone", nodeName: "rd-phone-9z8y7x", report: report)
    }

    /// 메일에 붙어 온 진단 파일을 Mac에서 열었을 때 생기는 기록(기기 id가 없다).
    private func imported() -> DeviceCrashEvent {
        let text = """
        {"checklist":[{"answer":"failed","id":"pay.sheet","note":"010-1234-5678로 연락","title":"결제 화면이 열린다"},{"answer":"passed","choice":"보임","id":"pay.sum","note":"","title":"금액"},{"answer":"unchecked","id":"pay.later","note":"","title":"나중에"}],"diagnostics":{"app":{"build":"7","bundleId":"com.example.sample","device":"iPhone16,2","name":"Sample","os":"iOS 18.1","version":"1.2"},"logs":["05:05 비밀 로그 줄"]},"format":1}
        """
        return DeviceCrashEvent(deviceId: "", deviceName: "메일 첨부", nodeName: "",
                                report: CrashReport(kind: .feedback, name: "diag.json", bundleId: bundle, appVersion: "1.2 (7)", crashedAt: start, text: text))
    }

    // MARK: 가리기

    @Test func scrubberMasksAddressesAndKeepsOrdinaryText() {
        let s = FeedbackScrubber.scrub
        #expect(s("문의는 dev@example.com 으로") == "문의는 [메일] 으로")
        #expect(s("Dev.Name+tag@Mail.Example.co.kr") == "[메일]")
        // 주소는 통째로 가린다.
        #expect(s("https://example.com/pay?token=abc&u=1 에서") == "[주소] 에서")
        #expect(s("ftp://user:pw@example.com/file") == "[주소]")
        #expect(s("myapp://open?id=42") == "[주소]")
        #expect(s("https://example.com/docs/page 참고") == "[주소] 참고")
        // tailnet과 노드 이름.
        #expect(s("rd-mac-1a2b3c4d.tail0001.ts.net 에 안 붙어요") == "[호스트] 에 안 붙어요")
        #expect(s("http://RD-MAC-1A2B3C4D.Tail0001.TS.NET/x") == "[주소]")
        #expect(s("노드 rd-phone-9z8y7x 입니다") == "노드 [호스트] 입니다")
        // IP.
        #expect(s("서버 192.168.0.12 와 100.64.1.2:8080") == "서버 [IP] 와 [IP]:8080")
        #expect(s("fd7a:115c:a1e0::1 그리고 ::1 그리고 fe80::1ff:fe23:4567:890a") == "[IP] 그리고 [IP] 그리고 [IP]")
        #expect(s("12:30:45에 멈춤, 비율 16:9") == "12:30:45에 멈춤, 비율 16:9")
        // 전화번호처럼 보이는 숫자열.
        #expect(s("010-1234-5678") == "[번호]")
        #expect(s("전화 +82 10 1234 5678 주세요") == "전화 [번호] 주세요")
        #expect(s("(02) 123-4567로 전화") == "[번호]로 전화")
        #expect(s("방 번호 1234-5678") == "방 번호 1234-5678", "숫자 9개가 안 되면 그대로 둔다")
        #expect(s("계좌 123456789012") == "계좌 [번호]")
        #expect(s("2026-11-19 10:20에 3번 눌렀고 1.2 (7) 빌드") == "2026-11-19 10:20에 3번 눌렀고 1.2 (7) 빌드")
        // 경로.
        #expect(s("/Users/someone/Documents/a.txt 를 열면") == "[경로]", "경로에 빈칸이 있을 수 있어 줄 끝까지 가린다")
        #expect(s("~/Library/Logs/x.log") == "[경로]")
        // GitHub이 알림을 보내지 않게 @ 뒤를 끊는다.
        #expect(s("@octocat 확인") == "@\u{200B}octocat 확인")
        #expect(s("그냥 글 한 줄, 숫자 42와 100% 그리고 a/b") == "그냥 글 한 줄, 숫자 42와 100% 그리고 a/b")
    }

    @Test func scrubberMasksEveryMailShape() {
        let s = FeedbackScrubber.scrub
        for mail in ["홍길동@example.com", "kim@회사.한국", "user@localhost", "o'brien@example.com", "a.b+c@sub.example.co.kr"] {
            #expect(s("문의 \(mail) 로") == "문의 [메일] 로", "\(mail)")
        }
        #expect(s("<user@example.com>, (kim@회사.한국).") == "<[메일]>, ([메일]).")
        #expect(s("mailto:user@example.com") == "[메일]")
        // `@이름`만 있는 것은 메일이 아니다: 알림이 가지 않게만 한다.
        #expect(s("@octocat 그리고 (@hubot)") == "@\u{200B}octocat 그리고 (@\u{200B}hubot)")
        #expect(s("a @ b") == "a @ b")
    }

    @Test func scrubberMasksTokens() {
        let s = FeedbackScrubber.scrub
        let x = String(repeating: "x", count: 36)
        let jwt = "eyJxxxxxxxxxx.eyJyyyyyyyyyy.zzzzzzzzzz"
        let tokens = ["ghp_\(x)", "gho_\(x)", "ghs_\(x)", "github_pat_\(x)_\(x)", "sk-\(x)", "sk-proj-\(x)",
                      "xoxb-0000-\(x)", "xoxa-0000-\(x)", "xoxp-0000-\(x)", "AKIA" + String(repeating: "X", count: 16),
                      "Bearer \(jwt)", "bearer \(x)", jwt,
                      String(repeating: "0a", count: 16), String(repeating: "0A1b", count: 16),
                      String(repeating: "Ab+/", count: 8) + "==", String(repeating: "x_-Y", count: 10)]
        for token in tokens {
            #expect(s("키 \(token) 끝") == "키 [토큰] 끝", "\(token)")
            #expect(s(token) == "[토큰]", "\(token)")
        }
        #expect(s("Authorization: Bearer \(jwt)") == "Authorization: [토큰]")
        // 31자까지는 그냥 글자다.
        #expect(s(String(repeating: "a", count: 31)) == String(repeating: "a", count: 31))
    }

    @Test func scrubberKeepsOnlyPlainGitHubRepositoryLinks() {
        let s = FeedbackScrubber.scrub
        for kept in ["https://github.com/example/app", "https://github.com/example/app/", "https://github.com/example/app/issues",
                     "https://github.com/example/app/issues/12", "https://github.com/example/my.app/pull/3"] {
            #expect(s("관련: \(kept) 참고") == "관련: \(kept) 참고", "\(kept)")
            #expect(s("\(kept).") == "\(kept).", "끝의 마침표는 주소가 아니다")
        }
        for masked in ["https://example.com", "https://example.com/", "http://github.com/example/app", "https://github.com/example",
                       "https://github.com/example/app/issues/12?token=abc", "https://github.com/example/app/issues/12#issuecomment-1",
                       "https://github.com/example/app/blob/main/Secret.swift", "https://github.com/example/app/pull/3/files",
                       "https://user@github.com/example/app", "https://github.com:8443/example/app", "https://github.com.example.com/a/b",
                       "https://gist.github.com/example/abcdef", "myapp://open/item/42", "ftp://example.com/file", "wss://example.com/socket"] {
            #expect(s("관련: \(masked) 참고") == "관련: [주소] 참고", "\(masked)")
        }
        // 남긴 주소 안의 글자는 뒤 규칙이 건드리지 않는다.
        let long = "https://github.com/example/" + String(repeating: "r", count: 40) + "/issues/123456789"
        #expect(s(long) == long)
    }

    @Test func scrubberMasksHostsPathsAndDeviceIdentifiers() {
        let s = FeedbackScrubber.scrub
        // 호스트 이름과 포트.
        #expect(s("my-mac.local 에 붙음") == "[호스트] 에 붙음")
        #expect(s("민수의-MacBook.local 에 붙음") == "[호스트] 에 붙음")
        #expect(s("localhost:8080 과 build.example.com:8443") == "[호스트] 과 [호스트]")
        #expect(s("rd-mac-1a2b3c4d-extra_x.suffix 그리고 rd-phone-9z8y7x.") == "[호스트] 그리고 [호스트].")
        #expect(s("tail0a1b2c 네트워크, TAIL0001") == "[호스트] 네트워크, [호스트]")
        #expect(s("tailor made, retail0") == "tailor made, retail0")
        // 빈칸이 든 경로는 줄 끝까지.
        #expect(s("파일 /Users/someone/My Documents/a b.txt 를 열면\n다음 줄") == "파일 [경로]\n다음 줄")
        #expect(s("~/Library/Application Support/App/x y.log") == "[경로]")
        #expect(s("file:///Users/someone/a b.txt 끝") == "[경로]")
        #expect(s("/private/var/folders/ab/T/rd cable/x") == "[경로]")
        #expect(s("/var/mobile/Containers/Data/x.log, /tmp/rd-1/x") == "[경로]")
        #expect(s("비율 a/b 와 and/or") == "비율 a/b 와 and/or")
        // IPv6: IPv4 대응 주소와 영역까지.
        #expect(s("::ffff:192.168.0.12 에서") == "[IP] 에서")
        #expect(s("fe80::1%en0 그리고 fe80::1ff:fe23:4567:890a%anri0 로") == "[IP] 그리고 [IP] 로")
        #expect(s("64:ff9b::192.0.2.33") == "[IP]")
        // MAC 주소와 기기 UDID.
        #expect(s("aa:bb:cc:00:11:22 와 AA-BB-CC-00-11-22") == "[기기] 와 [기기]")
        #expect(s("UDID 00008120-000000000000001E 입니다") == "UDID [기기] 입니다")
        #expect(s("옛 기기 0123456789abcdef0123456789abcdef01234567.") == "옛 기기 [기기].")
        // 전화번호: 문장 부호 바로 뒤와 tel:.
        for lead in [":", ",", ".", "/", "-"] {
            #expect(s("연락처\(lead)010-1234-5678") == "연락처\(lead)[번호]", "\(lead)")
        }
        #expect(s("tel:+82-10-1234-5678") == "tel:[번호]")
        #expect(s("call:010-1234-5678 로") == "call:[번호] 로")
        // 사용자 영역 글자를 넣어 남길 주소의 자리표시를 흉내 낼 수 없다.
        #expect(s("\u{E000}0\u{E001} https://example.com/x") == "0 [주소]")
    }

    @Test func targetIsReadFromGitHubRemotesOnly() {
        for remote in ["https://github.com/example/app.git", "https://github.com/example/app", "git@github.com:example/app.git",
                       "ssh://git@github.com/example/app.git", "https://GitHub.com/example/app/\n"] {
            #expect(IssueTarget.fromRemote(remote) == "example/app", "\(remote)")
        }
        for remote in ["https://gitlab.com/example/app.git", "git@example.com:example/app.git", "/tmp/repo", "", "https://github.com/example"] {
            #expect(IssueTarget.fromRemote(remote) == nil, "\(remote)")
        }
        #expect(IssueTarget.normalized(" example/app ") == "example/app")
        #expect(IssueTarget.normalized("https://github.com/example/my.app") == "example/my.app")
        for bad in ["example", "example/app/extra", "exa mple/app", "-x/app", "example/app --label x", ""] {
            #expect(IssueTarget.normalized(bad) == nil, "\(bad)")
        }
    }

    // MARK: 본문

    @Test func bodyCarriesOnlyTheAllowedFields() async throws {
        let w = try await world()
        w.store.receive(direct(checks: [
            .init(id: "pay.sheet", title: "결제 화면이 열린다", answer: "실패", note: "dev@example.com 에 물어봄\n둘째 줄", build: "7", answeredAt: "2026-11-13T05:05:01.000Z"),
            .init(id: "pay.sum", title: "금액이 보인다", answer: "통과"),
            .init(id: "pay.later", title: "나중에 볼 것"),
        ]))
        let item = try #require(w.store.items.first)
        let draft = try w.model.issuePreview(for: item.id).get().draft

        #expect(draft.title == "결제 단추가 안 눌려요. [메일] 으로 알려 주세요")
        #expect(draft.body == """
        결제 단추가 안 눌려요. [메일] 으로 알려 주세요
        두 번 눌러도 같습니다

        ## 환경
        - 앱 버전: 1.2 (7)
        - OS: iOS 18.1
        - 기기: iPhone16,2
        - 받은 시각: 2026-11-12T10:15:00Z
        - 첨부: 2개
        - 로그: 붙어 있음

        ## 확인 목록의 답
        - [실패] 결제 화면이 열린다
          - 메모: [메일] 에 물어봄 둘째 줄
        - [통과] 금액이 보인다

        ---
        \(FeedbackIssue.footer)

        """)
        // 올라가면 안 되는 것: 로그 줄, 첨부 이름, 기기 이름과 id, 노드·tailnet 이름, 메일 주소, 경로, 번들 ID, 기록 id와 파일 경로.
        let forbidden = ["token=", "결제 화면 열림", "최근 로그", "secret-photo", "notes.txt", "민수", "d_1", "rd-phone", "rd-mac", "ts.net",
                         "dev@example.com", "/Users/", bundle, item.id, item.file, w.tmp.url.path, "pay.sheet", "CrashLogs"]
        for word in forbidden {
            #expect(!draft.body.contains(word) && !draft.title.contains(word), "\(word)")
        }
        #expect(FeedbackIssue.footer.contains("RemoteDebug") && FeedbackIssue.footer.contains("개발자의 Mac"))
    }

    @Test func titleIsBoundedAndEmptyMessagesGetAFixedTitle() async throws {
        let w = try await world()
        w.store.receive(direct(String(repeating: "가", count: 300)))
        w.store.receive(direct("(글 없이 보냄)"))
        let long = try #require(w.store.items.first { w.store.text($0)?.hasPrefix("가") == true })
        let empty = try #require(w.store.items.first { $0.id != long.id })
        let longDraft = try w.model.issuePreview(for: long.id).get().draft
        #expect(longDraft.title.count == FeedbackIssue.titleLimit && longDraft.title.hasSuffix("…"))
        let emptyDraft = try w.model.issuePreview(for: empty.id).get().draft
        #expect(emptyDraft.title == "앱에서 온 피드백 · 1.2 (7)")
        #expect(emptyDraft.body.hasPrefix(FeedbackIssue.emptyMessage + "\n") && !emptyDraft.body.contains("글 없이 보냄"))
        // 기기가 보낸 버전·모델 글자는 정해 둔 글자만 남긴다.
        #expect(FeedbackIssue.plain("1.2 (7)\n@octocat <b>") == "1.2 (7)octocat b")
        #expect(FeedbackIssue.plain(String(repeating: "9", count: 80)).count == 40)
    }

    @Test func importedRecordsReadTheAppAndAnswersFromTheDiagnosticsFile() async throws {
        let w = try await world()
        w.store.receive(imported())
        let item = try #require(w.store.items.first)
        #expect(item.isImported)
        let draft = try w.model.issuePreview(for: item.id).get().draft
        #expect(draft.title == "앱에서 온 피드백 · 1.2 (7)")
        #expect(draft.body.contains("- OS: iOS 18.1\n- 기기: iPhone16,2\n") && draft.body.contains("- 첨부: 0개\n- 로그: 붙어 있음"))
        #expect(draft.body.contains("- [실패] 결제 화면이 열린다\n  - 메모: [번호]로 연락\n- [보임] 금액\n"))
        for word in ["비밀 로그", "나중에", "010-1234", "pay.sheet", bundle, "diagnostics"] { #expect(!draft.body.contains(word), "\(word)") }
    }

    // MARK: 어느 프로젝트 것인가

    @Test func recordsMapToTheProjectThatPublishedTheirBundleID() async throws {
        let w = try await world(target: nil)
        w.store.receive(direct())
        w.store.receive(direct("다른 앱에서 온 글", bundleId: "com.example.other"))
        w.store.receive(direct("번들 ID가 없는 글", bundleId: ""))
        let mine = try #require(w.store.items.first { $0.bundleId == bundle })
        let other = try #require(w.store.items.first { $0.bundleId == "com.example.other" })
        let bare = try #require(w.store.items.first { $0.bundleId.isEmpty })
        #expect(w.model.project(publishing: bundle)?.id == w.project.id)
        #expect(w.model.project(publishing: "com.example.other") == nil)

        // 저장소를 정하지 않은 프로젝트는 올리지 않는다.
        guard case .failure(let noTarget) = w.model.issuePreview(for: mine.id) else { Issue.record("저장소 없이 미리보기가 나왔다"); return }
        #expect(noTarget.message.contains("이슈 저장소가 정해져 있지 않습니다"))
        #expect(!w.model.filesAutomatically(mine))
        try #require(w.model.setIssueTarget("example/app", for: w.project).get().issueTarget == "example/app")
        #expect(try w.model.issuePreview(for: mine.id).get().repo == "example/app")

        // 주인 없는 기록은 까닭과 함께 거절한다.
        guard case .failure(let noOwner) = w.model.issuePreview(for: other.id) else { Issue.record("주인 없는 기록의 미리보기가 나왔다"); return }
        #expect(noOwner.message.contains("com.example.other") && noOwner.message.contains("게시한 연결한 프로젝트가 없어"))
        guard case .failure(let noBundle) = w.model.issuePreview(for: bare.id) else { Issue.record("번들 ID 없는 기록의 미리보기가 나왔다"); return }
        #expect(noBundle.message.contains("번들 ID가 없어"))
        guard case .failure(let missing) = w.model.issuePreview(for: "c_none") else { Issue.record("없는 기록의 미리보기가 나왔다"); return }
        #expect(missing.message.contains("c_none"))
        if case .success = await w.model.fileIssue(other.id) { Issue.record("주인 없는 기록이 올라갔다") }
        #expect(w.filer.calls.isEmpty)

        // 크래시 기록은 올리지 않는다.
        w.store.receive(DeviceCrashEvent(deviceId: "d_1", deviceName: "폰", nodeName: "", report: .ips(name: "a.ips", text: "{\"bundleID\":\"\(bundle)\"}\n본문", fallbackDate: start)))
        let crash = try #require(w.store.items.first { $0.kind == .ips })
        guard case .failure(let notFeedback) = w.model.issuePreview(for: crash.id) else { Issue.record("크래시 기록의 미리보기가 나왔다"); return }
        #expect(notFeedback.message.contains("피드백만"))

        // 저장소와 자동 등록은 프로젝트와 함께 저장된다.
        w.model.setIssueAuto(false, for: w.project)
        let reopened = ProjectsModel(root: w.tmp.path("state"), builder: AdviceBuilder(app: w.tmp.path("p/App.app")),
                                     scanner: DerivedDataScanner(root: w.tmp.path("DerivedData"))) { _, _ in nil }
        reopened.load()
        #expect(reopened.projects.first?.issueTarget == "example/app" && reopened.projects.first?.issueAuto == false)
        guard case .failure(let bad) = w.model.setIssueTarget("not a repo", for: w.project) else { Issue.record("모양이 아닌 저장소를 받았다"); return }
        #expect(bad.message.contains("owner/repo"))
        #expect(try w.model.setIssueTarget("", for: w.project).get().issueTarget == nil)
    }

    // MARK: 자동과 수동

    @Test func directFeedbackIsFiledOnArrivalAndImportedFeedbackNever() async throws {
        // 저장소를 정하는 것만으로는 켜지지 않는다. 주인이 화면에서 켜야 한다.
        let off = try await world(auto: false)
        #expect(off.project.issueTarget == "example/app" && off.project.issueAuto == nil && !off.project.filesIssuesAutomatically)
        off.store.receive(direct())
        let unsent = try #require(off.store.items.first)
        #expect(!off.model.filesAutomatically(unsent))
        await off.model.receivedForIssue(unsent)
        #expect(off.filer.calls.isEmpty && off.model.issueErrors.isEmpty)
        #expect(try off.model.setIssueTarget("example/other", for: off.project).get().filesIssuesAutomatically == false)

        let w = try await world()
        #expect(w.project.filesIssuesAutomatically, "주인이 켠 뒤에는 켜져 있다")
        w.store.receive(direct())
        w.store.receive(imported())
        let sent = try #require(w.store.items.first { !$0.isImported })
        let mailed = try #require(w.store.items.first { $0.isImported })
        #expect(w.model.filesAutomatically(sent) && !w.model.filesAutomatically(mailed))

        await w.model.receivedForIssue(mailed)
        #expect(w.filer.calls.isEmpty && w.store.items.allSatisfy { $0.issueURL == nil })
        await w.model.receivedForIssue(sent)
        #expect(w.filer.calls.count == 1 && w.filer.calls[0].repo == "example/app")
        let filed = try #require(w.store.items.first { $0.id == sent.id })
        #expect(filed.issueURL == "https://github.com/example/app/issues/12" && filed.issueNumber == 12 && filed.issueFiledAt == start)
        #expect(w.store.items.first { $0.id == mailed.id }?.issueURL == nil)
        // 주소는 파일에 남아 앱을 다시 켜도 이어지고, 목록 글에 나온다.
        #expect(CrashLogStore(directory: w.store.directory, now: { Date() }).items.first { $0.id == sent.id }?.issueNumber == 12)
        let list = CrashLogStore.listText(directory: try #require(w.store.directory))
        #expect(list.contains("\n    이슈: https://github.com/example/app/issues/12") && list.components(separatedBy: "\n    이슈:").count == 2)

        // 자동 등록을 끄면 받아도 올리지 않는다. 크래시 기록도 올리지 않는다.
        w.model.setIssueAuto(false, for: w.project)
        w.store.receive(direct("자동 등록을 끈 뒤에 온 글"))
        let later = try #require(w.store.items.first { $0.issueURL == nil && !$0.isImported })
        #expect(!w.model.filesAutomatically(later))
        await w.model.receivedForIssue(later)
        #expect(w.filer.calls.count == 1)

        // 메일로 온 기록은 사람이 미리보기에서 고친 제목과 본문으로만 올라간다.
        w.filer.succeed("https://github.com/example/app/issues/13")
        let manual = try await w.model.fileIssue(mailed.id, draft: FeedbackIssueDraft(title: "  결제 화면이 안 열림  ", body: "사람이 고친 본문\n")).get()
        #expect(manual.issueNumber == 13 && w.filer.calls.count == 2)
        #expect(w.filer.calls[1].title == "결제 화면이 안 열림" && w.filer.calls[1].body == "사람이 고친 본문\n")
        guard case .failure(let untitled) = await w.model.fileIssue(later.id, draft: .init(title: " ", body: "x")) else { Issue.record("제목 없이 올라갔다"); return }
        #expect(untitled.message.contains("제목") && w.filer.calls.count == 2)
    }

    @Test func storeTellsTheListenerAboutNewRecordsOnly() throws {
        let store = CrashLogStore(directory: nil, now: { Date() })
        var seen: [String] = []
        store.onReceived = { seen.append($0.id) }
        store.receive(direct())
        store.receive(direct())
        #expect(seen.count == 1 && seen.first == store.items.first?.id)
    }

    @Test func automaticFilingIsCappedPerProjectAndGHRunsOneAtATime() async throws {
        let w = try await world()
        w.filer.slow(.milliseconds(20))
        let count = ProjectsModel.autoIssueLimit + 3
        for index in 0..<count { w.store.receive(direct("쏟아지는 글 \(index)")) }
        let items = w.store.items
        #expect(items.count == count)
        // 한꺼번에 들어와도 gh는 하나씩 돌고, 한도까지만 저절로 올린다.
        let model = w.model
        for task in items.map({ item in Task { await model.receivedForIssue(item) } }) { await task.value }
        #expect(w.filer.calls.count == ProjectsModel.autoIssueLimit && w.filer.peak == 1)
        let unfiled = w.store.items.filter { $0.issueURL == nil }
        #expect(unfiled.count == 3)
        for item in unfiled {
            #expect(w.model.issueErrors[item.id]?.contains("한 시간에 \(ProjectsModel.autoIssueLimit)개") == true, "한도를 넘은 기록에 까닭이 보인다")
        }
        // 한도를 넘은 기록도 직접 올릴 수 있다. 직접 올리는 것은 한도가 없지만 줄은 선다.
        for task in unfiled.map({ item in Task { _ = await model.fileIssue(item.id) } }) { await task.value }
        #expect(w.filer.calls.count == count && w.filer.peak == 1)
        #expect(w.store.items.allSatisfy { $0.issueURL != nil } && w.model.issueErrors.isEmpty)
        #expect(!w.model.issueQueueBusy && w.model.issueQueueWaiters.isEmpty)
    }

    @Test func textWithoutTheSeparatorIsNeverUsedAsTheMessage() async throws {
        let w = try await world()
        // 옛 클라이언트나 손댄 클라이언트가 `---` 줄 없이 보낸 기록: 글과 로그를 가를 수 없다.
        let raw = "화면이 멈춰요\n05:04:59 결제 화면 열림 token=abcdef123456\n05:05:00 GET /v1/builds secret-line"
        w.store.receive(DeviceCrashEvent(deviceId: "d_1", deviceName: "폰", nodeName: "", report:
            CrashReport(kind: .feedback, name: "feedback.txt", bundleId: bundle, appVersion: "1.2 (7)", crashedAt: start, text: raw)))
        let item = try #require(w.store.items.first)
        #expect(item.message == nil && !w.model.filesAutomatically(item))
        await w.model.receivedForIssue(item)
        #expect(w.filer.calls.isEmpty, "저절로 올리지 않는다")
        #expect(w.model.issueErrors[item.id]?.contains("나눌 수 없어") == true)

        let preview = try w.model.issuePreview(for: item.id).get()
        #expect(preview.needsMessage && preview.draft.title == "앱에서 온 피드백 · 1.2 (7)")
        #expect(preview.draft.body.hasPrefix("\n\n## 환경\n"), "글 자리는 비어 있다")
        for word in ["화면이 멈춰요", "token=", "secret-line", "결제 화면 열림"] { #expect(!preview.draft.body.contains(word), "\(word)") }
        // 에이전트도, 본문 없이 부른 올리기도 받지 않는다. 사람이 적은 본문으로만 올라간다.
        let agent = await w.model.handleAgentRequest("issue\n\(item.id)\nconfirm\n")
        #expect(!agent.ok && agent.error?.contains("나눌 수 없어") == true)
        if case .success = await w.model.fileIssue(item.id) { Issue.record("글 없이 올라갔다") }
        #expect(w.filer.calls.isEmpty)
        #expect(try await w.model.fileIssue(item.id, draft: .init(title: "화면이 멈춤", body: "사람이 적은 글\n")).get().issueURL != nil)
        #expect(w.filer.calls.count == 1 && w.filer.calls[0].body == "사람이 적은 글\n")
    }

    @Test func theMessageComesFromTheExplicitFieldWhenTheRecordHasOne() async throws {
        let w = try await world()
        // 새 클라이언트는 글을 따로 적어 보낸다. 글 안에 `---` 줄이 있어도, 원문에 그 줄이 없어도 글은 그 값이다.
        var report = CrashReport.feedback(message: "첫 줄\n\n---\n글 안의 줄", bundleId: bundle, appVersion: "1.2 (7)",
                                          details: "기기: iPhone16,2, iOS 18.1\n최근 로그\n05:05 secret-line", date: start)
        #expect(report.message == "첫 줄\n\n---\n글 안의 줄")
        w.store.receive(DeviceCrashEvent(deviceId: "d_1", deviceName: "폰", nodeName: "", report: report))
        let split = try #require(w.store.items.first)
        #expect(split.message == report.message && w.model.filesAutomatically(split))
        let draft = try w.model.issuePreview(for: split.id).get().draft
        #expect(draft.title == "첫 줄" && draft.body.hasPrefix("첫 줄\n\n---\n글 안의 줄\n\n## 환경\n") && !draft.body.contains("secret-line"))

        report = CrashReport(kind: .feedback, name: "feedback.txt", bundleId: bundle, appVersion: "1.2 (7)", crashedAt: start,
                             text: "줄 없는 원문\n05:05 secret-line")
        report.message = "따로 온 글"
        w.store.receive(DeviceCrashEvent(deviceId: "d_1", deviceName: "폰", nodeName: "", report: report))
        let bare = try #require(w.store.items.first { $0.id != split.id })
        let preview = try w.model.issuePreview(for: bare.id).get()
        #expect(!preview.needsMessage && w.model.filesAutomatically(bare))
        #expect(preview.draft.body.hasPrefix("따로 온 글\n\n## 환경\n") && preview.draft.body.contains("- 로그: 붙어 있음"))
        #expect(!preview.draft.body.contains("secret-line") && !preview.draft.body.contains("줄 없는 원문"))
        // 글 없이 보낸 것(빈 글자)도 값이다.
        report.text += "\n다른 원문"
        report.message = ""
        w.store.receive(DeviceCrashEvent(deviceId: "d_1", deviceName: "폰", nodeName: "", report: report))
        let empty = try #require(w.store.items.first { $0.message == "" })
        #expect(try w.model.issuePreview(for: empty.id).get().draft.body.hasPrefix(FeedbackIssue.emptyMessage + "\n"))
        // 크래시 기록에는 이 값을 두지 않는다.
        var crash = CrashReport.ips(name: "a.ips", text: "{}\n본문", fallbackDate: start)
        crash.message = "x"
        w.store.receive(DeviceCrashEvent(deviceId: "d_1", deviceName: "폰", nodeName: "", report: crash))
        #expect(w.store.items.first { $0.kind == .ips }?.message == nil)
    }

    // MARK: 한 번만, 실패

    @Test func aRecordIsFiledOnceAndFailuresLeaveItUnfiled() async throws {
        let w = try await world()
        w.store.receive(direct())
        let id = try #require(w.store.items.first?.id)

        w.filer.fail("gh에 로그인되어 있지 않습니다.")
        guard case .failure(let failure) = await w.model.fileIssue(id) else { Issue.record("실패해야 한다"); return }
        #expect(failure.message == "gh에 로그인되어 있지 않습니다.")
        #expect(w.store.items.first?.issueURL == nil && w.model.issueErrors[id] == failure.message)
        #expect(w.filer.calls.count == 1, "실패해도 다시 시도하지 않는다")

        w.filer.succeed("https://github.com/example/app/issues/21")
        #expect(try await w.model.fileIssue(id).get().issueNumber == 21)
        #expect(w.model.issueErrors[id] == nil)
        // 이미 올린 기록은 다시 올리지 않고 같은 주소를 돌려준다.
        w.filer.succeed("https://github.com/example/app/issues/22")
        #expect(try await w.model.fileIssue(id).get().issueNumber == 21)
        await w.model.receivedForIssue(try #require(w.store.items.first))
        #expect(w.filer.calls.count == 2)
        #expect(w.store.setIssue(id, url: "https://github.com/example/app/issues/99")?.issueNumber == 21)
        #expect(w.store.setIssue("c_none", url: "x") == nil)
    }

    // MARK: gh

    @Test func ghReceivesTheBodyInAFileThatIsRemovedAfterwards() async throws {
        let tmp = try TempDir("gh")
        let seen = Seen()
        let filer = GHIssueFiler(tool: { "/opt/homebrew/bin/gh" }, run: { executable, arguments in
            seen.lock.withLock {
                seen.runs.append([executable] + arguments)
                if let index = arguments.firstIndex(of: "--body-file") {
                    let path = arguments[index + 1]
                    seen.bodies.append((try? String(contentsOfFile: path, encoding: .utf8)) ?? "<없음>")
                    seen.modes.append(((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? 0)
                }
                return seen.outputs.isEmpty ? (0, "https://github.com/example/app/issues/7\n") : seen.outputs.removeFirst()
            }
        }, tempDirectory: tmp.path("work"))
        let body = "본문 첫 줄\n--title 아님\n"

        #expect(try await filer.create(repo: "example/app", title: "제목", body: body).get() == "https://github.com/example/app/issues/7")
        let first = try #require(seen.runs.first)
        #expect(first.prefix(8) == ["/opt/homebrew/bin/gh", "issue", "create", "--repo", "example/app", "--title", "제목", "--body-file"])
        #expect(first.suffix(2) == ["--label", "feedback"])
        #expect(!first.contains { $0.contains("본문 첫 줄") }, "본문은 명령줄에 싣지 않는다")
        #expect(seen.bodies == [body] && seen.modes == [0o600])
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path("work").path).isEmpty, "임시 파일을 지운다")

        // 라벨이 없는 저장소: 라벨 없이 한 번 더 올린다.
        seen.runs = []
        seen.outputs = [(1, "could not add label: 'feedback' not found\n"), (0, "Creating issue in example/app\n\nhttps://github.com/example/app/issues/8\n")]
        #expect(try await filer.create(repo: "example/app", title: "제목", body: body).get() == "https://github.com/example/app/issues/8")
        #expect(seen.runs.count == 2 && !seen.runs[1].contains("--label") && seen.runs[1].contains("--body-file"))

        // 실패는 짧은 안내가 되고 다시 시도하지 않는다. 임시 파일은 실패해도 지운다.
        let cases: [(String, String)] = [
            ("To get started with GitHub CLI, please run:  gh auth login\n", "gh auth login을 실행"),
            ("GraphQL: Could not resolve to a Repository with the name 'example/app'. (repository)\n", "저장소 example/app를 찾지 못했습니다"),
            ("the 'example/app' repository has disabled issues\n", "이슈를 받지 않습니다"),
            ("HTTP 403: Resource not accessible by integration\n", "쓸 권한이 없습니다"),
            ("Post \"https://api.github.com/graphql\": dial tcp: lookup api.github.com: no such host\n", "GitHub에 연결하지 못했습니다"),
            ("something odd happened for dev@example.com\nsecond line\n", "이슈를 등록하지 못했습니다: something odd happened for [메일]"),
            ("", "이슈를 등록하지 못했습니다."),
        ]
        for (output, expected) in cases {
            seen.runs = []
            seen.outputs = [(1, output)]
            guard case .failure(let failure) = await filer.create(repo: "example/app", title: "제목", body: body) else { Issue.record("실패해야 한다"); continue }
            #expect(failure.message.contains(expected), "\(output) → \(failure.message)")
            #expect(seen.runs.count == 1)
        }
        seen.outputs = [(0, "no address here\n")]
        guard case .failure(let noURL) = await filer.create(repo: "example/app", title: "제목", body: body) else { Issue.record("주소 없이 성공했다"); return }
        #expect(noURL.message.contains("이슈 주소를 돌려주지 않았습니다"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path("work").path).isEmpty)

        // 기한을 넘겨 멈춘 gh: 까닭을 알리고 라벨 없이 다시 돌리지 않는다. 임시 파일은 지운다.
        seen.runs = []
        seen.outputs = [(PhoneAppTools.timedOutCode, "could not add label\n")]
        guard case .failure(let late) = await filer.create(repo: "example/app", title: "제목", body: body) else { Issue.record("기한을 넘겼는데 성공했다"); return }
        #expect(late.message.contains("\(Int(GHIssueFiler.timeout))초 안에 끝나지 않아") && late.message.contains("example/app") && seen.runs.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path("work").path).isEmpty)

        // gh가 없으면 아무것도 돌리지 않는다.
        seen.runs = []
        let missing = GHIssueFiler(tool: { nil }, run: { _, _ in seen.lock.withLock { seen.runs.append([]) }; return (0, "") }, tempDirectory: tmp.path("none"))
        guard case .failure(let noTool) = await missing.create(repo: "example/app", title: "제목", body: body) else { Issue.record("gh 없이 성공했다"); return }
        #expect(noTool.message.contains("gh 명령을 찾지 못했습니다") && seen.runs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tmp.path("none").path))
        #expect(GHIssueFiler.issueURL(in: "https://github.com/example/app/issues/3\nhttps://github.com/example/app/issues/4") == "https://github.com/example/app/issues/4")
        #expect(GHIssueFiler.issueURL(in: "https://example.com/example/app/issues/3") == nil)
    }

    @Test func processRunnerStopsACommandThatOutlivesItsTimeout() async throws {
        let started = Date()
        let slow = await PhoneAppTools.run("/bin/sh", ["-c", "echo begun; sleep 30; echo never"], log: nil, timeout: 0.5)
        #expect(slow.code == PhoneAppTools.timedOutCode && slow.output.contains("begun") && !slow.output.contains("never"))
        #expect(Date().timeIntervalSince(started) < 10, "기한 뒤에 곧 돌아온다")
        // 기한 안에 끝나면 종료 코드와 출력이 그대로다.
        let quick = await PhoneAppTools.run("/bin/sh", ["-c", "echo done; exit 3"], log: nil, timeout: 30)
        #expect(quick.code == 3 && quick.output == "done\n")
        let plain = await PhoneAppTools.run("/bin/echo", ["기한 없음"], log: nil)
        #expect(plain.code == 0 && plain.output == "기한 없음\n")
    }

    @Test func filingStateClearsWhenGHFailsSoTheRecordCanBeFiledAgain() async throws {
        let w = try await world()
        w.store.receive(direct())
        let id = try #require(w.store.items.first?.id)
        w.filer.fail("gh가 60초 안에 끝나지 않아 멈췄습니다.")
        if case .success = await w.model.fileIssue(id) { Issue.record("실패해야 한다") }
        #expect(w.model.issuesInFlight.isEmpty && !w.model.issueQueueBusy, "올리는 중 표시가 남지 않는다")
        w.filer.succeed("https://github.com/example/app/issues/30")
        #expect(try await w.model.fileIssue(id).get().issueNumber == 30)
    }

    // MARK: 에이전트

    @Test func agentSeesThePreviewFirstAndFilesOnlyWithConfirm() async throws {
        let w = try await world()
        w.model.setIssueAuto(false, for: w.project)
        w.store.receive(direct())
        w.store.receive(imported())
        let id = try #require(w.store.items.first { !$0.isImported }?.id)
        let mailed = try #require(w.store.items.first { $0.isImported }?.id)

        #expect(await w.model.handleAgentRequest("issues\n\n\n").text?.contains("이슈로 올린 피드백이 없습니다") == true)
        let preview = await w.model.handleAgentRequest("issue\n\(id)\n\n")
        #expect(preview.ok && preview.issue?.filed == false && preview.issue?.url == nil && preview.issue?.repo == "example/app")
        #expect(preview.issue?.title == "결제 단추가 안 눌려요. [메일] 으로 알려 주세요" && preview.issue?.body.contains("## 환경") == true)
        #expect(preview.text?.contains("아직 올리지 않았습니다") == true && preview.text?.contains("issue \(id) confirm") == true)
        #expect(w.filer.calls.isEmpty, "confirm 없이는 올리지 않는다")
        #expect(await !w.model.handleAgentRequest("issue\n\(id)\nyes\n").ok && w.filer.calls.isEmpty)
        #expect(await !w.model.handleAgentRequest("issue\n\n\n").ok)
        #expect(await !w.model.handleAgentRequest("issue\nc_none\nconfirm\n").ok)

        let filed = await w.model.handleAgentRequest("issue\n\(id)\nconfirm\n")
        #expect(filed.ok && filed.issue?.filed == true && filed.issue?.url == "https://github.com/example/app/issues/12")
        #expect(w.filer.calls.count == 1 && w.filer.calls[0].body == preview.issue?.body && w.filer.calls[0].title == preview.issue?.title)
        // 다시 불러도 올리지 않고 주소를 돌려준다.
        let again = await w.model.handleAgentRequest("issue\n\(id)\nconfirm\n")
        #expect(again.ok && again.text?.contains("이미 이슈로 올린 기록") == true && w.filer.calls.count == 1)

        // 메일로 온 기록은 에이전트가 올리지 못한다.
        let refused = await w.model.handleAgentRequest("issue\n\(mailed)\nconfirm\n")
        #expect(!refused.ok && refused.error?.contains("Mac 앱") == true && w.filer.calls.count == 1)

        let list = try #require(await w.model.handleAgentRequest("issues\n\n\n").text)
        #expect(list.contains("\(id)  https://github.com/example/app/issues/12") && !list.contains(mailed))
        #expect(await w.model.handleAgentRequest("reports\nfeedback\n\n").text?.contains("이슈: https://github.com/example/app/issues/12") == true)

        // 실패는 오류로 돌아오고 기록은 그대로다.
        w.store.receive(direct("또 다른 글"))
        let other = try #require(w.store.items.first { $0.issueURL == nil && !$0.isImported }?.id)
        w.filer.fail("GitHub에 연결하지 못했습니다.")
        let failed = await w.model.handleAgentRequest("issue\n\(other)\nconfirm\n")
        #expect(!failed.ok && failed.error == "GitHub에 연결하지 못했습니다." && w.store.items.first { $0.id == other }?.issueURL == nil)
    }

    @Test func agentReadsTheIssueTargetButCannotChangeIt() async throws {
        let w = try await world(target: nil, origin: "git@github.com:example/app.git")
        let path = w.project.container
        let unset = await w.model.handleAgentRequest("issue-target\n\(path)\n\n")
        #expect(unset.ok && unset.issueTarget?.repo == nil && unset.issueTarget?.auto == false && unset.issueTarget?.suggested == "example/app")
        #expect(unset.text?.contains("git origin은 example/app") == true && unset.text?.contains("이슈 저장소…") == true)
        #expect(w.model.projects.first?.issueTarget == nil, "git origin은 권하기만 하고 저절로 정하지 않는다")

        // 정하기, 지우기, 자동 등록 켜고 끄기는 모두 거절하고 아무것도 바꾸지 않는다.
        for argument in ["https://github.com/example/app.git", "example/app", "auto-on", "auto-off", "clear", "not a repo"] {
            let refused = await w.model.handleAgentRequest("issue-target\n\(path)\n\(argument)\n")
            #expect(!refused.ok && refused.error == ProjectsModel.issueTargetOwnerOnly && refused.issueTarget == nil, "\(argument)")
            #expect(w.model.projects.first?.issueRepo == nil && w.model.projects.first?.issueAuto == nil, "\(argument)")
        }
        #expect(ProjectsModel.issueTargetOwnerOnly.contains("더 보기 > \"이슈 저장소…\"") && ProjectsModel.issueTargetOwnerOnly.contains("사용자에게"))

        // 주인이 화면에서 정한 값은 읽을 수 있고, 그것도 바꾸지 못한다.
        let owned = try w.model.setIssueTarget("example/app", for: w.project).get()
        let manual = await w.model.handleAgentRequest("issue-target\n\(path)\n\n")
        #expect(manual.ok && manual.issueTarget?.repo == "example/app" && manual.issueTarget?.auto == false && manual.text?.contains("자동 등록은 꺼져 있어") == true)
        #expect(await w.model.handleAgentRequest("status\n\n\n").projects?.first?.issueRepo == "example/app")
        w.model.setIssueAuto(true, for: owned)
        let auto = await w.model.handleAgentRequest("issue-target\n\(path)\n\n")
        #expect(auto.ok && auto.issueTarget?.auto == true && auto.text?.contains("자동 등록이 켜져") == true)
        for argument in ["clear", "auto-off", "example/other"] {
            #expect(await !w.model.handleAgentRequest("issue-target\n\(path)\n\(argument)\n").ok)
        }
        #expect(w.model.projects.first?.issueTarget == "example/app" && w.model.projects.first?.filesIssuesAutomatically == true)
        #expect(await !w.model.handleAgentRequest("issue-target\n\n\n").ok)
    }

    @Test func mcpToolSendsTheTwoStepCommandsAndNeverAChange() async throws {
        let sent = Lines()
        let server = AgentMCPServer { command, path, scheme, _ in
            sent.append("\(command)|\(path)|\(scheme)")
            return Data(#"{"ok":true}"#.utf8)
        }
        func call(_ arguments: [String: Any]) async throws -> [String: Any] {
            let request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                      "params": ["name": "remotedebug_feedback_issue", "arguments": arguments]])
            let reply = try #require(await server.handle(request))
            return try #require((JSONSerialization.jsonObject(with: reply) as? [String: Any])?["result"] as? [String: Any])
        }
        _ = try await call(["id": "c_1a2b3c"])
        _ = try await call(["id": "c_1a2b3c", "confirm": false])
        _ = try await call(["id": "c_1a2b3c", "confirm": "true"])
        _ = try await call(["id": "c_1a2b3c", "confirm": true])
        _ = try await call([:])
        _ = try await call(["project_path": "/tmp/App"])
        // 저장소나 자동 등록을 바꾸려는 인자는 Mac 앱에 보내지 않고 거절한다.
        for arguments: [String: Any] in [["project_path": "/tmp/App", "repo": "example/app", "auto": false], ["project_path": "/tmp/App", "repo": ""],
                                         ["project_path": "/tmp/App", "auto": true], ["id": "c_1a2b3c", "confirm": true, "auto": true]] {
            let refused = try await call(arguments)
            #expect(refused["isError"] as? Bool == true)
            let text = try #require(((refused["content"] as? [[String: Any]])?.first)?["text"] as? String)
            #expect(text.contains("에이전트가 바꿀 수 없습니다") && text.contains("이슈 저장소…"))
        }
        #expect(sent.all == ["issue|c_1a2b3c|", "issue|c_1a2b3c|", "issue|c_1a2b3c|", "issue|c_1a2b3c|confirm", "issues||",
                             "issue-target|/tmp/App|"])
    }

    @Test func toolListScriptAndGuidanceNameTheIssueCommands() throws {
        let names = AgentMCPServer.tools.compactMap { $0["name"] as? String }
        #expect(names == ["remotedebug_status", "remotedebug_pairing_code", "remotedebug_pair_requests", "remotedebug_pair_decide",
                          "remotedebug_push_file", "remotedebug_push_link", "remotedebug_files", "remotedebug_schemes", "remotedebug_build",
                          "remotedebug_feedback_setup", "remotedebug_feedback_checklist", "remotedebug_feedback_issue",
                          "remotedebug_device_logs", "remotedebug_import_diagnostics", "remotedebug_crash_logs"])
        let tool = try #require(AgentMCPServer.tools.first { $0["name"] as? String == "remotedebug_feedback_issue" })
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["id", "confirm", "project_path"], "저장소와 자동 등록을 바꾸는 인자는 없다")
        #expect((properties["confirm"] as? [String: Any])?["type"] as? String == "boolean" && (schema["required"] as? [String])?.isEmpty == true)
        let description = try #require(tool["description"] as? String)
        for word in ["confirm: true", "로그와 첨부는 올라가지 않으니", "두 번 올라가지 않고", "바꿀 수 없다", "이슈 저장소…"] { #expect(description.contains(word), "\(word)") }

        let script = AgentScript.text(agentDir: "/tmp/agent", bundleID: "com.example.host")
        #expect(script.contains("issue <기록 id> [confirm] | issues | issue-target <경로>\n") && !script.contains("auto-on") && !script.contains("owner/repo"))
        #expect(script.contains("push|connect|schemes|build|feedback|issue-target)"))
        let usage = AgentScript.usage(script: "/tmp/rd", container: "/tmp/App.xcodeproj")
        for text in [AgentScript.feedbackGuidance, usage, AgentScript.globalSkill(script: "/tmp/rd")] {
            #expect(!text.contains("auto-on") && !text.contains("|clear|") && !text.contains("`repo`"), "바꾸는 명령을 알려 주지 않는다")
            for rule in ["로그와 첨부는 없다", "`report <기록 id>`", "issue <기록 id> confirm", "요청 하나", "나누거나 제목을",
                         "사용자만 정한다", "더 보기 > \"이슈 저장소…\"", "읽기만"] {
                #expect(text.contains(rule), "\(rule)")
            }
        }
        #expect(usage.contains("issue-target '/tmp/App.xcodeproj'"))
        #expect(AgentScript.globalSkill(script: "/tmp/rd").contains("`remotedebug_feedback_issue`"))
    }
}

private final class Seen: @unchecked Sendable {
    let lock = NSLock()
    var runs: [[String]] = [], bodies: [String] = [], modes: [Int] = []
    var outputs: [(Int32, String)] = []
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var all: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}
