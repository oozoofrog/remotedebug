import PhoneClientKit
import RDModels
import SwiftUI
import UniformTypeIdentifiers

/// 파일 하나: Mac 목록의 항목과 이 iPhone에 받아 둔 사본을 묶는다.
struct FileItem: Identifiable {
    /// Mac 목록의 항목. 이 iPhone에만 있는 파일이면 nil.
    var resource: ResourceDescriptor?
    /// 받아 둔 사본(이름이 같은 파일).
    var received: ReceivedFile?
    var download: FileDownloadState?
    var progress: FileTransferProgress?

    var id: String { resource?.id ?? "local:" + name }
    var name: String { resource?.name ?? received?.name ?? "" }
    var size: Int64 { resource?.size ?? received?.size ?? 0 }
    var type: UTType? { UTType(filenameExtension: (name as NSString).pathExtension) }
    var isDownloading: Bool { download == .downloading }

    /// 받아 둔 사본이 Mac 목록과 같은 내용인지.
    var isCurrent: Bool {
        guard let resource, let received else { return received != nil }
        return received.size == resource.size && received.sha256 == resource.sha256.lowercased()
    }

    enum Route: Hashable {
        case file(String)
        case link(String)
    }
}

extension PhoneViewState {
    var fileItems: [FileItem] {
        var items = resources.filter { !$0.isLink }.map { r in
            FileItem(resource: r, received: receivedFiles.first { $0.name == r.name },
                     download: fileDownloads[r.id], progress: fileProgress[r.id])
        }
        let names = Set(resources.filter { !$0.isLink }.map(\.name))
        items += receivedFiles.filter { !names.contains($0.name) }.map { FileItem(received: $0) }
        return items
    }
}

/// Mac에서 받은 파일 영역.
struct FilesScreen: View {
    var state: PhoneViewState
    var actions: PhoneActions
    @Environment(\.openURL) private var openURL

    private var items: [FileItem] { state.fileItems }

    var body: some View {
        NavigationStack {
            List {
                if state.host == nil {
                    ContentUnavailableView {
                        Label("페어링한 Mac 없음", systemImage: "laptopcomputer.slash")
                    } description: {
                        Text("빌드 탭에서 Mac과 페어링하면 Mac이 보낸 파일을 받을 수 있습니다.")
                    }
                } else {
                    let downloading = items.filter(\.isDownloading)
                    if !downloading.isEmpty {
                        Section("받는 중") {
                            ForEach(downloading) { item in
                                NavigationLink(value: FileItem.Route.file(item.id)) { FileListRow(item: item) }
                            }
                        }
                    }
                    let areas = ResourceDescriptor.areas(state.resources)
                    if areas.contains(where: { $0.project != nil }) {
                        // 프로젝트 구역이 있으면 구역마다 한 칸(링크 먼저, 그다음 파일). 받는 중인 파일은 위 칸에 있다.
                        let sections = areas.compactMap { area -> AreaRows? in
                            let ids = Set(area.resources.map(\.id))
                            let rows = AreaRows(area: area, links: area.resources.filter(\.isLink),
                                                files: items.filter { !$0.isDownloading && ids.contains($0.resource?.id ?? "") })
                            return rows.links.isEmpty && rows.files.isEmpty ? nil : rows
                        }
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.links) { linkRow($0) }
                                ForEach(section.files) { fileRow($0) }
                            } header: {
                                Text(section.area.title)
                            } footer: {
                                if state.tunnel != .connected, section.id == sections.last?.id {
                                    Text("받으려면 RemoteDebug VPN을 켜야 합니다.")
                                }
                            }
                        }
                    } else {
                        let links = state.resources.filter(\.isLink)
                        if !links.isEmpty {
                            Section("링크") {
                                ForEach(links) { linkRow($0) }
                            }
                        }
                        let fromMac = items.filter { $0.resource != nil && !$0.isDownloading }
                        Section {
                            if fromMac.isEmpty && downloading.isEmpty {
                                Text("Mac 앱의 보낸 파일 화면에 파일을 끌어 놓으면 여기에 나타납니다.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(fromMac) { fileRow($0) }
                        } header: {
                            Text("Mac에서 보낸 파일")
                        } footer: {
                            if state.tunnel != .connected {
                                Text("받으려면 RemoteDebug VPN을 켜야 합니다.")
                            }
                        }
                    }
                }
                let local = items.filter { $0.resource == nil }
                if !local.isEmpty {
                    Section {
                        ForEach(local) { item in
                            NavigationLink(value: FileItem.Route.file(item.id)) { FileListRow(item: item) }
                                .swipeActions {
                                    Button("지우기", role: .destructive) { actions.deleteReceivedFile(item.name) }
                                }
                        }
                    } header: {
                        Text("이 iPhone에만 있는 파일")
                    } footer: {
                        Text("Mac 목록에서 빠졌거나 파일 앱에서 넣은 파일입니다.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                if state.host != nil { await actions.refresh() }
            }
            .navigationTitle("파일")
            .toolbar {
                if let url = FilesAppLink.documents {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("파일 앱에서 보기", systemImage: "folder")
                        }
                    }
                }
            }
            .navigationDestination(for: FileItem.Route.self) { route in
                switch route {
                case .file(let id):
                    if let item = items.first(where: { $0.id == id }) {
                        FileDetailView(item: item, actions: actions, tunnelConnected: state.tunnel == .connected)
                    } else {
                        ContentUnavailableView("파일이 목록에서 빠졌습니다", systemImage: "doc.questionmark")
                    }
                case .link(let id):
                    if let link = state.resources.first(where: { $0.id == id }) {
                        LinkDetailView(resource: link)
                    } else {
                        ContentUnavailableView("링크가 목록에서 빠졌습니다", systemImage: "link")
                    }
                }
            }
        }
    }
}

/// 구역 한 칸에 보일 줄.
private struct AreaRows: Identifiable {
    var area: ResourceArea
    var links: [ResourceDescriptor]
    var files: [FileItem]
    var id: String { area.id }
}

extension FilesScreen {
    private func linkRow(_ link: ResourceDescriptor) -> some View {
        NavigationLink(value: FileItem.Route.link(link.id)) { LinkRow(resource: link) }
            .swipeActions {
                if let url = link.link.flatMap(URL.init(string:)) {
                    Button("열기") { openURL(url) }.tint(PhoneTheme.tint)
                }
            }
    }

    private func fileRow(_ item: FileItem) -> some View {
        NavigationLink(value: FileItem.Route.file(item.id)) { FileListRow(item: item) }
            .swipeActions {
                if item.received == nil {
                    Button("받기") { if let r = item.resource { actions.downloadFile(r) } }
                        .tint(PhoneTheme.tint)
                }
            }
    }
}

private struct LinkRow: View {
    var resource: ResourceDescriptor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: LinkDetailView.isWeb(resource.link) ? "safari" : "arrow.up.forward.app")
                .font(.system(size: 19))
                .foregroundStyle(PhoneTheme.tint)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(resource.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(resource.link ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FileListRow: View {
    var item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            FileTypeIcon(type: item.type)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let progress = item.progress, item.isDownloading {
                    ProgressView(value: progress.fraction)
                        .tint(PhoneTheme.tint)
                    Text("\(Int(progress.fraction * 100))% · \(progress.received.formatted(.byteCount(style: .file))) / \(progress.total.formatted(.byteCount(style: .file)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(item.size.formatted(.byteCount(style: .file))) · \(item.type?.localizedDescription ?? String(localized: "파일"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            FileStatusBadge(item: item)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FileStatusBadge: View {
    var item: FileItem

    var body: some View {
        Group {
            switch item.download {
            case .downloading:
                EmptyView()
            case .failed:
                Label("실패", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case nil:
                if item.received == nil {
                    Label("받기 전", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                } else if item.isCurrent {
                    Label("받음", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("새 내용", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(PhoneTheme.tint)
                }
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
    }
}

struct FileTypeIcon: View {
    var type: UTType?
    var size: CGFloat = 32

    static func symbol(for type: UTType?) -> String {
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .json) || type.conforms(to: .sourceCode) || type.conforms(to: .propertyList) { return "curlybraces" }
        if type.conforms(to: .database) || ["sqlite", "db", "realm"].contains(type.preferredFilenameExtension ?? "") { return "cylinder.split.1x2" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    var body: some View {
        Image(systemName: Self.symbol(for: type))
            .font(.system(size: size * 0.6))
            .foregroundStyle(PhoneTheme.tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 파일 앱에서 이 앱의 폴더나 파일을 여는 주소(`shareddocuments://`).
enum FilesAppLink {
    static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first.flatMap(url(for:))
    }

    static func url(for file: URL) -> URL? {
        URL(string: "shareddocuments://" + file.path(percentEncoded: true))
    }
}
