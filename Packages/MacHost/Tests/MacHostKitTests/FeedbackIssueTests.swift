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

        var calls: [(repo: String, title: String, body: String)] { lock.withLock { stored } }
        func fail(_ message: String) { lock.withLock { answer = .failure(IssueFailure(message)) } }
        func succeed(_ url: String) { lock.withLock { answer = .success(url) } }

        func create(repo: String, title: String, body: String) async -> Result<String, IssueFailure> {
            lock.withLock {
                stored.append((repo, title, body))
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
    private func world(target: String? = "example/app", origin: String? = nil) async throws -> World {
        let tmp = try TempDir("issue")
        let store = CrashLogStore(directory: tmp.path("state/CrashLogs"), now: { [start] in start })
        let filer = FakeFiler()
        let model = ProjectsModel(root: tmp.path("state"), builder: AdviceBuilder(app: tmp.path("p/App.app")),
                                  scanner: DerivedDataScanner(root: tmp.path("DerivedData")),
                                  crashLogs: store, issueFiler: filer, originURL: { _ in origin }) { _ in nil }
        var project = try #require(await model.connect(tmp.path("p/App.xcodeproj")))
        model.notePublished(bundle, by: project)
        if let target { project = try model.setIssueTarget(target, for: project).get() }
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
        // 쿼리나 로그인 정보가 든 주소는 통째로, 그렇지 않은 주소는 그대로.
        #expect(s("https://example.com/pay?token=abc&u=1 에서") == "[주소] 에서")
        #expect(s("ftp://user:pw@example.com/file") == "[주소]")
        #expect(s("myapp://open?id=42") == "[주소]")
        #expect(s("https://example.com/docs/page 참고") == "https://example.com/docs/page 참고")
        // tailnet과 노드 이름.
        #expect(s("rd-mac-1a2b3c4d.tail0001.ts.net 에 안 붙어요") == "[호스트] 에 안 붙어요")
        #expect(s("http://RD-MAC-1A2B3C4D.Tail0001.TS.NET/x") == "http://[호스트]/x")
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
        #expect(s("/Users/someone/Documents/a.txt 를 열면") == "[경로] 를 열면")
        #expect(s("~/Library/Logs/x.log") == "[경로]")
        // GitHub이 알림을 보내지 않게 @ 뒤를 끊는다.
        #expect(s("@octocat 확인") == "@\u{200B}octocat 확인")
        #expect(s("그냥 글 한 줄, 숫자 42와 100% 그리고 a/b") == "그냥 글 한 줄, 숫자 42와 100% 그리고 a/b")
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
                                     scanner: DerivedDataScanner(root: w.tmp.path("DerivedData"))) { _ in nil }
        reopened.load()
        #expect(reopened.projects.first?.issueTarget == "example/app" && reopened.projects.first?.issueAuto == false)
        guard case .failure(let bad) = w.model.setIssueTarget("not a repo", for: w.project) else { Issue.record("모양이 아닌 저장소를 받았다"); return }
        #expect(bad.message.contains("owner/repo"))
        #expect(try w.model.setIssueTarget("", for: w.project).get().issueTarget == nil)
    }

    // MARK: 자동과 수동

    @Test func directFeedbackIsFiledOnArrivalAndImportedFeedbackNever() async throws {
        let w = try await world()
        #expect(w.project.filesIssuesAutomatically, "저장소를 정하면 자동 등록이 켜진 채로 시작한다")
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

        // gh가 없으면 아무것도 돌리지 않는다.
        seen.runs = []
        let missing = GHIssueFiler(tool: { nil }, run: { _, _ in seen.lock.withLock { seen.runs.append([]) }; return (0, "") }, tempDirectory: tmp.path("none"))
        guard case .failure(let noTool) = await missing.create(repo: "example/app", title: "제목", body: body) else { Issue.record("gh 없이 성공했다"); return }
        #expect(noTool.message.contains("gh 명령을 찾지 못했습니다") && seen.runs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tmp.path("none").path))
        #expect(GHIssueFiler.issueURL(in: "https://github.com/example/app/issues/3\nhttps://github.com/example/app/issues/4") == "https://github.com/example/app/issues/4")
        #expect(GHIssueFiler.issueURL(in: "https://example.com/example/app/issues/3") == nil)
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

    @Test func agentReadsAndSetsTheIssueTarget() async throws {
        let w = try await world(target: nil, origin: "git@github.com:example/app.git")
        let path = w.project.container
        let unset = await w.model.handleAgentRequest("issue-target\n\(path)\n\n")
        #expect(unset.ok && unset.issueTarget?.repo == nil && unset.issueTarget?.auto == false && unset.issueTarget?.suggested == "example/app")
        #expect(unset.text?.contains("git origin은 example/app") == true)
        #expect(w.model.projects.first?.issueTarget == nil, "git origin은 권하기만 하고 저절로 정하지 않는다")

        let set = await w.model.handleAgentRequest("issue-target\n\(path)\nhttps://github.com/example/app.git\n")
        #expect(set.ok && set.issueTarget?.repo == "example/app" && set.issueTarget?.auto == true && set.text?.contains("자동 등록이 켜져") == true)
        #expect(await w.model.handleAgentRequest("status\n\n\n").projects?.first?.issueRepo == "example/app")
        let off = await w.model.handleAgentRequest("issue-target\n\(path)\nauto-off\n")
        #expect(off.ok && off.issueTarget?.auto == false && w.model.projects.first?.filesIssuesAutomatically == false)
        #expect(await w.model.handleAgentRequest("issue-target\n\(path)\nauto-on\n").issueTarget?.auto == true)
        #expect(await !w.model.handleAgentRequest("issue-target\n\(path)\nnot a repo\n").ok)
        let cleared = await w.model.handleAgentRequest("issue-target\n\(path)\nclear\n")
        #expect(cleared.ok && cleared.issueTarget?.repo == nil && w.model.projects.first?.issueTarget == nil)
        #expect(await !w.model.handleAgentRequest("issue-target\n\n\n").ok)
    }

    @Test func mcpToolSendsTheTwoStepCommands() async throws {
        let sent = Lines()
        let server = AgentMCPServer { command, path, scheme, _ in
            sent.append("\(command)|\(path)|\(scheme)")
            return Data((scheme == "bad/" ? #"{"ok":false,"error":"모양"}"# : #"{"ok":true}"#).utf8)
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
        _ = try await call(["project_path": "/tmp/App", "repo": "example/app", "auto": false])
        _ = try await call(["project_path": "/tmp/App", "repo": ""])
        #expect(try await call(["project_path": "/tmp/App", "repo": "bad/", "auto": true])["isError"] as? Bool == true)
        #expect(sent.all == ["issue|c_1a2b3c|", "issue|c_1a2b3c|", "issue|c_1a2b3c|", "issue|c_1a2b3c|confirm", "issues||",
                             "issue-target|/tmp/App|", "issue-target|/tmp/App|example/app", "issue-target|/tmp/App|auto-off",
                             "issue-target|/tmp/App|clear", "issue-target|/tmp/App|bad/"])
    }

    @Test func toolListScriptAndGuidanceNameTheIssueCommands() throws {
        let names = AgentMCPServer.tools.compactMap { $0["name"] as? String }
        #expect(names == ["remotedebug_status", "remotedebug_pairing_code", "remotedebug_pair_requests", "remotedebug_pair_decide",
                          "remotedebug_push_file", "remotedebug_push_link", "remotedebug_files", "remotedebug_schemes", "remotedebug_build",
                          "remotedebug_feedback_setup", "remotedebug_feedback_checklist", "remotedebug_feedback_issue",
                          "remotedebug_device_logs", "remotedebug_crash_logs"])
        let tool = try #require(AgentMCPServer.tools.first { $0["name"] as? String == "remotedebug_feedback_issue" })
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["id", "confirm", "project_path", "repo", "auto"])
        #expect((properties["confirm"] as? [String: Any])?["type"] as? String == "boolean" && (schema["required"] as? [String])?.isEmpty == true)
        let description = try #require(tool["description"] as? String)
        for word in ["confirm: true", "로그와 첨부는 올라가지 않으니", "두 번 올라가지 않고"] { #expect(description.contains(word), "\(word)") }

        let script = AgentScript.text(agentDir: "/tmp/agent", bundleID: "com.example.host")
        #expect(script.contains("issue <기록 id> [confirm] | issues | issue-target <경로> [owner/repo|clear|auto-on|auto-off]"))
        #expect(script.contains("push|connect|schemes|build|feedback|issue-target)"))
        let usage = AgentScript.usage(script: "/tmp/rd", container: "/tmp/App.xcodeproj")
        for text in [AgentScript.feedbackGuidance, usage, AgentScript.globalSkill(script: "/tmp/rd")] {
            for rule in ["로그와 첨부는 없다", "`report <기록 id>`", "issue <기록 id> confirm", "요청 하나", "나누거나 제목을"] {
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
