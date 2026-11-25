import AppKit
import MacHostKit
import RDModels
import SwiftUI
import UniformTypeIdentifiers

/// iPhone이 보낸 크래시 기록과 피드백: 목록과 원문.
struct CrashLogsView: View {
    @Environment(HostModel.self) private var model
    @Environment(ProjectsModel.self) private var projects: ProjectsModel?
    @State private var issuePreview: ProjectsModel.IssuePreview?
    @State private var issueNotice: String?
    @State private var selection: String?
    @State private var search = ""
    @State private var migrationNotice: String?

    private var store: CrashLogStore { model.crashLogs }

    private var shown: [CrashLogStore.Item] {
        guard !search.isEmpty else { return store.items }
        return store.items.filter { "\($0.bundleId) \($0.name) \($0.deviceName)".localizedCaseInsensitiveContains(search) }
    }

    private var selected: CrashLogStore.Item? {
        shown.first { $0.id == selection } ?? shown.first
    }

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("받은 크래시·피드백 없음", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("RemoteDebug iPhone 앱이 비정상 종료되면 다시 열 때 기록을 보냅니다. 다른 앱의 기록은 iPhone 설정 > 개인정보 보호 및 보안 > 분석 및 향상 > 분석 데이터에서 열고, 공유 버튼으로 RemoteDebug에 넘기면 여기로 들어옵니다. 앱 화면의 더 보기 메뉴 > \"크래시·피드백 보내기 추가\"대로 패키지를 넣은 앱은 자기 크래시와 피드백을 직접 보냅니다.")
                }
            } else {
                HSplitView {
                    List(shown, selection: Binding(get: { selected?.id }, set: { selection = $0 })) { item in
                        CrashRow(item: item, issueError: projects?.issueErrors[item.id]).tag(item.id)
                    }
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    if let selected {
                        CrashText(text: store.text(selected), image: store.imageURL(selected),
                                  attachments: (selected.attachments ?? []).compactMap { one in
                                      store.attachmentURL(one).map { CrashText.Attachment(name: one.name, bytes: one.bytes, url: $0) }
                                  })
                            .id(selected.id)
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView.search(text: search)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("크래시·피드백")
        // 처리한 지 오래된 기록은 목록을 보일 때도 지운다(앱을 오래 켜 두는 경우).
        .task { store.purgeHandled() }
        .onChange(of: model.diagnosticsOpenedRecordID, initial: true) { _, id in
            if let id {
                search = ""
                selection = id
                model.diagnosticsOpenedRecordID = nil
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "앱·기기 검색")
        .dropDestination(for: URL.self) { urls, _ in
            let diagnostics = urls.filter(DiagnosticsFile.matches)
            guard !diagnostics.isEmpty else { return false }
            Task { await model.openDiagnostics(diagnostics) }
            return true
        }
        .alert("기존 진단 키 이전", isPresented: Binding(get: { migrationNotice != nil }, set: { if !$0 { migrationNotice = nil } })) {
            Button("확인") { migrationNotice = nil }
        } message: {
            Text(migrationNotice ?? "")
        }
        .alert("이슈로 등록", isPresented: Binding(get: { issueNotice != nil }, set: { if !$0 { issueNotice = nil } })) {
            Button("확인") { issueNotice = nil }
        } message: {
            Text(issueNotice ?? "")
        }
        .sheet(item: $issuePreview) { preview in
            if let projects { IssuePreviewSheet(preview: preview, projects: projects) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(exportedAs: DiagnosticsFile.typeIdentifier)]
                    panel.allowsMultipleSelection = true
                    panel.message = String(localized: "피드백 메일에 붙어 온 암호화된 진단 파일(.afdiag)을 고르세요.")
                    if panel.runModal() == .OK { Task { await model.openDiagnostics(panel.urls) } }
                } label: {
                    Label("암호화된 진단 열기…", systemImage: "lock.open")
                }
                .help("피드백 메일에 붙어 온 암호화된 진단 파일을 이 Mac의 키로 풀어 목록에 넣는다")
                Button {
                    Task {
                        switch await model.migrateFeedbackKeys() {
                        case .success(let count):
                            migrationNotice = String(localized: "기존 진단 키 \(count)개를 이전했습니다.")
                        case .failure(let failure):
                            migrationNotice = failure.message
                        }
                    }
                } label: {
                    Label("기존 진단 키 이전", systemImage: "key.horizontal")
                }
                .help("이전 버전에서 만든 키를 복사합니다. macOS가 키마다 접근 허용을 요청할 수 있습니다.")
                .disabled(model.isMigratingFeedbackKeys)
                Button {
                    guard let selected, let text = store.text(selected) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("원문 복사", systemImage: "doc.on.doc")
                }
                .disabled(selected == nil)
                .help("선택한 기록의 원문을 복사")
                if let url = selected.flatMap(store.fileURL) {
                    ShareLink(item: url) { Label("공유", systemImage: "square.and.arrow.up") }
                        .help("선택한 기록 파일을 공유")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Finder에서 보기", systemImage: "folder")
                    }
                }
                Button {
                    guard let selected, let projects else { return }
                    // 올리기 전에 제목과 본문을 보여 준다. 올릴 수 없으면 까닭을 알린다.
                    switch projects.issuePreview(for: selected.id) {
                    case .success(let preview): issuePreview = preview
                    case .failure(let failure): issueNotice = failure.message
                    }
                } label: {
                    Label("이슈로 등록…", systemImage: "exclamationmark.bubble")
                }
                .disabled(selected?.kind != .feedback || selected?.issueURL != nil || projects == nil)
                .help("이 피드백의 글과 앱·기기 정보를 GitHub 이슈로 올린다. 올리기 전에 제목과 본문을 보여 주고, 로그와 첨부는 올리지 않는다")
                Button {
                    if let selected { store.setHandled(selected.id, selected.handledAt == nil) }
                } label: {
                    if selected?.handledAt == nil {
                        Label("처리함으로 표시", systemImage: "checkmark.circle")
                    } else {
                        Label("처리함 표시 지우기", systemImage: "checkmark.circle.fill")
                    }
                }
                .disabled(selected == nil)
                .help("문의를 처리한 날을 적어 둔다. 그날부터 \(CrashLogStore.handledRetentionDays)일 뒤에 이 기록과 첨부를 지운다")
                Button(role: .destructive) {
                    if let selected { store.remove(selected.id) }
                } label: {
                    Label("이 기록 지우기", systemImage: "trash")
                }
                .disabled(selected == nil)
                .help("이 Mac에 저장된 이 기록을 지운다")
            }
        }
    }
}

private struct CrashRow: View {
    let item: CrashLogStore.Item
    /// 이슈로 올리다 실패한 까닭. 없으면 `nil`.
    var issueError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: item.kind == .feedback ? "text.bubble" : "exclamationmark.triangle")
                    .foregroundStyle(item.kind == .feedback ? Color.accentColor : Color.orange)
                Text(item.title).font(.headline).lineLimit(1)
            }
            Text(item.crashedAt.formatted(date: .abbreviated, time: .standard))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(item.kind.label) · \(item.appVersion) · \(item.deviceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let deletes = item.deletesAt {
                Label("처리함 · \(deletes.formatted(date: .abbreviated, time: .omitted)) 뒤 지움", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let address = item.issueURL, let url = URL(string: address) {
                Link(destination: url) {
                    if let number = item.issueNumber {
                        Label("이슈 #\(number)", systemImage: "arrow.up.right.square")
                    } else {
                        Label("이슈 열기", systemImage: "arrow.up.right.square")
                    }
                }
                .font(.caption)
            } else if let issueError {
                Label("이슈 등록 실패: \(issueError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

private struct CrashText: View {
    let text: String?
    var image: URL?
    var attachments: [Attachment] = []

    struct Attachment: Identifiable {
        var name: String
        var bytes: Int
        var url: URL
        var id: URL { url }
        var isPicture: Bool { ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) }
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 12) {
                if let image {
                    ReceivedPictureView(url: image, maxHeight: 420, label: Text("피드백에 붙은 사진"))
                }
                if !attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("첨부 \(attachments.count)개").font(.headline)
                        ForEach(attachments) { attachment in
                            // 받은 파일은 앱에서 열지 않는다. 사진만 미리 보이고 나머지는 Finder에서 고른다.
                            if attachment.isPicture {
                                ReceivedPictureView(url: attachment.url, maxHeight: 320, label: Text(verbatim: attachment.name))
                            }
                            HStack(spacing: 8) {
                                Image(systemName: attachment.isPicture ? "photo" : "doc")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(attachment.name).lineLimit(1).truncationMode(.middle)
                                Text(Int64(attachment.bytes).formatted(.byteCount(style: .file)))
                                    .foregroundStyle(.secondary)
                                Button("Finder에서 보기") {
                                    NSWorkspace.shared.activateFileViewerSelecting([attachment.url])
                                }
                                .accessibilityLabel("\(attachment.name) Finder에서 보기")
                            }
                            .font(.callout)
                        }
                    }
                }
                Text(text ?? String(localized: "기록 파일을 읽을 수 없습니다."))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(12)
        }
    }
}

/// 기기가 보낸 사진 하나. 파일의 앞머리가 JPEG나 PNG일 때만, 메인 스레드 밖에서 줄인 그림으로 풀어 보인다
/// (`ReceivedPicture`). 그 밖의 파일은 풀지 않고 자리만 보인다.
private struct ReceivedPictureView: View {
    let url: URL
    let maxHeight: CGFloat
    let label: Text
    @State private var picture: ReceivedPicture.Thumbnail?
    @State private var loaded = false

    var body: some View {
        Group {
            if let picture {
                Image(decorative: picture.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .accessibilityLabel(label)
            } else if loaded {
                Label("미리 볼 수 없는 사진입니다(JPEG나 PNG가 아니거나 읽을 수 없습니다).", systemImage: "photo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            let url = url
            picture = await Task.detached(priority: .userInitiated) { ReceivedPicture.thumbnail(at: url) }.value
            loaded = true
        }
    }
}
