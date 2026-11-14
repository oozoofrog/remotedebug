import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RemoteDebugWidgets: WidgetBundle {
    var body: some Widget {
        FileTransferLiveActivity()
    }
}

private let brandTint = Color(red: 0.04, green: 0.55, blue: 0.58)

struct FileTransferLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FileTransferAttributes.self) { context in
            LockScreenTransferView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.9))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percentText(context.state))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(brandTint)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: context.state.fraction)
                            .tint(brandTint)
                        Text(detailText(context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                Text(percentText(context.state))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(brandTint)
            } minimal: {
                ProgressView(value: context.state.fraction) {
                    PhaseIcon(phase: context.state.phase).font(.caption2)
                }
                .progressViewStyle(.circular)
                .tint(brandTint)
            }
            .keylineTint(brandTint)
        }
    }
}

private struct LockScreenTransferView: View {
    var attributes: FileTransferAttributes
    var state: FileTransferAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PhaseIcon(phase: state.phase)
                Text(attributes.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(percentText(state))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(brandTint)
            }
            ProgressView(value: state.fraction)
                .tint(brandTint)
            Text(detailText(state))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct PhaseIcon: View {
    var phase: FileTransferAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .receiving: Image(systemName: "arrow.down.circle.fill").foregroundStyle(brandTint)
        case .received: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}

private func percentText(_ state: FileTransferAttributes.ContentState) -> String {
    switch state.phase {
    case .received: String(localized: "완료")
    case .failed: String(localized: "실패")
    case .cancelled: String(localized: "취소")
    case .receiving: "\(Int(state.fraction * 100))%"
    }
}

private func detailText(_ state: FileTransferAttributes.ContentState) -> String {
    let bytes = "\(state.received.formatted(.byteCount(style: .file))) / \(state.total.formatted(.byteCount(style: .file)))"
    switch state.phase {
    case .receiving: return String(localized: "Mac에서 받는 중 · \(bytes)")
    case .received: return String(localized: "받음 · 파일 앱의 RemoteDebug 폴더")
    case .failed: return state.message ?? String(localized: "받지 못했습니다")
    case .cancelled: return String(localized: "받기를 취소했습니다 · \(bytes)")
    }
}
