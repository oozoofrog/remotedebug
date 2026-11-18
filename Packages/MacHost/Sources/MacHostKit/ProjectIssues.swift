import Foundation
import RDModels

/// 받은 피드백을 그 앱의 GitHub 저장소에 이슈로 올린다.
///
/// - 어느 저장소인지는 프로젝트마다 정한다(`ConnectedProject.issueRepo`). 정하지 않은 프로젝트의 피드백은 올리지 않는다.
/// - 피드백이 어느 프로젝트 것인지는 번들 ID로 안다(그 프로젝트에서 게시한 앱의 번들 ID).
/// - 페어링한 기기가 바로 보낸 피드백은 자동 등록이 켜져 있으면 받는 대로 올린다. 메일에 붙어 온 진단 파일에서 넣은 기록은
///   저절로 올리지 않고, 사람이 Mac 화면에서 제목과 본문을 보고 눌러야 올린다.
/// - 같은 기록은 한 번만 올린다. 올린 주소는 기록에 남는다.
extension ProjectsModel {
    /// 올리기 전에 보여 줄 것.
    public struct IssuePreview: Sendable, Hashable, Identifiable {
        public var id: String { item.id }
        public var item: CrashLogStore.Item
        public var project: ConnectedProject
        public var repo: String
        public var draft: FeedbackIssueDraft
    }

    struct AgentIssue: Codable, Hashable {
        var recordId: String
        var repo: String
        var title: String
        var body: String
        /// 올린 이슈의 주소. 아직 올리지 않았으면 없다.
        var url: String?
        var filed: Bool
    }

    struct AgentIssueTarget: Codable, Hashable {
        var project: String
        /// 이슈 저장소. 정하지 않았으면 없다.
        var repo: String?
        /// 페어링한 기기가 보낸 피드백을 받는 대로 올리는지.
        var auto: Bool
        /// 프로젝트 폴더의 git origin에서 읽은 저장소(정할 때 참고).
        var suggested: String?
    }

    // MARK: 저장소 정하기

    /// 프로젝트 폴더의 git origin이 github.com 저장소면 `owner/repo`. 화면과 에이전트가 정할 값을 권할 때 쓴다.
    public func suggestedIssueTarget(for project: ConnectedProject) async -> String? {
        await originURL(project.folder).flatMap(IssueTarget.fromRemote)
    }

    /// 이슈 저장소를 정한다. 빈 글자면 지운다(이 프로젝트의 피드백을 올리지 않는다).
    @discardableResult
    public func setIssueTarget(_ text: String, for project: ConnectedProject) -> Result<ConnectedProject, IssueFailure> {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var repo: String?
        if !text.isEmpty {
            guard let normalized = IssueTarget.normalized(text) else {
                return .failure(IssueFailure(String(localized: "저장소는 owner/repo 모양이어야 합니다(예: example/app). 받은 값: \(text)")))
            }
            repo = normalized
        }
        guard let updated = updateProject(project.id, { $0.issueRepo = repo }) else {
            return .failure(IssueFailure(String(localized: "연결한 프로젝트가 아닙니다: \(project.name)")))
        }
        return .success(updated)
    }

    /// 페어링한 기기가 보낸 피드백을 받는 대로 올릴지 정한다.
    @discardableResult
    public func setIssueAuto(_ on: Bool, for project: ConnectedProject) -> ConnectedProject? {
        updateProject(project.id) { $0.issueAuto = on }
    }

    // MARK: 미리보기와 올리기

    /// 이 기록을 이슈로 올리면 어디에 무엇이 올라가는지. 올릴 수 없으면 까닭.
    public func issuePreview(for id: String) -> Result<IssuePreview, IssueFailure> {
        load()
        guard let crashLogs else { return .failure(IssueFailure(String(localized: "받은 기록을 읽을 수 없습니다."))) }
        guard let item = crashLogs.items.first(where: { $0.id == id }) else {
            return .failure(IssueFailure(String(localized: "\(id) 기록이 없습니다.")))
        }
        guard item.kind == .feedback else {
            return .failure(IssueFailure(String(localized: "피드백만 이슈로 올립니다. 크래시 기록은 원문이 로그라서 올리지 않습니다.")))
        }
        guard !item.bundleId.isEmpty, let project = project(publishing: item.bundleId) else {
            return .failure(IssueFailure(item.bundleId.isEmpty
                ? String(localized: "이 피드백에는 보낸 앱의 번들 ID가 없어 어느 저장소에 올릴지 알 수 없습니다.")
                : String(localized: "\(item.bundleId) 앱을 게시한 연결한 프로젝트가 없어 어느 저장소에 올릴지 알 수 없습니다. 그 앱의 프로젝트를 연결해 한 번 게시한 뒤 다시 시도하세요.")))
        }
        guard let repo = project.issueTarget else {
            return .failure(IssueFailure(String(localized: "\(project.name) 프로젝트에 이슈 저장소가 정해져 있지 않습니다. 앱 화면에서 그 프로젝트의 더 보기 메뉴 > \"이슈 저장소…\"로 정하세요.")))
        }
        guard let text = crashLogs.text(item) else { return .failure(IssueFailure(String(localized: "\(id) 기록의 원문 파일을 읽을 수 없습니다."))) }
        return .success(IssuePreview(item: item, project: project, repo: repo, draft: FeedbackIssue.draft(item: item, text: text)))
    }

    /// 기록을 이슈로 올리고 주소를 기록에 남긴다. 이미 올린 기록이면 아무것도 올리지 않고 그 기록을 돌려준다.
    /// `draft`를 주면 그 제목과 본문으로 올린다(사람이 미리보기에서 고친 것).
    @discardableResult
    public func fileIssue(_ id: String, draft: FeedbackIssueDraft? = nil) async -> Result<CrashLogStore.Item, IssueFailure> {
        let preview: IssuePreview
        switch issuePreview(for: id) {
        case .success(let found): preview = found
        case .failure(let failure): return .failure(failure)
        }
        if preview.item.issueURL != nil { return .success(preview.item) }
        guard issuesInFlight.insert(id).inserted else { return .failure(IssueFailure(String(localized: "이 기록은 지금 올리는 중입니다."))) }
        defer { issuesInFlight.remove(id) }
        let chosen = draft ?? preview.draft
        let title = FeedbackIssue.clip(chosen.title.trimmingCharacters(in: .whitespacesAndNewlines), 250)
        guard !title.isEmpty else { return .failure(IssueFailure(String(localized: "이슈 제목이 비어 있습니다."))) }
        switch await issueFiler.create(repo: preview.repo, title: title, body: chosen.body) {
        case .success(let url):
            issueErrors[id] = nil
            guard let saved = crashLogs?.setIssue(id, url: url) else {
                return .failure(IssueFailure(String(localized: "이슈는 올라갔지만(\(url)) 기록이 그 사이에 지워져 주소를 남기지 못했습니다.")))
            }
            return .success(saved)
        case .failure(let failure):
            issueErrors[id] = failure.message
            return .failure(failure)
        }
    }

    /// 받는 대로 올릴 기록인가: 페어링한 기기가 바로 보낸 피드백이고, 그 프로젝트에 저장소가 있고 자동 등록이 켜져 있다.
    /// 메일에 붙어 온 진단 파일에서 넣은 기록은 언제나 아니다.
    public func filesAutomatically(_ item: CrashLogStore.Item) -> Bool {
        load()
        guard item.kind == .feedback, !item.isImported, item.issueURL == nil, !item.bundleId.isEmpty else { return false }
        return project(publishing: item.bundleId)?.filesIssuesAutomatically == true
    }

    /// 새로 받은 기록을 규칙에 맞으면 올린다. 실패하면 `issueErrors`에 까닭을 남기고 다시 시도하지 않는다.
    public func receivedForIssue(_ item: CrashLogStore.Item) async {
        guard filesAutomatically(item) else { return }
        await fileIssue(item.id)
    }

    // MARK: 에이전트 명령

    /// `issue <기록 id> [confirm]`: `confirm` 없이는 올라갈 제목과 본문만 돌려준다.
    func issueResponse(id: String, argument: String) async -> AgentResponse {
        let id = id.trimmingCharacters(in: .whitespaces), argument = argument.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return AgentResponse(ok: false, error: "기록 id가 필요합니다. reports feedback으로 목록을 확인하세요.") }
        guard argument.isEmpty || argument == "confirm" else {
            return AgentResponse(ok: false, error: "issue <기록 id> 다음에는 confirm만 올 수 있습니다. 받은 값: \(argument)")
        }
        let preview: IssuePreview
        switch issuePreview(for: id) {
        case .success(let found): preview = found
        case .failure(let failure): return AgentResponse(ok: false, error: failure.message)
        }
        func info(_ item: CrashLogStore.Item) -> AgentIssue {
            AgentIssue(recordId: id, repo: preview.repo, title: preview.draft.title, body: preview.draft.body,
                       url: item.issueURL, filed: item.issueURL != nil)
        }
        if let url = preview.item.issueURL {
            return AgentResponse(ok: true, text: "이미 이슈로 올린 기록입니다: \(url). 다시 올리지 않습니다.", issue: info(preview.item))
        }
        guard !preview.item.isImported else {
            return AgentResponse(ok: false, error: "메일에 붙어 온 진단 파일에서 넣은 기록은 에이전트가 올리지 않습니다. 사용자가 RemoteDebug Mac 앱의 크래시·피드백 화면에서 '이슈로 등록…'으로 제목과 본문을 확인하고 올립니다.")
        }
        guard argument == "confirm" else {
            return AgentResponse(ok: true,
                                 text: "아직 올리지 않았습니다. issue.title과 issue.body가 저장소 \(preview.repo)에 그대로 올라갑니다(공개 저장소면 누구나 봅니다). 로그와 첨부는 올라가지 않습니다. 올리려면 issue \(id) confirm(MCP는 confirm: true)으로 다시 부르세요.",
                                 issue: info(preview.item))
        }
        switch await fileIssue(id) {
        case .success(let item):
            return AgentResponse(ok: true, text: "이슈로 올렸습니다: \(item.issueURL ?? "")", issue: info(item))
        case .failure(let failure):
            return AgentResponse(ok: false, error: failure.message)
        }
    }

    /// `issues`: 이슈로 올린 기록 목록.
    func issuesResponse() -> AgentResponse {
        let filed = (crashLogs?.items ?? []).filter { $0.issueURL != nil }
        guard !filed.isEmpty else {
            return AgentResponse(ok: true, text: "이슈로 올린 피드백이 없습니다. 올릴 수 있는 기록은 reports feedback으로 보고, issue <기록 id>로 올라갈 내용을 먼저 확인합니다.")
        }
        let lines = filed.map { item in
            "\(item.id)  \(item.issueURL ?? "")  \(item.issueFiledAt.map(CrashLogStore.dayText) ?? "")  \(item.bundleId) \(item.appVersion)"
        }
        return AgentResponse(ok: true, text: (["# 이슈로 올린 피드백 \(filed.count)개 (기록 id, 이슈 주소, 올린 날, 앱과 빌드). 이슈에는 로그와 첨부가 없다. report <기록 id>로 읽는다"] + lines).joined(separator: "\n"))
    }

    /// `issue-target <프로젝트 경로> [owner/repo|clear|auto-on|auto-off]`: 인자가 없으면 지금 값을 돌려준다.
    func issueTargetResponse(project: ConnectedProject, argument: String) async -> AgentResponse {
        let argument = argument.trimmingCharacters(in: .whitespaces)
        var project = project
        var text: String
        switch argument {
        case "":
            text = project.issueTarget.map { "이슈 저장소: \($0)." } ?? "이슈 저장소가 정해져 있지 않아 이 프로젝트의 피드백은 이슈로 올리지 않습니다."
        case "clear":
            if case .success(let updated) = setIssueTarget("", for: project) { project = updated }
            text = "이슈 저장소를 지웠습니다. 이 프로젝트의 피드백은 이슈로 올리지 않습니다."
        case "auto-on", "auto-off":
            project = setIssueAuto(argument == "auto-on", for: project) ?? project
            text = argument == "auto-on" ? "자동 등록을 켰습니다." : "자동 등록을 껐습니다. issue <기록 id> confirm이나 Mac 화면의 '이슈로 등록…'으로만 올립니다."
        default:
            switch setIssueTarget(argument, for: project) {
            case .success(let updated):
                project = updated
                text = "이슈 저장소를 \(updated.issueTarget ?? "")로 정했습니다."
            case .failure(let failure):
                return AgentResponse(ok: false, error: failure.message)
            }
        }
        if project.filesIssuesAutomatically {
            text += " 자동 등록이 켜져 있어, 페어링한 기기가 Debug 빌드에서 보낸 피드백은 받는 대로 올립니다(글, 앱 버전, OS, 기기 종류, 확인 목록의 답만. 로그와 첨부는 올리지 않는다). 끄려면 auto-off."
        }
        let suggested = await suggestedIssueTarget(for: project)
        if project.issueTarget == nil, let suggested {
            text += " 이 프로젝트의 git origin은 \(suggested)입니다. 사용자에게 물어 정하세요."
        }
        return AgentResponse(ok: true, text: text,
                             issueTarget: AgentIssueTarget(project: project.name, repo: project.issueTarget,
                                                           auto: project.filesIssuesAutomatically, suggested: suggested))
    }
}
