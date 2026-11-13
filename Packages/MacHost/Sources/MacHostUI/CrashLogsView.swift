import AppKit
import MacHostKit
import RDModels
import SwiftUI

/// iPhone이 보낸 크래시 기록: 목록과 원문.
struct CrashLogsView: View {
    @Environment(HostModel.self) private var model
    @State private var selection: String?
    @State private var search = ""

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
                    Label("받은 크래시 기록 없음", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("RemoteDebug iPhone 앱이 비정상 종료되면 다시 열 때 기록을 보냅니다. 다른 앱의 기록은 iPhone 설정 > 개인정보 보호 및 보안 > 분석 및 향상 > 분석 데이터에서 열고, 공유 버튼으로 RemoteDebug에 넘기면 여기로 들어옵니다.")
                }
            } else {
                HSplitView {
                    List(shown, selection: Binding(get: { selected?.id }, set: { selection = $0 })) { item in
                        CrashRow(item: item).tag(item.id)
                    }
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    if let selected {
                        CrashText(text: store.text(selected))
                            .id(selected.id)
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView.search(text: search)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("크래시")
        .searchable(text: $search, placement: .toolbar, prompt: "앱·기기 검색")
        .toolbar {
            ToolbarItemGroup {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.headline).lineLimit(1)
            Text(item.crashedAt.formatted(date: .abbreviated, time: .standard))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\(item.appVersion) · \(item.deviceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct CrashText: View {
    let text: String?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text ?? "기록 파일을 읽을 수 없습니다.")
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
    }
}
