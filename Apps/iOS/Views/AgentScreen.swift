import PhoneClientKit
import RDModels
import SwiftUI

/// Mac의 에이전트(Claude Code, Codex)에 요청을 보내고 진행과 답을 본다.
struct AgentScreen: View {
    var state: PhoneViewState
    var actions: PhoneActions

    @State private var path: [String] = []
    @State private var draft = ""
    @State private var projectID = ""
    @State private var tool: AgentTool?
    @State private var continuing: AgentJob?
    @State private var isSending = false
    @State private var problem: String?
    @FocusState private var editing: Bool

    private var board: AgentBoard? { state.agentBoard }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if state.host == nil {
                    ContentUnavailableView {
                        Label("페어링한 Mac 없음", systemImage: "laptopcomputer.slash")
                    } description: {
                        Text("빌드 탭에서 Mac과 페어링하면 Mac의 에이전트에 요청을 보낼 수 있습니다.")
                    }
                } else if state.tunnel != .connected {
                    ContentUnavailableView {
                        Label("VPN 꺼짐", systemImage: "network.slash")
                    } description: {
                        Text("빌드 탭에서 RemoteDebug VPN을 켜면 요청을 보낼 수 있습니다.")
                    }
                } else if let board {
                    if board.enabled {
                        composer(board)
                    } else {
                        Section {
                            Label("Mac이 iPhone의 요청을 받지 않습니다", systemImage: "hand.raised")
                                .font(.headline)
                            Text("Mac RemoteDebug 앱의 에이전트 화면에서 \"페어링한 iPhone의 요청 받기\"를 켜세요.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !board.requests.isEmpty {
                        Section("요청") {
                            ForEach(board.requests) { job in
                                NavigationLink(value: job.id) { AgentJobRow(job: job) }
                            }
                        }
                    }
                } else if let message = state.agentError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                    }
                } else {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Mac에서 받는 중").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .tint(PhoneTheme.tint)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await actions.refreshAgent() }
            .navigationTitle("에이전트")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                AgentJobDetail(job: board?.requests.first { $0.id == id }, cancel: actions.cancelAgentRequest) { job in
                    continuing = job
                    path = []
                    editing = true
                }
            }
        }
        // 이 탭이 보이는 동안 Mac의 진행 상황을 받아 온다. 실행 중인 요청이 있으면 더 자주 받는다.
        .task(id: PollKey(reachable: state.tunnel == .connected && state.host != nil, busy: isBusy)) {
            let interval: Duration = isBusy ? .seconds(2) : .seconds(6)
            while !Task.isCancelled {
                await actions.refreshAgent()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private struct PollKey: Hashable {
        var reachable: Bool
        var busy: Bool
    }

    private var isBusy: Bool {
        state.agentBoard?.requests.contains { !$0.state.isFinished } ?? false
    }

    private func selectedProject(_ board: AgentBoard) -> String {
        board.projects.contains { $0.id == projectID } ? projectID : board.projects.first?.id ?? ""
    }

    private func selectedTool(_ board: AgentBoard) -> AgentTool? {
        tool.flatMap { board.agents.contains($0) ? $0 : nil } ?? board.agents.first
    }

    @ViewBuilder
    private func composer(_ board: AgentBoard) -> some View {
        Section {
            if let continuing {
                HStack {
                    Label("\(continuing.projectName) · \(continuing.agent.title): \(continuing.text)", systemImage: "arrowshape.turn.up.left")
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                    Button("새 요청으로") { self.continuing = nil }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                }
            } else if board.projects.isEmpty {
                Text("Mac RemoteDebug 앱의 프로젝트 화면에서 프로젝트를 연결하면 그 폴더에서 에이전트를 실행합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if board.agents.isEmpty {
                Text("Mac에서 claude, codex 명령을 찾지 못했습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("프로젝트", selection: Binding(get: { selectedProject(board) }, set: { projectID = $0 })) {
                    ForEach(board.projects) { Text($0.name).tag($0.id) }
                }
                if board.agents.count > 1 {
                    Picker("에이전트", selection: Binding(get: { selectedTool(board) ?? .claude }, set: { tool = $0 })) {
                        ForEach(board.agents) { Text($0.title).tag($0) }
                    }
                }
            }
            TextField("에이전트에 보낼 요청", text: $draft, axis: .vertical)
                .lineLimit(3...10)
                .focused($editing)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            Button {
                send(board)
            } label: {
                HStack {
                    Text("보내기")
                    if isSending { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend(board))
        } header: {
            Text(continuing == nil ? "새 요청" : "이어서 요청")
        }
    }

    private func canSend(_ board: AgentBoard) -> Bool {
        guard !isSending, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return continuing != nil || (!selectedProject(board).isEmpty && selectedTool(board) != nil)
    }

    private func send(_ board: AgentBoard) {
        let submission = AgentSubmission(text: draft, project: continuing?.project ?? selectedProject(board),
                                         agent: continuing?.agent ?? selectedTool(board), continues: continuing?.id ?? "")
        isSending = true
        Task {
            problem = await actions.sendAgentRequest(submission)
            isSending = false
            if problem == nil {
                draft = ""
                continuing = nil
                editing = false
            }
        }
    }
}

extension AgentJob.State {
    var label: String {
        switch self {
        case .queued: "대기 중"
        case .running: "실행 중"
        case .done: "완료"
        case .failed: "실패"
        case .cancelled: "멈춤"
        }
    }
}

private struct AgentStateMark: View {
    var state: AgentJob.State

    var body: some View {
        switch state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

private struct AgentJobRow: View {
    var job: AgentJob

    var body: some View {
        HStack(spacing: 12) {
            AgentStateMark(state: job.state)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.text).lineLimit(2)
                Text("\(job.projectName) · \(job.agent.title) · \(job.origin) · \(job.state.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// 요청 하나의 진행과 답.
private struct AgentJobDetail: View {
    var job: AgentJob?
    var cancel: @MainActor @Sendable (String) async -> Void
    var continueJob: (AgentJob) -> Void

    var body: some View {
        List {
            if let job {
                Section("요청") {
                    Text(job.text).textSelection(.enabled)
                    LabeledContent("상태") {
                        HStack(spacing: 6) {
                            AgentStateMark(state: job.state)
                            Text(job.state.label)
                        }
                    }
                    LabeledContent("프로젝트", value: job.projectName)
                    LabeledContent("에이전트", value: job.agent.title)
                    LabeledContent("보낸 곳", value: job.origin)
                    LabeledContent("보낸 시각", value: job.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if job.state.isFinished {
                    if !job.output.isEmpty {
                        Section(job.state == .done ? "답" : "결과") {
                            Text(job.output).textSelection(.enabled)
                            Button("답 복사") { UIPasteboard.general.string = job.output }
                        }
                    }
                    if job.canContinue {
                        Section {
                            Button("이어서 요청") { continueJob(job) }
                        }
                    }
                } else {
                    if !job.activity.isEmpty {
                        Section("진행") {
                            Text(job.activity)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                    Section {
                        Button("멈추기", role: .destructive) { Task { await cancel(job.id) } }
                    }
                }
            } else {
                ContentUnavailableView("Mac의 목록에서 지워진 요청입니다", systemImage: "trash")
            }
        }
        .listStyle(.insetGrouped)
        .tint(PhoneTheme.tint)
        .navigationTitle("요청")
        .navigationBarTitleDisplayMode(.inline)
    }
}
