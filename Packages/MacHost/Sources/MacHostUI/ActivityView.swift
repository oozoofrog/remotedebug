import MacHostKit
import RDModels
import SwiftUI

struct ActivityView: View {
    enum Tab: Hashable { case activity, logs }

    @Environment(HostModel.self) private var model
    @State private var tab: Tab = .activity

    var body: some View {
        Group {
            switch tab {
            case .activity: activityList
            case .logs: logList
            }
        }
        .navigationTitle("활동")
        .toolbar {
            Picker("보기", selection: $tab) {
                Text("활동").tag(Tab.activity)
                Text("코어 로그").tag(Tab.logs)
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var activityList: some View {
        if model.activity.isEmpty {
            ContentUnavailableView("기록 없음", systemImage: "list.bullet.rectangle",
                                   description: Text("페어링 결과, 설치 진행, 거부된 접근이 여기에 기록됩니다."))
        } else {
            List(model.activity) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: Self.symbol(item.kind))
                        .foregroundStyle(Self.tint(item.kind))
                        .accessibilityHidden(true)
                    Text(item.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.date.formatted(date: .omitted, time: .standard))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var logList: some View {
        if model.logs.isEmpty {
            ContentUnavailableView("코어 로그 없음", systemImage: "doc.plaintext",
                                   description: Text("공유 중 코어가 남긴 경고와 메시지가 여기에 표시됩니다."))
        } else {
            List(Array(model.logs.enumerated().reversed()), id: \.offset) { _, log in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(log.level.uppercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(log.level == "error" ? .red : (log.level == "warn" ? .orange : .secondary))
                        .frame(width: 48, alignment: .leading)
                    Text(log.message)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    static func symbol(_ kind: ActivityItem.Kind) -> String {
        switch kind {
        case .denied: "hand.raised"
        case .session(let e):
            switch e.state {
            case .completed: "checkmark.circle"
            case .failed, .expired: "xmark.circle"
            default: "arrow.down.circle"
            }
        case .pairDecided: "person.crop.circle.badge.checkmark"
        case .deviceAdded: "iphone"
        }
    }

    static func tint(_ kind: ActivityItem.Kind) -> Color {
        switch kind {
        case .denied: .orange
        case .session(let e):
            switch e.state {
            case .completed: .green
            case .failed, .expired: .red
            default: .secondary
            }
        case .pairDecided, .deviceAdded: .secondary
        }
    }
}
