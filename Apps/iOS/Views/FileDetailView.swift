import AVKit
import PDFKit
import PhoneClientKit
import QuickLook
import QuickLookThumbnailing
import RDModels
import SwiftUI
import UniformTypeIdentifiers

/// 파일 하나의 상세: 받기 진행, 종류별 미리보기, 문서 정보, 열기·공유·파일 앱 링크.
struct FileDetailView: View {
    var item: FileItem
    var actions: PhoneActions
    var tunnelConnected: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var quickLook: URL?
    @State private var confirmsDelete = false
    @State private var copied: String?

    var body: some View {
        List {
            Section {
                header
            }
            statusSection
            if let file = item.received?.url, item.download != .downloading {
                Section("미리보기") {
                    FilePreview(url: file, type: item.type)
                }
            }
            infoSection
            linksSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($quickLook)
        .confirmationDialog("이 iPhone에서 지울까요?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("지우기", role: .destructive) {
                actions.deleteReceivedFile(item.name)
                if item.resource == nil { dismiss() }
            }
        } message: {
            Text(item.resource == nil ? "이 파일은 Mac 목록에 없어 다시 받을 수 없습니다." : "Mac 목록에 남아 있어 다시 받을 수 있습니다.")
        }
    }

    // MARK: 머리

    private var header: some View {
        HStack(spacing: 14) {
            FileThumbnail(url: item.received?.url, type: item.type)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(item.type?.localizedDescription ?? "파일")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(item.size.formatted(.byteCount(style: .file)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 상태와 동작

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch item.download {
            case .downloading:
                if let progress = item.progress {
                    TransferProgressView(progress: progress)
                }
                Button(role: .destructive) {
                    if let id = item.resource?.id { actions.cancelDownload(id) }
                } label: {
                    Label("받기 취소", systemImage: "xmark.circle")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                downloadButton(title: "다시 받기")
            case nil:
                if item.received == nil {
                    downloadButton(title: "받기")
                } else {
                    if !item.isCurrent, item.resource != nil {
                        Label("Mac의 파일이 바뀌었습니다. 받아 둔 것은 이전 내용입니다.", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(PhoneTheme.tint)
                        downloadButton(title: "새 내용 받기")
                    }
                    receivedActions
                }
            }
        } header: {
            Text("상태")
        } footer: {
            if item.download == .downloading {
                Text("앱을 닫아도 iOS가 계속 받습니다. 진행은 잠금 화면과 Dynamic Island에도 보입니다.")
            } else if item.resource != nil, item.received == nil || !item.isCurrent, !tunnelConnected {
                Text("받으려면 RemoteDebug VPN을 켜야 합니다.")
            }
        }
    }

    private func downloadButton(title: String) -> some View {
        Button {
            if let resource = item.resource { actions.downloadFile(resource) }
        } label: {
            Label(title, systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    @ViewBuilder
    private var receivedActions: some View {
        if let file = item.received?.url {
            Button {
                quickLook = file
            } label: {
                Label("열기", systemImage: "eye")
            }
            ShareLink(item: file) {
                Label("다른 앱으로 보내기", systemImage: "square.and.arrow.up")
            }
            if let link = FilesAppLink.url(for: file.deletingLastPathComponent()) {
                Button {
                    openURL(link)
                } label: {
                    Label("파일 앱에서 보기", systemImage: "folder")
                }
            }
            Button(role: .destructive) {
                confirmsDelete = true
            } label: {
                Label("이 iPhone에서 지우기", systemImage: "trash")
            }
        }
    }

    // MARK: 정보

    private var infoSection: some View {
        Section("정보") {
            LabeledContent("종류", value: item.type?.localizedDescription ?? "알 수 없음")
            if let identifier = item.type?.identifier {
                LabeledContent("형식 식별자") { Text(identifier).font(.caption.monospaced()).textSelection(.enabled) }
            }
            LabeledContent("크기") {
                Text("\(item.size.formatted(.byteCount(style: .file))) (\(item.size.formatted())바이트)")
                    .monospacedDigit()
            }
            if let resource = item.resource {
                LabeledContent("Mac에서 보낸 시각", value: resource.publishedAt.formatted(date: .abbreviated, time: .shortened))
                if let project = resource.project { LabeledContent("구역", value: project.name) }
            }
            if let received = item.received {
                LabeledContent("이 iPhone에 저장", value: received.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "알 수 없음")
                LabeledContent("저장 위치", value: "나의 iPhone › RemoteDebug › \(received.name)")
            }
            if let sha = item.resource?.sha256 ?? item.received?.sha256 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("SHA-256")
                        Spacer()
                        if item.received != nil, item.resource != nil {
                            Label(item.isCurrent ? "Mac과 같음" : "Mac과 다름", systemImage: item.isCurrent ? "checkmark.seal.fill" : "xmark.seal")
                                .font(.caption)
                                .foregroundStyle(item.isCurrent ? .green : .orange)
                        }
                    }
                    Text(sha)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let id = item.resource?.id {
                LabeledContent("파일 id") { Text(id).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
    }

    private var linksSection: some View {
        Section("복사") {
            copyButton("이름 복사", item.name)
            if let sha = item.resource?.sha256 ?? item.received?.sha256 {
                copyButton("SHA-256 복사", sha)
            }
            if let path = item.received?.url.path {
                copyButton("iPhone 안 경로 복사", path)
            }
        }
    }

    private func copyButton(_ title: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = title
        } label: {
            Label(copied == title ? "복사함" : title, systemImage: copied == title ? "checkmark" : "doc.on.doc")
        }
    }
}

/// 받는 중: 진행 막대, 바이트, 속도, 남은 시간.
struct TransferProgressView: View {
    var progress: FileTransferProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(PhoneTheme.tint)
                    Spacer()
                    Text("\(progress.received.formatted(.byteCount(style: .file))) / \(progress.total.formatted(.byteCount(style: .file)))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress.fraction)
                    .tint(PhoneTheme.tint)
                HStack {
                    if let speed = progress.bytesPerSecond(now: context.date) {
                        Text("\(Int64(speed).formatted(.byteCount(style: .file)))/초")
                    }
                    Spacer()
                    if let remaining = progress.remainingSeconds(now: context.date) {
                        Text("남은 시간 \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 받은 파일의 썸네일. 없으면 종류 아이콘.
private struct FileThumbnail: View {
    var url: URL?
    var type: UTType?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                FileTypeIcon(type: type, size: 64)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PhoneTheme.tint.opacity(0.12)))
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: 3, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}

/// 종류별 미리보기: 이미지, 동영상·소리, PDF, 텍스트·JSON. 그 밖에는 iOS 미리보기를 안내한다.
private struct FilePreview: View {
    var url: URL
    var type: UTType?

    var body: some View {
        if let type, type.conforms(to: .image) {
            ImagePreview(url: url)
        } else if let type, type.conforms(to: .audiovisualContent) {
            MediaPreview(url: url)
        } else if let type, type.conforms(to: .pdf) {
            PDFPreview(url: url)
        } else if let type, type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .propertyList) || type.conforms(to: .sourceCode) {
            TextPreview(url: url, isJSON: type.conforms(to: .json))
        } else {
            Text("이 형식은 여기서 미리 볼 수 없습니다. 위의 ‘열기’로 iOS 미리보기를 쓰거나 다른 앱으로 보내세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ImagePreview: View {
    var url: URL
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 360)
                    .frame(maxWidth: .infinity)
                Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale)) 픽셀")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: url) {
            image = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 1600, height: 1600)) ?? UIImage(contentsOfFile: url.path) }.value
        }
    }
}

private struct MediaPreview: View {
    var url: URL
    @State private var player: AVPlayer?
    @State private var info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoPlayer(player: player)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let info {
                Text(info)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            player = AVPlayer(url: url)
            let asset = AVURLAsset(url: url)
            var parts: [String] = []
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                parts.append("길이 " + Duration.seconds(duration.seconds).formatted(.time(pattern: duration.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                parts.append("\(Int(abs(size.width))) × \(Int(abs(size.height)))")
            }
            info = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        .onDisappear { player?.pause() }
    }
}

private struct PDFPreview: View {
    var url: URL

    var body: some View {
        let document = PDFDocument(url: url)
        VStack(alignment: .leading, spacing: 8) {
            PDFKitView(document: document)
                .frame(height: 420)
            if let count = document?.pageCount {
                Text("\(count)쪽")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    var document: PDFDocument?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

private struct TextPreview: View {
    var url: URL
    var isJSON: Bool
    @State private var text: String?
    @State private var summary: String?

    nonisolated static let limit = 64 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            let isJSON = self.isJSON
            let result = await Task.detached { () -> (String, String) in
                guard let handle = try? FileHandle(forReadingFrom: url) else { return ("읽지 못했습니다.", "") }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: Self.limit + 1)) ?? Data()
                let truncated = data.count > Self.limit
                let body = data.prefix(Self.limit)
                if isJSON, !truncated, let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
                   let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                    let text = String(decoding: pretty, as: UTF8.self)
                    return (text, "JSON · \(text.split(separator: "\n").count)줄(정리해서 보임)")
                }
                let text = String(decoding: body, as: UTF8.self)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                return (text, truncated ? "앞 64KB만 보임 · \(lines)줄" : "\(lines)줄" + (isJSON ? " · JSON 형식이 아님" : ""))
            }.value
            text = result.0
            summary = result.1.isEmpty ? nil : result.1
        }
    }
}
