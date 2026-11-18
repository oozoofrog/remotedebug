import Combine
import Foundation

/// Own this session at the settings root, outside changing Form/Section rows.
@MainActor
public final class FeedbackSession: ObservableObject {
    public let recipient: String
    public let labels: FeedbackLabels
    public let appInfo: FeedbackAppInfo
    private let content: (FeedbackAppInfo) -> FeedbackContent
    @Published public var composing: FeedbackMail?
    @Published public private(set) var status: String?
    @Published public private(set) var isCollecting = false
    public var diagnostics: FeedbackDiagnostics?
    @Published public var attachesDiagnostics = true
    /// Photos and files the user chose. They go into the mail as they are, never into the diagnostics file.
    public var files: [FeedbackFile] = []
    @Published public var checklist: [FeedbackCheck] = []
    @Published public private(set) var diagnosticsFile: URL?
    private var hasFallbackAttachment = false
    private var hasFallbackFiles = false
    private var temporaryDirectory: URL?

    public init(recipient: String, appInfo: FeedbackAppInfo, labels: FeedbackLabels = FeedbackLabels(),
                content: @escaping (FeedbackAppInfo) -> FeedbackContent = FeedbackContent.standard) {
        self.recipient = recipient
        self.appInfo = appInfo
        self.labels = labels
        self.content = content
    }

    /// Returns a mailto URL only when the native composer is unavailable. Never sends mail itself.
    public func prepare(canSendMail: Bool, temporaryRoot: URL? = nil) async -> URL? {
        guard !isCollecting, composing == nil else { return nil }
        status = nil
        isCollecting = true
        defer { isCollecting = false }
        var attachment: FeedbackAttachment?
        clearTemporaryFile()
        hasFallbackAttachment = false
        hasFallbackFiles = false
        if attachesDiagnostics, let diagnostics {
            do {
                attachment = try await diagnostics.attachment(checklist: checklist)
            } catch is CancellationError {
                return nil
            } catch {
                status = labels.collectionFailed
            }
        }
        guard !Task.isCancelled else { return nil }
        let mail = FeedbackMail(recipient: recipient, content: content(appInfo), attachment: attachment, files: files,
                                attachmentNotice: labels.attachmentNotice)
        if canSendMail {
            composing = mail
            return nil
        }
        hasFallbackFiles = !files.isEmpty
        if let attachment {
            hasFallbackAttachment = true
            // 진단 파일은 정해진 폴더 하나에만 둔다. 새로 만들기 전에 폴더를 비워 기기에 한 개까지만 남는다.
            let root = temporaryRoot ?? FileManager.default.temporaryDirectory
            Self.removeLeftovers(in: root)
            let directory = root.appendingPathComponent(Self.temporaryFolderName, isDirectory: true)
            temporaryDirectory = directory
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(attachment.fileName)
                try attachment.data.write(to: file, options: .atomic)
                diagnosticsFile = file
            } catch {
                clearTemporaryFile()
                appendStatus(labels.shareFailed)
            }
        }
        guard let url = mail.mailtoURL else {
            openedMailLink(accepted: false)
            return nil
        }
        return url
    }

    public func openedMailLink(accepted: Bool) {
        if !accepted { appendStatus(labels.unavailable) }
        if hasFallbackAttachment, diagnosticsFile != nil { appendStatus(labels.separateAttachment) }
        if hasFallbackFiles { appendStatus(labels.separateFiles) }
    }

    public func finish(_ outcome: FeedbackOutcome) {
        composing = nil
        if let message = labels.message(for: outcome) { appendStatus(message) }
    }

    public func addressCopied() { status = labels.copied }

    private func appendStatus(_ message: String) {
        status = status.map { $0 + "\n" + message } ?? message
    }

    nonisolated static let temporaryFolderName = "AppFeedback"

    /// 앞서 남은 진단 파일을 지운다(앱이 중간에 꺼져 지우지 못한 것 포함). 앱을 시작할 때와 새 파일을 만들기 전에 부른다.
    nonisolated static func removeLeftovers(in root: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent == temporaryFolderName || item.lastPathComponent.hasPrefix(temporaryFolderName + "-") {
            try? fm.removeItem(at: item)
        }
    }

    /// Call when leaving settings, after any share sheet is dismissed. Only this session's file is removed.
    public func clearTemporaryFile() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        diagnosticsFile = nil
    }
}
