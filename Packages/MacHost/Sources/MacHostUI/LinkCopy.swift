import AppKit
import SwiftUI

/// 링크를 클립보드에 넣고 VoiceOver로 알린다. 화면은 환경 값(`linkCopier`)으로 받아 테스트에서 바꿔 끼운다.
struct LinkCopier: Sendable {
    var write: @MainActor @Sendable (String) -> Void
    var announce: @MainActor @Sendable (String) -> Void

    /// 클립보드에는 링크 문자열만 넣는다.
    @MainActor
    func copy(_ url: URL, announcement: String?) {
        write(url.absoluteString)
        if let announcement { announce(announcement) }
    }

    static let system = LinkCopier(
        write: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        },
        announce: { text in
            guard let app = NSApp else { return }
            NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    )
}

extension EnvironmentValues {
    @Entry var linkCopier = LinkCopier.system
}

/// 복사 버튼. 누르면 잠깐 "복사됨"과 체크 표시로 바뀐다. 링크가 바뀌면 원래대로 돌아간다.
struct CopyLinkButton: View {
    @Environment(\.linkCopier) private var copier
    let url: URL
    /// 버튼 이름. `iconOnly`면 보이지 않고 접근성 이름으로만 쓴다.
    let title: String
    let announcement: String
    var iconOnly = false
    @State private var copiedAt: Date?

    static let copiedTitle = "복사됨"

    var body: some View {
        Button {
            copier.copy(url, announcement: announcement)
            copiedAt = Date()
        } label: {
            if iconOnly {
                Label(title, systemImage: copiedAt == nil ? "doc.on.doc" : "checkmark")
                    .labelStyle(.iconOnly)
            } else {
                Label(copiedAt == nil ? title : Self.copiedTitle, systemImage: copiedAt == nil ? "doc.on.doc" : "checkmark")
            }
        }
        .help(url.absoluteString)
        .onChange(of: url) { copiedAt = nil }
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copiedAt = nil }
        }
    }
}
