import AppKit
import MacHostKit
import SwiftUI

/// 프로젝트의 피드백을 이슈로 올릴 GitHub 저장소를 정한다.
struct IssueTargetSheet: View {
    let project: ConnectedProject
    let projects: ProjectsModel
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var auto = false
    @State private var suggested: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(project.name): 이슈 저장소").font(.title2.weight(.semibold))
            Text("이 프로젝트의 앱에서 받은 피드백을 GitHub 이슈로 올릴 저장소입니다. 이슈에는 사용자가 쓴 글, 앱 버전, OS, 기기 종류, 확인 목록의 답만 올라가고 로그와 첨부 파일은 이 Mac에만 남습니다. 메일 주소, 웹 주소, 토큰, IP, 호스트 이름, 경로, 전화번호처럼 보이는 것은 가립니다. 공개 저장소의 이슈는 누구나 볼 수 있습니다. 이 Mac에 GitHub CLI(gh)가 설치되어 로그인돼 있어야 합니다.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(text: $repo, prompt: Text(verbatim: "owner/repo")) { Text("저장소") }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                if let suggested, suggested != repo.trimmingCharacters(in: .whitespaces) {
                    Button("git origin의 \(suggested) 쓰기") { repo = suggested }
                }
            }
            Toggle("자동 등록", isOn: $auto)
            Text("켜면 페어링한 iPhone이 Debug 빌드에서 바로 보낸 피드백을 받는 대로 올립니다(프로젝트마다 한 시간에 \(ProjectsModel.autoIssueLimit)개까지). 꺼 두면 크래시·피드백 화면의 \"이슈로 등록…\"에서 내용을 확인한 뒤 올립니다. 메일에 붙어 온 진단 파일에서 넣은 기록은 켜 두어도 저절로 올리지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if project.issueTarget != nil {
                    Button("저장소 지우기", role: .destructive) {
                        projects.setIssueTarget("", for: project)
                        dismiss()
                    }
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            repo = project.issueTarget ?? ""
            // 자동 등록은 여기서 켠 적이 있을 때만 켜진 것으로 보인다. 저장소만 정하면 꺼진 채다.
            auto = project.issueAuto == true
            suggested = await projects.suggestedIssueTarget(for: project)
            // 정한 것이 없으면 git origin을 권하는 값으로 채워 둔다. 저장해야 쓰인다.
            if repo.isEmpty, let suggested { repo = suggested }
        }
    }

    private func save() {
        switch projects.setIssueTarget(repo, for: project) {
        case .success(let updated):
            projects.setIssueAuto(auto, for: updated)
            dismiss()
        case .failure(let failure):
            error = failure.message
        }
    }
}

/// 이슈로 올리기 전에 제목과 본문을 보여 주고 고치게 한다. 등록을 눌러야 올라간다.
struct IssuePreviewSheet: View {
    let preview: ProjectsModel.IssuePreview
    let projects: ProjectsModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(preview.repo)에 이슈로 등록").font(.title2.weight(.semibold))
            Text("아래 제목과 본문이 그대로 올라갑니다. 공개 저장소면 누구나 볼 수 있으니 이름, 연락처, 주소 같은 개인 정보가 남아 있으면 지우세요. 로그와 첨부 파일은 올리지 않습니다.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("제목", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("본문")
            if preview.needsMessage {
                Label("이 기록의 원문에서는 사용자가 쓴 글과 로그를 나눌 수 없어 본문의 글 자리를 비워 두었습니다. 올릴 글을 본문 맨 위에 직접 적으세요.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("등록") { file() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear {
            title = preview.draft.title
            text = preview.draft.body
        }
    }

    private func file() {
        working = true
        error = nil
        Task {
            let result = await projects.fileIssue(preview.item.id, draft: FeedbackIssueDraft(title: title, body: text))
            working = false
            switch result {
            case .success: dismiss()
            case .failure(let failure): error = failure.message
            }
        }
    }
}
