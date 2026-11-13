import AppKit
import MacHostKit
import RDModels
import SwiftUI

/// Mac과 iPhone에서 보낸 에이전트 요청: 보내기, 진행, 결과.
struct AgentView: View {
    @Environment(AgentDesk.self) private var desk: AgentDesk?

    var body: some View {
        if let desk {
            AgentDeskView(desk: desk)
        } else {
            ContentUnavailableView("에이전트를 쓸 수 없습니다", systemImage: "terminal")
        }
    }
}

private struct AgentDeskView: View {
    @Bindable var desk: AgentDesk
    @Environment(HostModel.self) private var model
    @State private var draft = ""
    @State private var projectID = ""
    @State private var tool: AgentTool?
    @State private var continuing: AgentJob?
    @State private var problem: String?
    @State private var confirmsFullAccess = false

    var body: some View {
        List {
            Section("iPhone 요청") { settings }
            Section(continuing == nil ? "새 요청" : "이어서 요청") { composer }
            if !desk.jobs.isEmpty {
                Section("요청") {
                    ForEach(desk.jobs) { job in
                        AgentJobRow(job: job, cancel: { desk.cancel(job.id) }, remove: { desk.remove(job.id) }) {
                            continuing = job
                        }
                    }
                }
            }
        }
        .navigationTitle("에이전트")
        .toolbar {
            ToolbarItem {
                Button("끝난 요청 지우기") { desk.clearFinished() }
                    .disabled(!desk.jobs.contains { $0.state.isFinished })
            }
        }
        .task { await desk.refreshTools() }
        .confirmationDialog("모든 권한으로 실행할까요?", isPresented: $confirmsFullAccess) {
            Button("모든 권한 허용", role: .destructive) { desk.access = .full }
            Button("돌아가기", role: .cancel) {}
        } message: {
            Text(AgentAccess.full.detail)
        }
    }

    @ViewBuilder private var settings: some View {
        Toggle("페어링한 iPhone의 요청 받기", isOn: $desk.acceptsRemote)
        if desk.acceptsRemote, !model.isRunning {
            Label("공유가 꺼져 있어 iPhone의 요청이 도착하지 않습니다.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        }
        Picker("에이전트 권한", selection: Binding(get: { desk.access }, set: { new in
            if new == .full { confirmsFullAccess = true } else { desk.access = new }
        })) {
            ForEach(AgentAccess.allCases) { Text($0.title).tag($0) }
        }
        Text(desk.access.detail)
            .font(.callout)
            .foregroundStyle(desk.access == .full ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        if desk.toolsChecked, desk.tools.isEmpty {
            HStack {
                Label("claude, codex 명령을 찾지 못했습니다. 터미널에서 실행되는지 확인하세요.", systemImage: "exclamationmark.triangle")
                Spacer()
                Button("다시 확인") { Task { await desk.refreshTools() } }
            }
        }
    }

    private var selectedProject: String {
        desk.projects.contains { $0.id == projectID } ? projectID : desk.projects.first?.id ?? ""
    }

    private var selectedTool: AgentTool? {
        tool.flatMap { desk.tools.contains($0) ? $0 : nil } ?? desk.tools.first
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (continuing != nil || (!selectedProject.isEmpty && selectedTool != nil))
    }

    @ViewBuilder private var composer: some View {
        if let continuing {
            HStack {
                Label("\(continuing.projectName) · \(continuing.agent.title): \(continuing.text)", systemImage: "arrowshape.turn.up.left")
                    .lineLimit(1)
                Spacer()
                Button("새 요청으로") { self.continuing = nil }
            }
        } else if desk.projects.isEmpty {
            Label("프로젝트 화면에서 프로젝트를 연결하면 그 폴더에서 에이전트를 실행합니다.", systemImage: "hammer")
                .foregroundStyle(.secondary)
        } else {
            Picker("프로젝트", selection: Binding(get: { selectedProject }, set: { projectID = $0 })) {
                ForEach(desk.projects) { Text($0.name).tag($0.id) }
            }
            if desk.tools.count > 1 {
                Picker("에이전트", selection: Binding(get: { selectedTool ?? .claude }, set: { tool = $0 })) {
                    ForEach(desk.tools) { Text($0.title).tag($0) }
                }
            }
        }
        TextEditor(text: $draft)
            .font(.body)
            .frame(minHeight: 70, maxHeight: 160)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("에이전트에 보낼 요청")
        HStack {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Spacer()
            Button("보내기") { send() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
        }
    }

    private func send() {
        let result = desk.submit(text: draft, project: selectedProject, agent: selectedTool, continues: continuing?.id ?? "")
        switch result {
        case .success:
            draft = ""
            problem = nil
            continuing = nil
        case .failure(let failure):
            problem = failure.message
        }
    }
}

private struct AgentJobRow: View {
    let job: AgentJob
    let cancel: () -> Void
    let remove: () -> Void
    let continueJob: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(job.text).textSelection(.enabled)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    if !job.state.isFinished { Button("멈추기", action: cancel) }
                    if job.canContinue { Button("이어서 요청", action: continueJob) }
                    if !job.output.isEmpty {
                        Button("답 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(job.output, forType: .string)
                        }
                    }
                    Spacer()
                    Button("지우기", role: .destructive, action: remove)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                stateMark
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.text).lineLimit(1)
                    Text("\(job.projectName) · \(job.agent.title) · \(job.origin) · \(job.createdAt.formatted(date: .omitted, time: .shortened)) · \(Self.stateText(job.state))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .onChange(of: job.state, initial: true) { _, state in
            if state == .running { expanded = true }
        }
    }

    /// 끝났으면 답, 실행 중이면 진행 내용.
    private var detail: String {
        job.state.isFinished ? job.output : job.activity
    }

    @ViewBuilder private var stateMark: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    static func stateText(_ state: AgentJob.State) -> String {
        switch state {
        case .queued: "대기 중"
        case .running: "실행 중"
        case .done: "완료"
        case .failed: "실패"
        case .cancelled: "멈춤"
        }
    }
}
