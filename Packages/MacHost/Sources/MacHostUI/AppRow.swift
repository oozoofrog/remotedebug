import AppKit
import MacHostKit
import RDModels
import SwiftUI

/// 앱 목록의 한 줄: 아이콘, 앱 이름(프로젝트 이름은 보조), 스킴, [빌드해서 게시], 최신 게시 버전과 시각.
/// 게시 취소·이전 빌드·연결 해제처럼 가끔 쓰는 동작은 더 보기 메뉴에 둔다.
struct AppRow: View {
    let entry: AppListEntry
    let projects: ProjectsModel?
    var expanded = false
    var toggleOlder: () -> Void = {}
    let unpublish: (LibraryBuild) -> Void
    let showInfo: (LibraryBuild) -> Void
    let removeProject: (ConnectedProject) -> Void
    let connectAgents: (ConnectedProject) -> Void

    @Environment(HostModel.self) private var host
    @State private var scheme = ""
    @State private var showsFeedbackSetup = false
    @State private var showsIssueTarget = false
    @State private var feedbackAdded = true
    @State private var choosingFiles = false

    private var build: LibraryBuild? { entry.group?.latest }
    private var older: [LibraryBuild] { entry.group?.older ?? [] }
    /// 이 줄에서 빌드하는 프로젝트(스킴 고르기와 빌드 버튼이 있다).
    private var controls: ConnectedProject? { entry.showsProjectControls ? entry.project : nil }
    private var schemes: [String] { controls.flatMap { projects?.schemes[$0.id] } ?? [] }
    private var phase: ProjectsModel.Phase? { controls.flatMap { projects?.phases[$0.id] } }
    private var isMissing: Bool { controls.map { projects?.missingProjects.contains($0.id) == true } ?? false }
    private var title: String { Self.title(entry) }

    static func title(_ entry: AppListEntry) -> String {
        entry.group?.latest.descriptor.displayName ?? entry.project?.name ?? ""
    }

    /// 앱 이름과 다를 때만 보이는 프로젝트 이름.
    static func projectCaption(_ entry: AppListEntry) -> String? {
        guard let project = entry.project, entry.group != nil, project.name != title(entry) else { return nil }
        return project.name
    }

    /// `1.2 (34) · 게시 3분 전`.
    static func latestText(_ d: BuildDescriptor) -> String {
        String(localized: "\(d.version) (\(d.buildNumber)) · 게시 \(d.publishedAt.formatted(.relative(presentation: .named)))")
    }

    /// 프로비저닝 프로필이 30일 안에 만료되거나 이미 만료됐을 때만 보이는 문장.
    static func profileNotice(_ expires: Date, now: Date = Date()) -> String? {
        let left = expires.timeIntervalSince(now)
        guard left < 30 * 86_400 else { return nil }
        let date = expires.formatted(date: .abbreviated, time: .omitted)
        return left <= 0 ? String(localized: "프로필 만료됨(\(date))") : String(localized: "프로필 만료 \(date)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.title3.weight(.semibold))
                        if let caption = Self.projectCaption(entry) {
                            Text(caption).foregroundStyle(.secondary)
                        }
                        if controls != nil, !feedbackAdded {
                            Button { showsFeedbackSetup = true } label: {
                                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("이 앱은 크래시 기록과 피드백을 Mac에 보내지 않습니다. 눌러서 추가 방법을 봅니다.")
                            .accessibilityLabel("크래시·피드백을 보내지 않음")
                            .accessibilityHint("추가 방법을 엽니다")
                        }
                    }
                    latestLine
                    if let notes = build?.descriptor.releaseNotes {
                        // iPhone의 빌드 줄에 보이는 업데이트 내역. 여기서는 두 줄만 보이고 전체는 도움말에 있다.
                        Text(verbatim: notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(notes)
                            .accessibilityLabel("업데이트 내역: \(notes)")
                    }
                }
                Spacer(minLength: 8)
                if let controls, !isMissing {
                    if !schemes.isEmpty {
                        Picker("스킴", selection: $scheme) {
                            if scheme.isEmpty { Text("스킴 고르기").tag("") }
                            ForEach(schemes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        .accessibilityLabel("\(title) 스킴")
                    }
                    Button {
                        Task { await projects?.build(controls, scheme: scheme) }
                    } label: {
                        Label("빌드해서 게시", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(scheme.isEmpty || phase != nil)
                    .accessibilityLabel("\(title) 빌드해서 게시")
                }
                moreMenu
            }
            status
            if expanded, !older.isEmpty {
                Divider()
                ForEach(older) { old in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(old.descriptor.version) (\(old.descriptor.buildNumber))")
                        Text("게시 \(old.descriptor.publishedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("게시 취소") { unpublish(old) }
                            .controlSize(.small)
                            .accessibilityLabel("\(old.descriptor.displayName) \(old.descriptor.publishedAt.formatted(date: .abbreviated, time: .shortened)) 빌드 게시 취소")
                    }
                    .font(.callout)
                }
            }
        }
        .rdCard()
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showsFeedbackSetup, onDismiss: refreshFeedback) {
            if let controls {
                FeedbackSetupSheet(project: controls, host: host.status?.fqdn ?? "")
            }
        }
        .sheet(isPresented: $showsIssueTarget) {
            if let controls, let projects {
                // 저장한 값이 다시 열 때 보이도록 지금 목록의 항목을 넘긴다.
                IssueTargetSheet(project: projects.projects.first { $0.id == controls.id } ?? controls, projects: projects)
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, let controls else { return }
            Task {
                // 파일 고르기 창이 준 주소는 보안 범위 접근이 필요할 수 있다.
                let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
                defer { for (url, started) in scoped where started { url.stopAccessingSecurityScopedResource() } }
                // 보낸 파일 화면의 이 프로젝트 구역에 들어간다.
                await host.shareFiles(urls, project: controls.resourceArea)
            }
        }
        .onChange(of: schemes) { pickScheme() }
        .task(id: controls?.id) {
            guard let controls, let projects else { return }
            refreshFeedback()
            if projects.schemes[controls.id] == nil { await projects.loadSchemes(for: controls) }
            pickScheme()
        }
    }

    @ViewBuilder private var icon: some View {
        if let build {
            BuildIcon(name: build.descriptor.displayName, seed: build.descriptor.bundleId, icon: build.descriptor.icon, sourcePath: build.sourcePath)
        } else if let project = entry.project {
            AppTile(name: project.name, seed: project.container, symbol: "hammer.fill")
        }
    }

    private var latestLine: some View {
        HStack(spacing: 10) {
            if let d = build?.descriptor {
                Text(Self.latestText(d))
                    .help(d.publishedAt.formatted(date: .abbreviated, time: .shortened))
                if let notice = Self.profileNotice(d.signing.profileExpires) {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .foregroundStyle(d.signing.profileExpires.timeIntervalSinceNow < 7 * 86_400 ? Color.orange : Color.secondary)
                }
                if host.installsInProgress.contains(where: { session in session.buildId == d.id || older.contains { $0.id == session.buildId } }) {
                    Label("iPhone이 받는 중", systemImage: "arrow.down.circle")
                }
            } else {
                Text("아직 게시한 빌드 없음")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var status: some View {
        if let controls, isMissing {
            HStack(spacing: 8) {
                Label("폴더를 찾을 수 없음", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.orange)
                    .help(controls.container)
                Button("연결 해제…") { removeProject(controls) }
                    .controlSize(.small)
            }
            .font(.callout)
        } else if let controls, let phase {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(Self.text(for: phase)).foregroundStyle(.secondary)
            }
            .font(.callout)
            if phase == .loadingSchemes, let started = projects?.schemeLoadStarted[controls.id] {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    if context.date.timeIntervalSince(started) >= ProjectsModel.slowSchemeLoad {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("스킴을 읽는 데 오래 걸리고 있습니다. xcodebuild가 Swift 패키지를 받거나 프로젝트를 여는 중일 수 있습니다.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("다시 시도") { Task { await projects?.retrySchemes(for: controls) } }
                                .controlSize(.small)
                        }
                        .font(.callout)
                    }
                }
            }
        } else if let controls {
            let report = projects?.reports[controls.id]
            if let report, let message = report.message {
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: report.ok ? "info.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.ok ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                    if let tail = report.logTail, !tail.isEmpty {
                        Text(tail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !report.ok, let path = report.logPath {
                        Button("전체 로그 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
            }
            if let loaded = projects?.schemes[controls.id] {
                if loaded.isEmpty {
                    HStack(spacing: 8) {
                        Text("빌드할 스킴이 없습니다.").foregroundStyle(.secondary)
                        Button("스킴 다시 읽기") { Task { await reloadSchemes() } }
                            .controlSize(.small)
                    }
                    .font(.callout)
                }
            } else if report?.ok == false, report?.scheme == nil {
                // 스킴 읽기가 실패했다(이유는 위 문장).
                Button("스킴 다시 읽기") { Task { await reloadSchemes() } }
                    .controlSize(.small)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let build {
                Button("빌드 정보…") { showInfo(build) }
                if !older.isEmpty {
                    Button(expanded ? String(localized: "이전 빌드 숨기기") : String(localized: "이전 빌드 \(older.count)개 보기"), action: toggleOlder)
                }
            }
            if let controls {
                Divider()
                Button("파일 보내기…") { choosingFiles = true }
                Button("크래시·피드백 보내기 추가…") { showsFeedbackSetup = true }
                Button("이슈 저장소…") { showsIssueTarget = true }
                Button("에이전트 연결…") { connectAgents(controls) }
                Button("스킴 다시 읽기") { Task { await reloadSchemes() } }
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([controls.containerURL]) }
            }
            if build != nil || controls != nil {
                Divider()
            }
            if let build {
                Button("게시 취소…", role: .destructive) { unpublish(build) }
            }
            if let controls {
                Button("연결 해제…", role: .destructive) { removeProject(controls) }
            }
        } label: {
            Label("더 보기", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("더 보기")
        .accessibilityLabel("\(title) 더 보기")
    }

    private func refreshFeedback() {
        guard let controls else { return }
        feedbackAdded = FeedbackSetup.isAdded(to: controls)
    }

    private func reloadSchemes() async {
        guard let controls, let projects else { return }
        await projects.retrySchemes(for: controls)
        pickScheme()
    }

    private func pickScheme() {
        guard let controls, let projects else { return }
        if scheme.isEmpty || !schemes.contains(scheme) {
            scheme = projects.preferredScheme(for: controls) ?? ""
        }
    }

    static func text(for phase: ProjectsModel.Phase) -> String {
        switch phase {
        case .loadingSchemes: String(localized: "스킴을 읽는 중")
        case .building(let scheme): String(localized: "\(scheme) 스킴을 Debug 기기용으로 빌드하는 중")
        case .importing: String(localized: "빌드를 검사하고 게시하는 중")
        }
    }
}

/// 빌드의 세부 정보: 번들 ID, 구성을 확인한 근거, 서명, 원본 위치.
struct BuildInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let build: LibraryBuild
    var project: ConnectedProject?

    private var d: BuildDescriptor { build.descriptor }

    static func evidence(_ d: BuildDescriptor) -> String {
        switch d.configurationEvidence {
        case .path: String(localized: "\(d.configuration) · \(d.configuration)-iphoneos 폴더")
        case .debugDylib: String(localized: "\(d.configuration) · debug.dylib 있음")
        case .userConfirmed: String(localized: "\(d.configuration) · 직접 확인")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                BuildIcon(name: d.displayName, seed: d.bundleId, icon: d.icon, sourcePath: build.sourcePath, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.displayName).font(.title2.bold())
                    Text("\(d.version) (\(d.buildNumber))").foregroundStyle(.secondary)
                }
            }
            Form {
                LabeledContent("번들 ID") { Text(d.bundleId).monospaced().textSelection(.enabled) }
                LabeledContent("구성") { Text(Self.evidence(d)) }
                LabeledContent("게시") { Text(d.publishedAt.formatted(date: .abbreviated, time: .shortened)) }
                LabeledContent("프로필") { Text(d.signing.profileName).textSelection(.enabled) }
                LabeledContent("프로필 만료") { Text(d.signing.profileExpires.formatted(date: .abbreviated, time: .omitted)) }
                if let project {
                    LabeledContent("프로젝트") { Text(project.name) }
                }
                LabeledContent("원본") {
                    Text(build.sourcePath)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
