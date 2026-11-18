import PhoneClientKit
import RDModels
import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// 빌드 목록의 앱 하나에서 크래시 기록을 열 때 쓰는 자료.
@MainActor
struct CrashPanel {
    var state: SettingsViewState
    var actions: SettingsActions
}

extension EnvironmentValues {
    @Entry var crashPanel: CrashPanel? = nil
}

/// 크래시 기록 칸: 모은 기록 목록, iPhone 설정 열기, 파일에서 가져오기. `app`을 주면 그 앱의 기록만 보인다.
struct CrashSection: View {
    var state: SettingsViewState
    var actions: SettingsActions
    var app: BuildDescriptor?
    @State private var showsImporter = false
    @State private var importError: String?

    var body: some View {
        Section {
            if app != nil, items.isEmpty {
                Text("이 앱의 기록을 아직 받지 않았습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                NavigationLink {
                    CrashDetailView(item: item, actions: actions)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.kind == .feedback ? String(localized: "피드백 · \(item.title)") : item.title).font(.body)
                        Text("\(item.crashedAt.formatted(date: .abbreviated, time: .standard)) · \(item.appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(item.sent ? "Mac에 보냄" : "아직 보내지 않음", systemImage: item.sent ? "checkmark.circle" : "clock")
                            .font(.caption)
                            .foregroundStyle(item.sent ? Color.secondary : Color.orange)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { actions.deleteCrash(items[index].id) }
            }
            if let error = importError ?? state.crashSendError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if app == nil {
                NavigationLink {
                    FeedbackComposer(canSendNow: state.canSendLogs, actions: actions)
                } label: {
                    Label("RemoteDebug 피드백 보내기", systemImage: "text.bubble")
                }
            }
            Button {
                actions.openAnalyticsData()
            } label: {
                Label("iPhone 설정에서 기록 찾기", systemImage: "gear")
            }
            Button {
                showsImporter = true
            } label: {
                Label("크래시 파일 가져오기…", systemImage: "folder")
            }
        } header: {
            Text(app == nil ? "크래시·피드백" : "\(app?.displayName ?? "") 크래시 기록")
        } footer: {
            if let app {
                Text("iPhone 설정 > 개인정보 보호 및 보안 > 분석 및 향상 > 분석 데이터에서 \(app.displayName)(으)로 시작하는 .ips 파일을 열고, 공유 버튼에서 RemoteDebug를 고르면 여기에 들어옵니다. 받은 기록은 Mac과 연결되면 자동으로 보냅니다.")
            } else {
                Text("이 앱이 비정상 종료되면 다음에 열 때 기록이 생깁니다. 다른 앱의 기록은 iPhone 설정 > 개인정보 보호 및 보안 > 분석 및 향상 > 분석 데이터에서 열고, 공유 버튼으로 RemoteDebug에 넘기거나 파일에 저장한 뒤 여기서 가져옵니다. 받은 기록은 Mac과 연결되면 자동으로 보냅니다.")
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.plainText, .json, .data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                importError = nil
                for url in urls {
                    if let error = await actions.importCrash(url) { importError = error }
                }
            }
        }
    }
}

extension CrashSection {
    /// 보여 줄 기록. 앱을 정했으면 번들 ID가 같은 것만.
    var items: [CrashBook.Item] {
        guard let app else { return state.crashes }
        return state.crashes.filter { $0.bundleId == app.bundleId }
    }
}

/// 빌드 목록에서 연 앱 하나의 크래시 기록.
struct AppCrashSheet: View {
    var app: BuildDescriptor
    var panel: CrashPanel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                CrashSection(state: panel.state, actions: panel.actions, app: app)
            }
            .navigationTitle("크래시 기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
    }
}

/// 크래시 기록 하나의 내용. 파일로 공유할 수 있다.
struct CrashDetailView: View {
    var item: CrashBook.Item
    var actions: SettingsActions
    @State private var text: String?

    var body: some View {
        ScrollView {
            Text(text ?? String(localized: "기록 파일을 읽을 수 없습니다."))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = actions.crashFile(item) {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) { Label("공유", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .task { text = actions.crashText(item) }
    }
}

/// RemoteDebug 앱에 대한 피드백을 적어 Mac에 보낸다. 사진과 파일은 사용자가 고른 것만 붙는다.
struct FeedbackComposer: View {
    var canSendNow: Bool
    var actions: SettingsActions
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includesLogs = true
    @State private var isSending = false
    /// 붙일 사진과 파일. 보낼 때까지 메모리에만 둔다(수와 크기는 `CrashReport`의 한도까지).
    @State private var attachments: [CrashReport.Attachment] = []
    @State private var attachNotice: String?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var photoNumber = 0
    @State private var picksFile = false

    private var isFull: Bool { attachments.count >= CrashReport.maxAttachments }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $message)
                    .frame(minHeight: 160)
                    .accessibilityLabel("피드백 내용")
            } header: {
                Text("무엇이 문제인가요?")
            }
            Section {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    HStack(spacing: 10) {
                        Image(systemName: attachment.type.hasPrefix("image/") ? "photo" : "doc")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.name).lineLimit(1).truncationMode(.middle)
                            Text(Int64(attachment.data.count).formatted(.byteCount(style: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            attachments.remove(at: index)
                            attachNotice = nil
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(attachment.name) 빼기")
                    }
                }
                PhotosPicker(selection: $pickedPhotos, maxSelectionCount: max(1, CrashReport.maxAttachments - attachments.count),
                             matching: .images) {
                    Label("사진 첨부", systemImage: "photo")
                }
                .disabled(isFull)
                Button {
                    picksFile = true
                } label: {
                    Label("파일 첨부", systemImage: "paperclip")
                }
                .disabled(isFull)
            } header: {
                Text("첨부")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("사진과 파일을 5개까지 붙일 수 있습니다. 파일 하나는 1MB, 모두 합쳐 1.5MB까지이고 사진은 크기를 줄여 붙입니다.")
                    if let attachNotice { Text(attachNotice).foregroundStyle(.red) }
                }
            }
            Section {
                Toggle("최근 진단 로그 붙이기", isOn: $includesLogs)
            } footer: {
                Text(canSendNow
                    ? "앱 버전, iOS 버전과 함께 페어링한 Mac으로 갑니다."
                    : "지금은 Mac과 연결돼 있지 않습니다. 저장해 두었다가 연결되면 보냅니다.")
            }
        }
        .navigationTitle("피드백 보내기")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task {
                attachNotice = nil
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self), let photo = UIImage(data: data),
                          let jpeg = Self.compressed(photo) else {
                        attachNotice = String(localized: "사진을 읽을 수 없습니다.")
                        continue
                    }
                    photoNumber += 1
                    add(.init(name: "photo-\(photoNumber).jpg", type: "image/jpeg", data: jpeg))
                }
            }
        }
        .fileImporter(isPresented: $picksFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            attachNotice = nil
            for url in (try? result.get()) ?? [] { addFile(url) }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("보내기") {
                    isSending = true
                    Task {
                        await actions.sendFeedback(message, includesLogs, attachments)
                        dismiss()
                    }
                }
                .disabled(isSending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// 한도 안이면 붙이고, 아니면 까닭을 알린다.
    private func add(_ attachment: CrashReport.Attachment) {
        switch CrashReport.attachmentRefusal(adding: attachment.data.count, to: attachments) {
        case nil: attachments.append(attachment)
        case .tooMany: attachNotice = String(localized: "첨부는 5개까지 붙일 수 있습니다.")
        case .tooLarge: attachNotice = String(localized: "1MB가 넘는 파일은 붙일 수 없습니다: \(attachment.name)")
        case .totalTooLarge: attachNotice = String(localized: "첨부는 모두 합쳐 1.5MB까지 붙일 수 있습니다.")
        }
    }

    /// 고른 파일을 읽어 붙인다. 파일을 다른 곳에 복사해 두지 않는다. 사진 파일은 줄여서, 나머지는 크기를 먼저 보고 읽는다.
    private func addFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if type?.conforms(to: .image) == true, size <= 50 << 20, let photo = UIImage(contentsOfFile: url.path),
           let jpeg = Self.compressed(photo) {
            add(.init(name: url.deletingPathExtension().lastPathComponent + ".jpg", type: "image/jpeg", data: jpeg))
            return
        }
        guard size <= CrashReport.maxAttachmentBytes else {
            attachNotice = String(localized: "1MB가 넘는 파일은 붙일 수 없습니다: \(name)")
            return
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            attachNotice = String(localized: "파일을 읽을 수 없습니다: \(name)")
            return
        }
        add(.init(name: name, type: type?.preferredMIMEType ?? "application/octet-stream", data: data))
    }

    /// 긴 변을 1600픽셀 아래로 줄이고 사진 한 장의 한도에 들어올 때까지 JPEG 품질과 크기를 낮춘다.
    static func compressed(_ photo: UIImage) -> Data? {
        let longest = max(photo.size.width, photo.size.height) * photo.scale
        for side in [1600.0, 1200, 800] {
            let scale = min(1, side / max(longest, 1))
            let size = CGSize(width: photo.size.width * photo.scale * scale, height: photo.size.height * photo.scale * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in photo.draw(in: CGRect(origin: .zero, size: size)) }
            for quality in [0.7, 0.5, 0.3] {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= CrashReport.maxAttachedImageBytes { return data }
            }
        }
        return nil
    }
}
