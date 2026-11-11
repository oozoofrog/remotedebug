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
            Button { choosing = true } label: {
                Label("프로젝트 추가…", systemImage: "plus")
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
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.name)
                                Text(suggestion.container).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("등록") { Task { await projects.register(suggestion) } }
                                .buttonStyle(.borderedProminent)
                                .help("이 프로젝트를 연결하고 Xcode에서 빌드할 때마다 게시합니다")
                            Button("등록하지 않음") { projects.dismiss(suggestion) }
                        }
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
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.headline)
                    Text(project.container).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if !schemes.isEmpty {
                    Picker("스킴", selection: $scheme) {
                        if scheme.isEmpty { Text("스킴 고르기").tag("") }
                        ForEach(schemes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .accessibilityLabel("\(project.name) 스킴")
                }
                Button("빌드해서 게시") {
                    Task { await projects.build(project, scheme: scheme) }
                }
                .buttonStyle(.borderedProminent)
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
        .padding(.vertical, 4)
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
                    Label("\(item.name) \(item.version) (\(item.buildNumber)) 게시됨", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
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
