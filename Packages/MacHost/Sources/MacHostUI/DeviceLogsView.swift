import AppKit
import MacHostKit
import RDModels
import SwiftUI

/// iPhone이 보낸 진단 로그.
struct DeviceLogsView: View {
    @Environment(HostModel.self) private var model
    @State private var selectedDevice: String?
    @State private var search = ""
    @State private var minimumLevel: DeviceLogEntry.Level = .debug
    @State private var confirmsClear = false

    private var store: DeviceLogStore { model.deviceLogs }
    private var device: DeviceLogStore.Device? {
        selectedDevice.flatMap(store.device(id:)) ?? store.devices.first
    }

    private var shown: [DeviceLogEntry] {
        guard let device else { return [] }
        let order = DeviceLogEntry.Level.allCases
        let minimum = order.firstIndex(of: minimumLevel) ?? 0
        return device.entries.filter { entry in
            (order.firstIndex(of: entry.level) ?? 0) >= minimum
                && (search.isEmpty || entry.line.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        Group {
            if let device {
                VStack(spacing: 0) {
                    header(device)
                    Divider()
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .frame(maxHeight: .infinity)
                    } else {
                        list
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("받은 iPhone 로그 없음", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("페어링한 iPhone의 RemoteDebug 앱이 VPN에 연결되면 빌드 목록을 받을 때마다 로그를 보냅니다. iPhone 앱의 설정 > 진단 로그에서 바로 보낼 수도 있습니다.")
                }
            }
        }
        .navigationTitle("iPhone 로그")
        .searchable(text: $search, placement: .toolbar, prompt: "로그 검색")
        .toolbar {
            ToolbarItemGroup {
                Picker("수준", selection: $minimumLevel) {
                    Text("모두").tag(DeviceLogEntry.Level.debug)
                    Text("정보 이상").tag(DeviceLogEntry.Level.info)
                    Text("경고 이상").tag(DeviceLogEntry.Level.warning)
                    Text("오류만").tag(DeviceLogEntry.Level.error)
                }
                .pickerStyle(.menu)
                .help("보여 줄 로그 수준")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.map(\.line).joined(separator: "\n"), forType: .string)
                } label: {
                    Label("보이는 로그 복사", systemImage: "doc.on.doc")
                }
                .disabled(shown.isEmpty)
                .help("보이는 로그를 텍스트로 복사")
                Button {
                    if let device, let url = store.fileURL(deviceID: device.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Label("Finder에서 보기", systemImage: "folder")
                }
                .disabled(device == nil)
                Button(role: .destructive) { confirmsClear = true } label: {
                    Label("이 기기 로그 지우기", systemImage: "trash")
                }
                .disabled(device == nil)
            }
        }
        .confirmationDialog("\(device?.name ?? "") 로그를 지울까요?", isPresented: $confirmsClear) {
            Button("로그 지우기", role: .destructive) {
                if let id = device?.id { store.clear(deviceID: id) }
                selectedDevice = nil
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 Mac에 저장된 이 기기의 로그를 모두 지웁니다. iPhone에 남은 로그는 지우지 않습니다.")
        }
    }

    private func header(_ device: DeviceLogStore.Device) -> some View {
        HStack(spacing: 12) {
            if store.devices.count > 1 {
                Picker("기기", selection: Binding(get: { device.id }, set: { selectedDevice = $0 })) {
                    ForEach(store.devices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            } else {
                Label(device.name, systemImage: "iphone").font(.headline)
            }
            Text(device.nodeName).font(.callout.monospaced()).foregroundStyle(.secondary)
            Spacer()
            if let received = device.lastReceived {
                Text("마지막 수신 \(received.formatted(.relative(presentation: .named)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(shown.count)/\(device.entries.count)줄")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(shown) { entry in
                LogRow(entry: entry).id(entry.id)
            }
            .listStyle(.plain)
            .onAppear { proxy.scrollTo(shown.last?.id, anchor: .bottom) }
            .onChange(of: shown.last?.id) { _, last in
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

private struct LogRow: View {
    let entry: DeviceLogEntry

    private var color: Color {
        switch entry.level {
        case .error: .red
        case .warning: .orange
        case .info: .primary
        case .debug: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.at.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(entry.level.rawValue.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(color)
                .frame(width: 56, alignment: .leading)
            Text(entry.source)
                .foregroundStyle(RDTheme.tint)
                .frame(width: 64, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
        .accessibilityElement(children: .combine)
    }
}
