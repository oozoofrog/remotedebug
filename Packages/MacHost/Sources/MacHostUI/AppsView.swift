import AppKit
import MacHostKit
import RDModels
import SwiftUI

/// 앱 목록의 한 줄: 같은 앱(번들 ID)의 빌드 묶음, 그 빌드를 만든 연결한 프로젝트, 또는 둘 다.
struct AppListEntry: Identifiable {
    var group: AppBuildGroup<LibraryBuild>?
    var project: ConnectedProject?
    /// 스킴 고르기와 빌드 버튼을 이 줄에 둔다. 프로젝트가 앱을 여럿 만들면 가장 최근에 게시한 줄에만 둔다.
    var showsProjectControls: Bool

    var id: String { group.map { "app:\($0.bundleId)" } ?? "project:\(project?.id ?? "")" }
    /// 최근 게시 시각. 빌드가 없으면 프로젝트를 연결한 시각.
    var recency: Date { group?.latest.descriptor.publishedAt ?? project?.addedAt ?? .distantPast }
}

enum AppList {
    /// 빌드 묶음과 연결한 프로젝트를 한 목록으로 합친다. 최근에 게시하거나 연결한 것이 위에 온다.
    static func entries(builds: [LibraryBuild], projects: [ConnectedProject],
                        owner: (LibraryBuild) -> ConnectedProject?) -> [AppListEntry] {
        var entries: [AppListEntry] = []
        var controlled: Set<String> = []
        // 묶음은 최근 게시 순이라 프로젝트의 첫 묶음이 가장 최근 것이다.
        for group in AppBuildGrouping.groups(builds, descriptor: { $0.descriptor }) {
            let project = ([group.latest] + group.older).lazy.compactMap(owner).first
            let controls = project.map { controlled.insert($0.id).inserted } ?? false
            entries.append(AppListEntry(group: group, project: project, showsProjectControls: controls))
        }
        for project in projects where !controlled.contains(project.id) {
            entries.append(AppListEntry(group: nil, project: project, showsProjectControls: true))
        }
        return entries.enumerated()
            .sorted { $0.element.recency != $1.element.recency ? $0.element.recency > $1.element.recency : $0.offset < $1.offset }
            .map(\.element)
    }
}

/// 첫 화면: 앱 하나가 한 줄. 프로젝트를 연결한 앱은 그 줄에서 빌드해 게시한다.
struct AppsView: View {
    @Environment(HostModel.self) private var model
    @Environment(ProjectsModel.self) private var projects: ProjectsModel?
    @Environment(LinkedProjectsModel.self) private var linkedProjects: LinkedProjectsModel?
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.connectProjects) private var connectProjects
    let showImporter: () -> Void

    @State private var choosingFolder = false
    @State private var choosingProject = false
    @State private var buildToUnpublish: LibraryBuild?
    @State private var projectToRemove: ConnectedProject?
    @State private var buildToInspect: LibraryBuild?
    @State private var showingAgentInstall = false
    @State private var showingLinkedProjects = false
    @State private var agentNotice: String?
    @State private var expandedApps: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entries: [AppListEntry] {
        Self.entries(model: model, projects: projects)
    }

    @MainActor
    static func entries(model: HostModel, projects: ProjectsModel?) -> [AppListEntry] {
        AppList.entries(builds: model.builds, projects: projects?.projects ?? []) { build in
            projects?.owner(sourcePath: build.sourcePath, bundleId: build.descriptor.bundleId)
        }
    }

    var body: some View {
        Group {
            if Self.showsEmptyState(model: model, pendingCount: importQueue.pending.count,
                                    projectCount: (projects?.projects.count ?? 0) + (projects?.suggestions.count ?? 0)) {
                // 시작하기 카드와 빈 상태 안내를 합치면 창보다 클 수 있다. 넘치면 스크롤하고, 남으면 안내를 가운데에 둔다.
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            header
                            emptyState
                                .frame(maxHeight: .infinity)
                        }
                        .frame(minHeight: proxy.size.height)
                    }
                }
            } else {
                // 머리(시작하기 카드)는 목록의 첫 줄로 넣어 함께 스크롤한다.
                // 목록 위에 따로 두면 낮은 창에서 높이 합이 창을 넘어 화면 전체가 위로 밀린다.
                list
            }
        }
        .navigationTitle("앱")
        .toolbar {
            ToolbarItemGroup {
                if model.importsInProgress > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("빌드 \(model.importsInProgress)개 가져오는 중")
                }
                Menu {
                    Button("빌드 가져오기…", action: showImporter)
                    // 샌드박스판은 프로젝트를 등록해 최근 빌드를 찾는다. 폴더 감시는 두지 않는다.
                    if !HostEdition.isSandboxed {
                        Button("폴더 감시…") { choosingFolder = true }
                    }
                    if HostEdition.isSandboxed, linkedProjects != nil {
                        Button("등록한 프로젝트…") { showingLinkedProjects = true }
                    }
                    if projects != nil {
                        Divider()
                        Button("에이전트에 설치…") { showingAgentInstall = true }
                    }
                } label: {
                    Label("가져오기", systemImage: "square.and.arrow.down")
                }
                .help("빌드 파일(.app, .ipa) 가져오기와 폴더 감시")
                Button { choosingProject = true } label: {
                    Label("프로젝트 추가…", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .help("프로젝트 폴더나 Xcode 프로젝트 파일을 고릅니다")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let projects, projects.scanStalled {
                    Label("Xcode 빌드 폴더(\(projects.derivedDataPath))를 읽지 못하고 있습니다. Xcode에서 한 빌드를 가져오지 못하고 등록 제안도 나오지 않습니다. 디스크 연결과 시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더의 RemoteDebug 항목을 확인하세요.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.bar)
                }
                if let projects, let message = projects.lastError {
                    ErrorBanner(message: message) { projects.lastError = nil }
                }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.chooseFolder(url) }
        }
        .background {
            // fileImporter는 뷰 하나에 하나만 동작한다.
            Color.clear
                .fileImporter(isPresented: $choosingProject, allowedContentTypes: HostEdition.isSandboxed ? [.folder] : [.folder, .package, .item],
                              allowsMultipleSelection: true) { result in
                    guard case .success(let urls) = result else { return }
                    connectProjects(urls)
                }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let builds = urls.filter { ["app", "ipa"].contains($0.pathExtension.lowercased()) }
            let projectURLs = ProjectConnector.projectURLs(in: urls)
            if !projectURLs.isEmpty { connectProjects(projectURLs) }
            guard !builds.isEmpty else { return !projectURLs.isEmpty }
            Task { await importQueue.importURLs(builds) { [model] url, mode in await model.importBuild(url, mode: mode) } }
            return true
        }
        .confirmationDialog(
            "게시를 취소할까요?",
            isPresented: Binding(get: { buildToUnpublish != nil }, set: { if !$0 { buildToUnpublish = nil } }),
            presenting: buildToUnpublish
        ) { build in
            Button("게시 취소", role: .destructive) {
                Task { await model.unpublish(build.id) }
            }
            Button("돌아가기", role: .cancel) {}
        } message: { build in
            Text("\(build.descriptor.displayName) \(build.descriptor.version) (\(build.descriptor.buildNumber)): iPhone의 빌드 목록에서 빠지고, 진행 중인 설치는 끊깁니다. 원본 파일은 그대로 둡니다.")
        }
        .confirmationDialog(
            "연결을 해제할까요?",
            isPresented: Binding(get: { projectToRemove != nil }, set: { if !$0 { projectToRemove = nil } }),
            presenting: projectToRemove
        ) { project in
            Button("연결 해제", role: .destructive) { projects?.remove(project) }
            Button("돌아가기", role: .cancel) {}
        } message: { project in
            Text("\(project.name): 목록에서 빠지고 Xcode 빌드를 더 가져오지 않습니다. 이미 게시된 빌드와 프로젝트 파일은 그대로 둡니다.")
        }
        .sheet(item: $buildToInspect) { build in
            BuildInfoSheet(build: build, project: projects?.owner(sourcePath: build.sourcePath, bundleId: build.descriptor.bundleId))
        }
        .sheet(isPresented: $showingAgentInstall) {
            if let projects {
                AgentInstallSheet(installer: AgentInstaller(serverPath: Bundle.main.executablePath ?? "", scriptPath: projects.agentScript.path))
            }
        }
        .sheet(isPresented: $showingLinkedProjects) {
            if let linkedProjects {
                NavigationStack {
                    LinkedProjectsView(projects: linkedProjects)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("닫기") { showingLinkedProjects = false }
                            }
                        }
                }
                .frame(minWidth: 560, minHeight: 420)
            }
        }
        .alert("에이전트 안내를 썼습니다", isPresented: Binding(get: { agentNotice != nil }, set: { if !$0 { agentNotice = nil } })) {
            Button("확인") {}
        } message: {
            Text(agentNotice ?? "")
        }
    }

    /// 보여 줄 앱·프로젝트·거부·대기·감시 폴더 문제가 하나도 없다.
    static func showsEmptyState(model: HostModel, pendingCount: Int, projectCount: Int = 0) -> Bool {
        model.builds.isEmpty && model.rejected.isEmpty && pendingCount == 0 && model.watchProblem == nil && projectCount == 0
    }

    private var header: some View {
        SetupChecklistCard(showImporter: showImporter, addProject: { choosingProject = true })
            .padding(.top, 12)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("앱 없음", systemImage: "app.dashed")
        } description: {
            Text(HostEdition.isSandboxed
                 ? "프로젝트 폴더를 등록하면 Xcode에서 iPhone용으로 한 최근 Debug 빌드를 게시합니다."
                 : "Xcode 프로젝트를 추가하거나 창으로 끌어 놓으면 Debug 기기용으로 빌드해 게시합니다.")
        } actions: {
            Button("프로젝트 추가…") { choosingProject = true }
                .buttonStyle(.borderedProminent)
            Button("빌드 가져오기…", action: showImporter)
        }
        .safeAreaInset(edge: .bottom) {
            if model.watchedFolder != nil {
                WatchedFolderRow(chooseFolder: { choosingFolder = true }).padding()
            }
        }
    }

    private var list: some View {
        let entries = self.entries
        return List {
            Group {
                Section {
                    VStack(spacing: 0) { header }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if let projects, !projects.suggestions.isEmpty {
                    Section("Xcode에서 기기용 Debug 빌드를 시작한 프로젝트") {
                        ForEach(projects.suggestions) { suggestion in
                            SuggestionRow(projects: projects, suggestion: suggestion)
                        }
                    }
                }
                if model.watchedFolder != nil || model.watchProblem != nil {
                    Section("감시 폴더") {
                        WatchedFolderRow(chooseFolder: { choosingFolder = true })
                    }
                }
                if !importQueue.pending.isEmpty {
                    Section("Debug 구성 확인 대기 \(importQueue.pending.count)개") {
                        ForEach(importQueue.pending) { item in
                            PendingImportRow(item: item)
                        }
                    }
                }
                Section {
                    if entries.isEmpty {
                        HStack {
                            Text("게시할 앱이 없습니다.").foregroundStyle(.secondary)
                            Spacer()
                            Button("프로젝트 추가…") { choosingProject = true }
                        }
                    }
                    ForEach(entries) { entry in
                        AppRow(
                            entry: entry,
                            projects: projects,
                            expanded: entry.group.map { expandedApps.contains($0.bundleId) } ?? false,
                            toggleOlder: { if let id = entry.group?.bundleId { expandedApps.formSymmetricDifference([id]) } },
                            unpublish: { buildToUnpublish = $0 },
                            showInfo: { buildToInspect = $0 },
                            removeProject: { projectToRemove = $0 },
                            connectAgents: connectAgents)
                    }
                } header: {
                    Text("앱 \(entries.count)개")
                }
                if !model.rejected.isEmpty {
                    Section {
                        ForEach(model.rejected) { item in
                            RejectedBuildRow(item: item)
                        }
                    } header: {
                        HStack {
                            Text("거부된 빌드 \(model.rejected.count)개")
                            Spacer()
                            Button("목록 지우기") { Task { await model.clearRejected() } }
                                .buttonStyle(.link)
                                .font(.callout)
                        }
                    }
                }
            }
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .animation(reduceMotion ? nil : .snappy, value: entries.map(\.id))
        .animation(reduceMotion ? nil : .snappy, value: expandedApps)
    }

    private func connectAgents(_ project: ConnectedProject) {
        guard let written = projects?.connectAgents(for: project), !written.isEmpty else { return }
        let paths = written.map(\.path).joined(separator: "\n")
        agentNotice = String(localized: "\(paths)\n\n이 프로젝트에서 Claude나 Codex가 RemoteDebug로 빌드·게시할 수 있습니다.")
    }
}

/// Xcode에서 기기용 Debug 빌드를 시작한, 아직 연결하지 않은 프로젝트.
private struct SuggestionRow: View {
    let projects: ProjectsModel
    let suggestion: ProjectsModel.Suggestion

    var body: some View {
        HStack(spacing: 14) {
            AppTile(name: suggestion.name, seed: suggestion.container, symbol: "sparkles")
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.name).font(.title3.weight(.semibold))
                Text(suggestion.container).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("등록") { Task { await projects.register(suggestion) } }
                .buttonStyle(.borderedProminent)
                .help("이 프로젝트를 연결하고 Xcode에서 빌드할 때마다 게시합니다")
            Button("등록하지 않음") { projects.dismiss(suggestion) }
        }
        .rdCard()
    }
}

struct RejectedBuildRow: View {
    let item: RejectedBuild

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(.title2)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.fileName).font(.headline)
                    if let bundleId = item.bundleId {
                        Text(bundleId)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(item.messages, id: \.self) { message in
                    Text(message).font(.callout)
                }
                Text(item.rejectedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .rdCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(item))
    }

    static func accessibilityText(_ item: RejectedBuild) -> String {
        String(localized: "거부됨: \(item.fileName). \(item.messages.joined(separator: " "))")
    }
}

/// 감시 중인 폴더. 폴더를 찾거나 읽을 수 없으면 그 사실과 다시 고르기를 보여 준다.
private struct WatchedFolderRow: View {
    @Environment(HostModel.self) private var model
    let chooseFolder: () -> Void

    var body: some View {
        if let problem = model.watchProblem {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !problem.path.isEmpty {
                        Text(problem.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(problem.path)
                    }
                }
                Spacer()
                if model.watchedFolder != nil {
                    Button("다시 확인") { Task { await model.rescan() } }
                }
                Button("폴더 다시 고르기", action: chooseFolder)
                    .buttonStyle(.borderedProminent)
                Button("감시 중지") { Task { await model.forgetFolder() } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("감시 폴더 문제")
        } else if let folder = model.watchedFolder {
            HStack {
                Label(folder.path, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                Spacer()
                Button("다시 확인") { Task { await model.rescan() } }
                Button("감시 중지") { Task { await model.forgetFolder() } }
            }
        }
    }
}

/// 구성을 확인하지 못해 사용자 답을 기다리는 빌드. 대화상자와 같은 답을 여기서도 할 수 있다(항목 id로 답한다).
private struct PendingImportRow: View {
    @Environment(HostModel.self) private var model
    @Environment(ImportQueue.self) private var importQueue
    let item: ImportQueue.Pending

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Label(ImportConfirmation.title(item), systemImage: "questionmark.app")
                Text(item.url.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("가져오지 않기") { importQueue.skip(item.id) }
            Button("Debug 빌드로 가져오기") {
                importQueue.confirm(item.id) { [model] url, mode in await model.importBuild(url, mode: mode) }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
