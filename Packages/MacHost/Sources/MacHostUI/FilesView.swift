import AppKit
import MacHostKit
import RDModels
import SwiftUI

/// 페어링한 iPhone으로 보낼 파일. 끌어 놓거나 골라서 넣는다.
struct FilesView: View {
    @Environment(HostModel.self) private var model
    @Environment(ProjectsModel.self) private var projects: ProjectsModel?
    /// 새로 넣는 파일·링크가 들어갈 구역. nil이면 공통이다.
    @State private var area: ResourceProject?
    @State private var choosing = false
    @State private var isTargeted = false
    @State private var fileToRemove: ResourceDescriptor?
    @State private var showsLinkSheet = false

    var body: some View {
        Group {
            if model.sharedFiles.isEmpty {
                ContentUnavailableView {
                    Label("보낸 파일 없음", systemImage: "doc.on.doc")
                } description: {
                    Text("파일이나 링크를 여기에 끌어 놓으면 페어링한 iPhone의 RemoteDebug 앱에서 받을 수 있습니다. 이름이 같은 파일을 다시 넣으면 바뀝니다. 연결한 프로젝트가 있으면 프로젝트별 구역으로 나눠 보낼 수 있습니다.")
                } actions: {
                    Button("파일 고르기…") { choosing = true }
                    Button("링크 보내기…") { showsLinkSheet = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .overlay {
            if isTargeted {
                RDTheme.cardShape
                    .strokeBorder(RDTheme.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("iPhone으로 보낸 파일")
        .toolbar {
            ToolbarItemGroup {
                if model.filesInProgress > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("파일 \(model.filesInProgress)개 보내는 중")
                }
                if choices.count > 1 {
                    Picker("넣을 구역", selection: $area) {
                        ForEach(choices, id: \.self) { choice in
                            Text(choice?.name ?? ResourceArea.commonTitle).tag(choice)
                        }
                    }
                    .help("새로 보내는 파일과 링크가 들어갈 구역")
                    .accessibilityLabel("넣을 구역")
                }
                Button { choosing = true } label: {
                    Label("파일 보내기…", systemImage: "square.and.arrow.up")
                }
                .help("iPhone으로 보낼 파일 고르기")
                Button { showsLinkSheet = true } label: {
                    Label("링크 보내기…", systemImage: "link.badge.plus")
                }
                .help("웹 주소나 앱 딥 링크를 iPhone으로 보내기")
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            share(urls)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            let links = urls.filter { !$0.isFileURL }
            guard !files.isEmpty || !links.isEmpty else { return false }
            if !files.isEmpty { share(files) }
            if !links.isEmpty { Task { for link in links { _ = await model.shareLink(link, project: area) } } }
            return true
        } isTargeted: { isTargeted = $0 }
        .sheet(isPresented: $showsLinkSheet) {
            LinkSheet { url, title in
                switch await model.shareLink(url, title: title, project: area) {
                case .success: return nil
                case .failure(let failure): return failure.message
                }
            }
        }
        .confirmationDialog(
            "파일을 지울까요?",
            isPresented: Binding(get: { fileToRemove != nil }, set: { if !$0 { fileToRemove = nil } }),
            presenting: fileToRemove
        ) { file in
            Button("지우기", role: .destructive) {
                Task { await model.unshareFile(file.id) }
            }
            Button("돌아가기", role: .cancel) {}
        } message: { file in
            Text(file.isLink ? "\(file.name): iPhone의 링크 목록에서 빠집니다." : "\(file.name): iPhone의 받을 파일 목록에서 빠집니다. iPhone에 이미 받은 사본과 Mac의 원본은 그대로 둡니다.")
        }
    }

    private var list: some View {
        List {
            if !model.isRunning {
                Label("공유가 꺼져 있어 iPhone이 받을 수 없습니다. 공유를 시작하면 이 목록을 다시 보냅니다.", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(ResourceDescriptor.areas(model.sharedFiles)) { section in
                Section(section.title) {
                    ForEach(section.resources) { file in
                        FileRow(file: file, destinations: choices.filter { $0?.id != file.project?.id }) { target in
                            Task { await model.moveSharedFile(file.id, to: target) }
                        } remove: { fileToRemove = file }
                    }
                }
            }
        }
    }

    /// 고를 수 있는 구역: 연결한 프로젝트, 항목이 남아 있는 구역(연결을 끊은 프로젝트), 공통.
    private var choices: [ResourceProject?] {
        Self.areaChoices(connected: projects?.projects ?? [], files: model.sharedFiles, current: area)
    }

    static func areaChoices(connected: [ConnectedProject], files: [ResourceDescriptor], current: ResourceProject? = nil) -> [ResourceProject?] {
        var seen = Set<String>()
        var list: [ResourceProject] = []
        for project in connected.map(\.resourceArea) + ResourceDescriptor.areas(files).compactMap(\.project) + (current.map { [$0] } ?? [])
        where seen.insert(project.id).inserted {
            list.append(project)
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } + [nil]
    }

    private func share(_ urls: [URL]) {
        Task {
            // 파일 고르기 창이 준 주소는 보안 범위 접근이 필요할 수 있다.
            let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (url, started) in scoped where started { url.stopAccessingSecurityScopedResource() } }
            await model.shareFiles(urls, project: area)
        }
    }
}

private struct FileRow: View {
    var file: ResourceDescriptor
    /// 옮길 수 있는 다른 구역. nil은 공통이다.
    var destinations: [ResourceProject?]
    var move: (ResourceProject?) -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if file.isLink {
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(RDTheme.tint)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (file.name as NSString).pathExtension) ?? .data))
                        .resizable()
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.link.map { "\($0) · \(file.publishedAt.formatted(date: .abbreviated, time: .shortened))" }
                     ?? "\(file.size.formatted(.byteCount(style: .file))) · \(file.publishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(role: .destructive, action: remove) {
                Label("지우기", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("목록에서 지우기")
            .accessibilityLabel("\(file.name) 지우기")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("SHA-256 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.sha256, forType: .string)
            }
            if !destinations.isEmpty {
                Menu("구역 옮기기") {
                    ForEach(destinations, id: \.self) { target in
                        Button(target?.name ?? ResourceArea.commonTitle) { move(target) }
                    }
                }
            }
            Button("지우기", role: .destructive, action: remove)
        }
    }
}

/// 링크 하나를 보내는 시트.
private struct LinkSheet: View {
    /// 실패하면 안내 문구를 돌려준다.
    var send: @MainActor (URL, String?) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var title = ""
    @State private var error: String?
    @State private var sending = false

    private var url: URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.isEmpty == false else { return nil }
        return url
    }

    var body: some View {
        Form {
            Section {
                TextField("주소", text: $address, prompt: Text("https://… 또는 앱스킴://…"))
                TextField("이름(선택)", text: $title, prompt: Text("비우면 주소에서 만듭니다"))
            } footer: {
                Text("웹 주소는 iPhone의 Safari로, 앱 딥 링크는 그 앱으로 열립니다. 같은 주소를 다시 보내면 이름만 바뀝니다.")
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("취소") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("보내기") {
                    guard let url else { return }
                    sending = true
                    Task {
                        error = await send(url, title.isEmpty ? nil : title)
                        sending = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(url == nil || sending)
            }
        }
    }
}
