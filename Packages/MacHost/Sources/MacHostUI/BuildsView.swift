import MacHostKit
import RDModels
import SwiftUI

struct BuildsView: View {
    @Environment(HostModel.self) private var model
    @Environment(ImportQueue.self) private var importQueue
    let showImporter: () -> Void

    @State private var choosingFolder = false
    @State private var buildToUnpublish: LibraryBuild?

    var body: some View {
        Group {
            if Self.showsEmptyState(model: model, pendingCount: importQueue.pending.count) {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("빌드")
        .toolbar {
            ToolbarItemGroup {
                if model.importsInProgress > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("빌드 \(model.importsInProgress)개 가져오는 중")
                }
                Button(action: showImporter) {
                    Label("빌드 가져오기…", systemImage: "square.and.arrow.down")
                }
                .help("빌드 가져오기 (⌘O)")
                Button { choosingFolder = true } label: {
                    Label("폴더 감시…", systemImage: "folder.badge.gearshape")
                }
                .help("고른 폴더의 빌드를 가져오고, 새로 빌드되는 앱도 자동으로 가져옵니다")
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.chooseFolder(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let builds = urls.filter { ["app", "ipa"].contains($0.pathExtension.lowercased()) }
            guard !builds.isEmpty else { return false }
            Task { await importQueue.importURLs(builds) { [model] url, mode in await model.importBuild(url, mode: mode) } }
            return true
        }
        .confirmationDialog(
            "게시를 취소할까요?",
            isPresented: Binding(get: { buildToUnpublish != nil }, set: { if !$0 { buildToUnpublish = nil } }),
            presenting: buildToUnpublish
        ) { build in
            Button("게시 취소", role: .destructive) {
                Task { await model.unpublish(build.id) }
            }
            Button("돌아가기", role: .cancel) {}
        } message: { build in
            Text("\(build.descriptor.displayName) \(build.descriptor.version) (\(build.descriptor.buildNumber)): iPhone의 빌드 목록에서 빠지고, 진행 중인 설치는 끊깁니다. 원본 파일은 그대로 둡니다.")
        }
    }

    /// 보여 줄 빌드·거부·대기·감시 폴더 문제가 하나도 없다.
    static func showsEmptyState(model: HostModel, pendingCount: Int) -> Bool {
        model.builds.isEmpty && model.rejected.isEmpty && pendingCount == 0 && model.watchProblem == nil
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("가져온 빌드 없음", systemImage: "shippingbox")
        } description: {
            Text("Xcode에서 Debug 구성으로 기기용으로 빌드한 .app이나 .ipa를 가져오세요. 창으로 끌어 놓아도 됩니다.")
        } actions: {
            Button("빌드 가져오기…", action: showImporter)
                .buttonStyle(.borderedProminent)
            Button("폴더 감시…") { choosingFolder = true }
        }
        .safeAreaInset(edge: .bottom) {
            if model.watchedFolder != nil {
                WatchedFolderRow(chooseFolder: { choosingFolder = true }).padding()
            }
        }
    }

    private var list: some View {
        List {
            if model.watchedFolder != nil || model.watchProblem != nil {
                Section("감시 폴더") {
                    WatchedFolderRow(chooseFolder: { choosingFolder = true })
                }
            }
            if !importQueue.pending.isEmpty {
                Section("Debug 구성 확인 대기 \(importQueue.pending.count)개") {
                    ForEach(importQueue.pending) { item in
                        PendingImportRow(item: item)
                    }
                }
            }
            Section {
                if !model.isRunning && !model.builds.isEmpty {
                    NotSharingRow()
                }
                if model.builds.isEmpty {
                    HStack {
                        Text("게시할 빌드가 없습니다.").foregroundStyle(.secondary)
                        Spacer()
                        Button("빌드 가져오기…", action: showImporter)
                    }
                }
                ForEach(model.builds) { build in
                    PublishedBuildRow(build: build) { buildToUnpublish = build }
                }
            } header: {
                Text("게시된 빌드 \(model.builds.count)개")
            }
            if !model.rejected.isEmpty {
                Section {
                    ForEach(model.rejected) { item in
                        RejectedBuildRow(item: item)
                    }
                } header: {
                    HStack {
                        Text("거부된 빌드 \(model.rejected.count)개")
                        Spacer()
                        Button("목록 지우기") { Task { await model.clearRejected() } }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
    }
}

private struct NotSharingRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("공유가 꺼져 있어 iPhone에서 이 빌드를 볼 수 없습니다.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
            Spacer()
            SharingButton()
        }
    }
}

struct PublishedBuildRow: View {
    let build: LibraryBuild
    let unpublish: () -> Void

    private var d: BuildDescriptor { build.descriptor }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.displayName).font(.headline)
                    Text("\(d.version) (\(d.buildNumber))")
                        .foregroundStyle(.secondary)
                }
                Text(d.bundleId)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow {
                        Text("구성").foregroundStyle(.secondary)
                        Text(Self.evidence(d))
                    }
                    GridRow {
                        Text("프로필 만료").foregroundStyle(.secondary)
                        ProfileExpiry(date: d.signing.profileExpires)
                    }
                    GridRow {
                        Text("게시").foregroundStyle(.secondary)
                        Text(d.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.callout)
            }
            Spacer()
            Button("게시 취소", action: unpublish)
                .accessibilityLabel("\(d.displayName) 게시 취소")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    static func evidence(_ d: BuildDescriptor) -> String {
        switch d.configurationEvidence {
        case .path: "\(d.configuration) · \(d.configuration)-iphoneos 폴더"
        case .debugDylib: "\(d.configuration) · debug.dylib 있음"
        case .userConfirmed: "\(d.configuration) · 직접 확인"
        }
    }
}

private struct ProfileExpiry: View {
    let date: Date

    var body: some View {
        let soon = date.timeIntervalSinceNow < 7 * 86_400
        HStack(spacing: 4) {
            if soon {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(date.formatted(date: .abbreviated, time: .omitted))
            if soon {
                Text("(7일 안에 만료)").foregroundStyle(.orange)
            }
        }
    }
}

struct RejectedBuildRow: View {
    let item: RejectedBuild

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(.title2)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.fileName).font(.headline)
                    if let bundleId = item.bundleId {
                        Text(bundleId)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(item.messages, id: \.self) { message in
                    Text(message).font(.callout)
                }
                Text(item.rejectedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityText(item))
    }

    static func accessibilityText(_ item: RejectedBuild) -> String {
        "거부됨: \(item.fileName). \(item.messages.joined(separator: " "))"
    }
}

/// 감시 중인 폴더. 폴더를 찾거나 읽을 수 없으면 그 사실과 다시 고르기를 보여 준다.
private struct WatchedFolderRow: View {
    @Environment(HostModel.self) private var model
    let chooseFolder: () -> Void

    var body: some View {
        if let problem = model.watchProblem {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if !problem.path.isEmpty {
                        Text(problem.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(problem.path)
                    }
                }
                Spacer()
                if model.watchedFolder != nil {
                    Button("다시 확인") { Task { await model.rescan() } }
                }
                Button("폴더 다시 고르기", action: chooseFolder)
                    .buttonStyle(.borderedProminent)
                Button("감시 중지") { Task { await model.forgetFolder() } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("감시 폴더 문제")
        } else if let folder = model.watchedFolder {
            HStack {
                Label(folder.path, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                Spacer()
                Button("다시 확인") { Task { await model.rescan() } }
                Button("감시 중지") { Task { await model.forgetFolder() } }
            }
        }
    }
}

/// 구성을 확인하지 못해 사용자 답을 기다리는 빌드. 대화상자와 같은 답을 여기서도 할 수 있다(항목 id로 답한다).
private struct PendingImportRow: View {
    @Environment(HostModel.self) private var model
    @Environment(ImportQueue.self) private var importQueue
    let item: ImportQueue.Pending

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Label(ImportConfirmation.title(item), systemImage: "questionmark.app")
                Text(item.url.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("가져오지 않기") { importQueue.skip(item.id) }
            Button("Debug 빌드로 가져오기") {
                importQueue.confirm(item.id) { [model] url, mode in await model.importBuild(url, mode: mode) }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
