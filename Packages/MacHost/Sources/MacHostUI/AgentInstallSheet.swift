import MacHostKit
import SwiftUI

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
