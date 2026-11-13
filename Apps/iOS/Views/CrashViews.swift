import PhoneClientKit
import RDModels
import SwiftUI
import UniformTypeIdentifiers

/// 설정 화면의 크래시 기록 칸: 모은 기록 목록, 파일에서 가져오기.
struct CrashSection: View {
    var state: SettingsViewState
    var actions: SettingsActions
    @State private var showsImporter = false
    @State private var importError: String?

    var body: some View {
        Section {
            ForEach(state.crashes) { item in
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
                for index in offsets { actions.deleteCrash(state.crashes[index].id) }
            }
            if let error = importError ?? state.crashSendError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button("크래시 파일 가져오기…") { showsImporter = true }
        } header: {
            Text("크래시 기록")
        } footer: {
            Text("이 앱이 비정상 종료되면 다음에 열 때 기록이 생깁니다. 다른 앱의 기록은 iPhone 설정 > 개인정보 보호 및 보안 > 분석 및 향상 > 분석 데이터에서 열고, 공유 버튼으로 RemoteDebug에 넘기거나 파일에 저장한 뒤 여기서 가져옵니다. 받은 기록은 Mac과 연결되면 자동으로 보냅니다.")
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
