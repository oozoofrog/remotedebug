import MacHostKit
import RDModels
import SwiftUI

struct BuildsView: View {
    @Environment(HostModel.self) private var model
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.connectProjects) private var connectProjects
    let showImporter: () -> Void

    @State private var choosingFolder = false
    @State private var buildToUnpublish: LibraryBuild?
    @State private var listWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 카드 두 장이 나란히 들어가는 너비부터 2열로 놓는다.
    private var columns: Int { listWidth >= 1080 ? 2 : 1 }

    /// 같은 앱의 빌드는 한 카드로 묶는다.
    private var groups: [AppBuildGroup<LibraryBuild>] {
        AppBuildGrouping.groups(model.builds) { $0.descriptor }
    }

    private var buildRows: [[AppBuildGroup<LibraryBuild>]] {
        let groups = groups
        return stride(from: 0, to: groups.count, by: columns).map {
            Array(groups[$0..<min($0 + columns, groups.count)])
        }
    }

    @State private var expandedApps: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            OverviewHero()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 6)
            SetupChecklistCard(showImporter: showImporter)
            if Self.showsEmptyState(model: model, pendingCount: importQueue.pending.count) {
                emptyState
                    .frame(maxHeight: .infinity)
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
            let projectURLs = ProjectConnector.projectURLs(in: urls)
            if !projectURLs.isEmpty { connectProjects(projectURLs) }
            guard !builds.isEmpty else { return !projectURLs.isEmpty }
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
            Group {
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
                ForEach(buildRows, id: \.first?.id) { row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { group in
                            PublishedBuildRow(
                                build: group.latest,
                                older: group.older,
                                expanded: expandedApps.contains(group.bundleId),
                                toggle: { expandedApps.formSymmetricDifference([group.bundleId]) },
                                fillsHeight: columns > 1
                            ) { buildToUnpublish = $0 }
                        }
                        if row.count < columns {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                    .rdListRow()
                }
            } header: {
                Text(groups.count == model.builds.count ? "게시된 빌드 \(model.builds.count)개" : "게시된 앱 \(groups.count)개 · 빌드 \(model.builds.count)개")
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
            .listSectionSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        .animation(reduceMotion ? nil : .snappy, value: model.builds.map(\.id))
        .animation(reduceMotion ? nil : .snappy, value: columns)
        .animation(reduceMotion ? nil : .snappy, value: expandedApps)
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
    /// 같은 앱의 이전 빌드(늦게 게시된 순서).
    var older: [LibraryBuild] = []
    var expanded = false
    var toggle: () -> Void = {}
    var fillsHeight = false
    let unpublish: (LibraryBuild) -> Void

    private var d: BuildDescriptor { build.descriptor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            latest
            if !older.isEmpty {
                Divider()
                Button(action: toggle) {
                    Label("이전 빌드 \(older.count)개", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(d.displayName) 이전 빌드 \(older.count)개")
                .accessibilityValue(expanded ? "펼침" : "접힘")
                if expanded {
                    ForEach(older) { old in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(old.descriptor.version) (\(old.descriptor.buildNumber))")
                            Text("게시 " + old.descriptor.publishedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("게시 취소") { unpublish(old) }
                                .controlSize(.small)
                                .accessibilityLabel("\(old.descriptor.displayName) \(old.descriptor.publishedAt.formatted(date: .abbreviated, time: .shortened)) 빌드 게시 취소")
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .rdCardSurface(fillHeight: fillsHeight)
        .accessibilityElement(children: .contain)
    }

    private var latest: some View {
        HStack(alignment: .top, spacing: 14) {
            BuildIcon(name: d.displayName, seed: d.bundleId, icon: d.icon, sourcePath: build.sourcePath)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(d.displayName).font(.title3.weight(.semibold))
                    Text("\(d.version) (\(d.buildNumber))")
                        .foregroundStyle(.secondary)
                }
                Text(d.bundleId)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Chip(text: Self.evidence(d), symbol: "ladybug.fill", color: RDTheme.tint)
                    Chip(text: "게시 " + d.publishedAt.formatted(.relative(presentation: .named)), symbol: "clock")
                        .help(d.publishedAt.formatted(date: .abbreviated, time: .shortened))
                }
                HStack(spacing: 6) {
                    Text("프로필 만료").foregroundStyle(.secondary)
                    ProfileExpiry(date: d.signing.profileExpires)
                }
                .font(.callout)
            }
            Spacer()
            Button("게시 취소") { unpublish(build) }
                .accessibilityLabel("\(d.displayName) 게시 취소")
        }
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
        .rdCard()
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
