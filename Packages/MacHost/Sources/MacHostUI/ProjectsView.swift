import AppKit
import MacHostKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectsView: View {
    @Environment(\.connectProjects) private var connectProjects
    let projects: ProjectsModel

    @State private var choosing = false
    @State private var projectToRemove: ConnectedProject?
    @State private var agentNotice: String?
    @State private var showingAgentInstall = false

    var body: some View {
        Group {
            if projects.projects.isEmpty && projects.suggestions.isEmpty {
                ContentUnavailableView {
                    Label("연결한 프로젝트 없음", systemImage: "hammer")
                } description: {
                    Text("프로젝트 폴더나 .xcodeproj, .xcworkspace를 창으로 끌어 놓으세요. Debug 기기용으로 빌드해 게시합니다.")
                } actions: {
                    Button("프로젝트 추가…") { choosing = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
        .navigationTitle("프로젝트")
        .toolbar {
            Button { showingAgentInstall = true } label: {
                Label("에이전트에 설치…", systemImage: "puzzlepiece.extension").labelStyle(.titleAndIcon)
            }
            .help("Claude Code와 Codex에 RemoteDebug MCP 서버와 스킬을 설치합니다")
            Button { choosing = true } label: {
                Label("프로젝트 추가…", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .help("프로젝트 폴더나 Xcode 프로젝트 파일을 고릅니다")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if projects.scanStalled {
                    Label("Xcode 빌드 폴더(\(projects.derivedDataPath))를 읽지 못하고 있습니다. Xcode에서 한 빌드를 가져오지 못하고 등록 제안도 나오지 않습니다. 디스크 연결과 시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더의 RemoteDebug 항목을 확인하세요.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.bar)
                }
                if let message = projects.lastError {
                    ErrorBanner(message: message) { projects.lastError = nil }
                }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .package, .item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            connectProjects(urls)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let found = ProjectConnector.projectURLs(in: urls)
            guard !found.isEmpty else { return false }
            connectProjects(found)
            return true
        }
        .confirmationDialog(
            "연결을 해제할까요?",
            isPresented: Binding(get: { projectToRemove != nil }, set: { if !$0 { projectToRemove = nil } }),
            presenting: projectToRemove
        ) { project in
            Button("연결 해제", role: .destructive) { projects.remove(project) }
            Button("돌아가기", role: .cancel) {}
        } message: { project in
            Text("\(project.name): 목록에서 빠지고 Xcode 빌드를 더 가져오지 않습니다. 이미 게시된 빌드와 프로젝트 파일은 그대로 둡니다.")
        }
        .sheet(isPresented: $showingAgentInstall) {
            AgentInstallSheet(installer: AgentInstaller(serverPath: Bundle.main.executablePath ?? "", scriptPath: projects.agentScript.path))
        }
        .alert("에이전트 안내를 썼습니다", isPresented: Binding(get: { agentNotice != nil }, set: { if !$0 { agentNotice = nil } })) {
            Button("확인") {}
        } message: {
            Text(agentNotice ?? "")
        }
    }

    private var list: some View {
        List {
            if !projects.suggestions.isEmpty {
                Section("Xcode에서 기기용 Debug 빌드를 시작한 프로젝트") {
                    ForEach(projects.suggestions) { suggestion in
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
            }
            Section("연결한 프로젝트 \(projects.projects.count)개") {
                ForEach(projects.projects) { project in
                    ProjectRow(projects: projects, project: project,
                               connectAgents: { connectAgents(project) },
                               remove: { projectToRemove = project })
                }
            }
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
    }

    private func connectAgents(_ project: ConnectedProject) {
        let written = projects.connectAgents(for: project)
        guard !written.isEmpty else { return }
        agentNotice = written.map(\.path).joined(separator: "\n")
            + "\n\n이 프로젝트에서 Claude나 Codex가 RemoteDebug로 빌드·게시할 수 있습니다."
    }
}

private struct ProjectRow: View {
    let projects: ProjectsModel
    let project: ConnectedProject
    let connectAgents: () -> Void
    let remove: () -> Void

    @State private var scheme = ""

    private var schemes: [String] { projects.schemes[project.id] ?? [] }
    private var phase: ProjectsModel.Phase? { projects.phases[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                AppTile(name: project.name, seed: project.container, symbol: "hammer.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.title3.weight(.semibold))
                    Text(project.container).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(project.container)
                }
                Spacer()
                if !schemes.isEmpty {
                    Picker("스킴", selection: $scheme) {
                        if scheme.isEmpty { Text("스킴 고르기").tag("") }
                        ForEach(schemes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .accessibilityLabel("\(project.name) 스킴")
                }
                Button {
                    Task { await projects.build(project, scheme: scheme) }
                } label: {
                    Label("빌드해서 게시", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(scheme.isEmpty || phase != nil)
                Menu {
                    Button("에이전트 연결…", action: connectAgents)
                    Button("스킴 다시 읽기") { Task { await reloadSchemes() } }
                    Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([project.containerURL]) }
                    Divider()
                    Button("연결 해제…", role: .destructive, action: remove)
                } label: {
                    Label("더 보기", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            status
        }
        .rdCard()
        .onChange(of: schemes) { pickScheme() }
        .task(id: project.id) {
            if schemes.isEmpty { await reloadSchemes() } else { pickScheme() }
        }
    }

    @ViewBuilder private var status: some View {
        if let phase {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(Self.text(for: phase)).font(.callout).foregroundStyle(.secondary)
            }
        } else if let report = projects.reports[project.id] {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(report.published, id: \.buildId) { item in
                    Chip(text: "\(item.name) \(item.version) (\(item.buildNumber)) 게시됨", symbol: "checkmark.circle.fill", color: .green)
                }
                if let message = report.message {
                    Label(message, systemImage: report.ok ? "info.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.ok ? Color.secondary : Color.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
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
                        .font(.callout)
                }
            }
        } else if schemes.isEmpty {
            Text("스킴을 읽지 못했습니다. 더 보기 메뉴에서 다시 읽으세요.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func reloadSchemes() async {
        await projects.loadSchemes(for: project)
        pickScheme()
    }

    private func pickScheme() {
        if scheme.isEmpty || !schemes.contains(scheme) {
            scheme = projects.preferredScheme(for: project) ?? ""
        }
    }

    static func text(for phase: ProjectsModel.Phase) -> String {
        switch phase {
        case .loadingSchemes: "스킴을 읽는 중"
        case .building(let scheme): "\(scheme) 스킴을 Debug 기기용으로 빌드하는 중"
        case .importing: "빌드를 검사하고 게시하는 중"
        }
    }
}

/// Claude Code와 Codex에 MCP 서버와 스킬을 설치·제거한다.
struct AgentInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let installer: AgentInstaller

    @State private var installed: [AgentInstaller.Target: Bool] = [:]
    @State private var outcomes: [AgentInstaller.Target: AgentInstaller.Outcome] = [:]
    @State private var working: AgentInstaller.Target?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("에이전트에 설치").font(.title2.bold())
            Text("설치하면 어느 프로젝트에서든 에이전트가 RemoteDebug로 빌드하고 게시할 수 있습니다. 사용자 전체 설정에 MCP 서버 remotedebug와 스킬 remotedebug를 더합니다.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AgentInstaller.Target.allCases) { target in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(target.title).font(.headline)
                        if installed[target] == true {
                            Label("설치됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                        }
                        Spacer()
                        if working == target { ProgressView().controlSize(.small) }
                        if installed[target] == true {
                            Button("제거") { run(target) { await installer.uninstall(target) } }
                        }
                        Button(installed[target] == true ? "다시 설치" : "설치") { run(target) { await installer.install(target) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(working != nil)
                    Text(installer.skillFile(target).path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let outcome = outcomes[target] {
                        Label(outcome.message, systemImage: outcome.ok ? "info.circle" : "exclamationmark.triangle.fill")
                            .foregroundStyle(outcome.ok ? Color.secondary : Color.red)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        for target in AgentInstaller.Target.allCases { installed[target] = installer.isInstalled(target) }
    }

    private func run(_ target: AgentInstaller.Target, _ action: @escaping () async -> AgentInstaller.Outcome) {
        working = target
        Task {
            outcomes[target] = await action()
            working = nil
            refresh()
        }
    }
}
