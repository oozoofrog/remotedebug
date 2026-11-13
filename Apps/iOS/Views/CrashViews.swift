import PhoneClientKit
import RDModels
import SwiftUI
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
                        Text(item.title).font(.body)
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
            Text(app == nil ? "크래시 기록" : "\(app?.displayName ?? "") 크래시 기록")
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
            Text(text ?? "기록 파일을 읽을 수 없습니다.")
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
