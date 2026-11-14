import MacHostKit
import SwiftUI

/// 샌드박스판의 프로젝트 화면. 프로젝트 폴더를 등록하면 Xcode에서 한 최근 Debug 기기용 빌드를 찾아 게시한다.
struct LinkedProjectsView: View {
    let projects: LinkedProjectsModel

    @State private var choosingProject = false
    @State private var choosingDerivedData = false

    var body: some View {
        Group {
            if projects.projects.isEmpty {
                ContentUnavailableView {
                    Label("등록한 프로젝트 없음", systemImage: "hammer")
                } description: {
                    Text("프로젝트 폴더를 등록하면 Xcode에서 iPhone용으로 빌드할 때마다 최근 Debug 빌드를 찾아 게시합니다.")
                } actions: {
                    Button("프로젝트 추가…") { choosingProject = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(projects.projects) { project in
                        row(project)
                    }
                }
            }
        }
        .navigationTitle("프로젝트")
        .toolbar {
            Button { choosingProject = true } label: {
                Label("프로젝트 추가…", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .help("Xcode 프로젝트가 있는 폴더를 고릅니다")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if projects.derivedData == nil, !projects.projects.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Xcode의 기본 빌드 폴더(DerivedData)에 있는 빌드를 찾으려면 그 폴더를 한 번 허용하세요. 빌드 위치를 프로젝트 폴더 안으로 둔 프로젝트는 허용 없이 찾습니다.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("빌드 폴더 허용…") { choosingDerivedData = true }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
                if let message = projects.lastError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.bar)
                }
            }
        }
        .fileImporter(isPresented: $choosingProject, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await projects.add(url) }
        }
        .fileDialogMessage("Xcode 프로젝트(.xcodeproj)가 있는 폴더를 고르세요.")
        .background {
            // fileImporter는 뷰 하나에 하나만 동작한다.
            Color.clear
                .fileImporter(isPresented: $choosingDerivedData, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    Task { await projects.allowDerivedData(url) }
                }
                .fileDialogDefaultDirectory(LinkedProjectsModel.defaultDerivedData)
                .fileDialogMessage("Xcode의 빌드 폴더(DerivedData)를 고르세요. 위치는 Xcode > Settings > Locations에 있습니다.")
        }
    }

    private func row(_ project: LinkedProjectsModel.Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name).font(.headline)
                Spacer()
                Button("등록 해제") { projects.remove(project) }
                    .accessibilityLabel("\(project.name) 등록 해제")
            }
            Text(project.folder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !project.hasContainer {
                Text("폴더를 읽을 수 없거나 Xcode 프로젝트가 없습니다. 등록을 해제하고 다시 추가하세요.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if project.builds.isEmpty {
                Text("기기용 Debug 빌드가 아직 없습니다. Xcode에서 iPhone을 대상으로 빌드하세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(project.builds, id: \.app) { build in
                    HStack {
                        Label(build.app.lastPathComponent, systemImage: "shippingbox")
                        Spacer()
                        Text(build.modified, format: .relative(presentation: .named))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
