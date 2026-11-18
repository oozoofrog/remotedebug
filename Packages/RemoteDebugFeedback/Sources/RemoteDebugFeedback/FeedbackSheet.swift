#if os(iOS) && !targetEnvironment(macCatalyst)
import MessageUI
import PhotosUI
import SwiftUI
import UIKit

/// 피드백 화면에 쓰는 문구. 앱의 언어에 맞게 바꿔 넣는다.
public struct RemoteDebugFeedbackLabels: Sendable {
    public var title = "피드백 보내기"
    public var prompt = "무엇이 문제인가요?"
    public var attachments = "첨부"
    public var attachPhoto = "사진 첨부"
    public var attachFile = "파일 첨부"
    public var removeAttachment = "빼기"
    public var attachmentLimits = "사진과 파일을 \(FeedbackFiles.maxCount)개까지 붙일 수 있습니다. 파일 하나는 1MB, 모두 합쳐 1.5MB까지이고 사진은 크기를 줄여 붙입니다."
    public var tooManyAttachments = "첨부는 \(FeedbackFiles.maxCount)개까지 붙일 수 있습니다."
    public var attachmentTooLarge = "1MB가 넘는 파일은 붙일 수 없습니다."
    public var attachmentsTooLarge = "첨부는 모두 합쳐 1.5MB까지 붙일 수 있습니다."
    public var attachmentUnreadable = "파일을 읽을 수 없습니다."
    public var includeLogs = "최근 로그 붙이기"
    public var send = "보내기"
    public var close = "닫기"
    public var disclosure = "앱 버전과 기기 종류가 함께 개발자에게 갑니다."
    public var notConfigured = "이 빌드는 피드백을 보낼 곳이 설정되지 않았습니다."
    public var collectingLogs = "로그를 모으는 중…"
    public var preparingMail = "메일을 준비하는 중…"
    public var sent = "보냈습니다."
    public var mail = FeedbackLabels()
    /// 설정 화면에 두는 로그 기록 동의 스위치의 문구(`RemoteDebugFeedbackConsentSection(labels: labels.consent)`).
    public var consent = RemoteDebugFeedbackConsentLabels()
    #if DEBUG
    // Mac으로 보내는 길과 확인 목록은 개발 빌드에만 있어, 그 문구도 배포 빌드에 들어가지 않는다.
    public var sendingToMac = "개발자의 Mac으로 보내는 중…"
    public var saving = "저장하는 중…"
    public var unreachable = "지금은 개발자의 Mac에 닿지 않습니다."
    public var sendByMail = "메일로 보내기"
    public var sendLater = "저장하고 나중에 보내기"
    public var saved = "저장해 두었습니다. RemoteDebug 앱의 VPN을 켜고 이 앱을 다시 열면 보냅니다."
    public var unansweredOnly = "답하지 않은 것만 보기"
    public var resetChecks = "답 모두 지우기"
    public var resetChecksConfirm = "이 기기에서 고른 답과 메모를 모두 지울까요?"
    public var checklist = "확인할 것"
    public var checklistFooter = "개발 빌드에만 보입니다. 고른 답은 피드백과 함께 갑니다."
    public var unansweredChecks = "아직 답하지 않은 것"
    public var checkAnswer = "답"
    public var noAnswer = "답 없음"
    public var checkNote = "메모(개인 정보는 적지 않습니다)"
    public var checkPlace = "어디서"
    public var checkSteps = "할 일"
    public var checkExpect = "보여야 하는 것"
    public var staleAnswer = "바뀌기 전 빌드에서 고른 답"
    #endif

    public init() {}

    func message(for refusal: FeedbackFiles.Refusal) -> String {
        switch refusal {
        case .tooMany: tooManyAttachments
        case .tooLarge: attachmentTooLarge
        case .totalTooLarge: attachmentsTooLarge
        case .unreadable: attachmentUnreadable
        }
    }
}

/// 피드백을 적어 보내는 화면. Debug 빌드는 Mac으로 바로 보내고, 닿지 않으면 메일이나 나중에 보내기를 고르게 한다. 배포 빌드는 메일로만 보낸다.
/// 화면을 저절로 찍지 않는다. 사진과 파일은 사용자가 고른 것만 붙는다. 글이 없어도 첨부, 로그, 확인 목록의 답이 있으면 보낼 수 있다.
public struct RemoteDebugFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var mail: FeedbackSession
    @State private var draft = FeedbackDraft()
    @State private var message = ""
    /// 붙일 사진과 파일. 보낼 때까지 메모리에만 두고 기기에 파일로 남기지 않는다.
    @State private var files = FeedbackFiles()
    @State private var attachNotice: String?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var picksFile = false
    #if DEBUG
    @StateObject private var checks = FeedbackCheckStore()
    /// "답하지 않은 것만 보기"를 켠 때에 이미 답이 있던 항목. 켠 뒤에 답한 항목은 메모를 적을 수 있게 그대로 보인다.
    @State private var hiddenChecks: Set<String>?
    @State private var asksReset = false
    /// 답을 지울 때마다 바꿔, 줄에 남은 메모 입력을 새로 그린다.
    @State private var resetCount = 0
    #endif
    // 배포판에서는 사용자가 켤 때만 로그를 붙인다.
    #if DEBUG
    @State private var includesLogs = true
    #else
    @State private var includesLogs = false
    #endif
    /// 지금 하고 있는 일. `nil`이면 쉬는 중이다.
    @State private var progress: String?
    @State private var collectedLogs: [String]?
    @State private var notice: String?
    @State private var asksRoute = false
    private let labels: RemoteDebugFeedbackLabels
    private let configuration: RemoteDebugFeedback.Configuration

    public init(labels: RemoteDebugFeedbackLabels = RemoteDebugFeedbackLabels()) {
        self.labels = labels
        let configuration = RemoteDebugFeedback.configuration
        self.configuration = configuration
        let draft = FeedbackDraft()
        let usageNotice = labels.mail.usageNotice
        _draft = State(initialValue: draft)
        _mail = StateObject(wrappedValue: FeedbackSession(recipient: configuration.email ?? "", appInfo: RemoteDebugFeedback.appInfo, labels: labels.mail) { info in
            FeedbackContent.standard(info, message: draft.message, usageNotice: usageNotice)
        })
    }

    private var hasMail: Bool { !(configuration.email ?? "").isEmpty }
    private var hasMac: Bool {
        #if DEBUG
        RemoteDebugFeedback.client != nil
        #else
        false
        #endif
    }
    private var hasKey: Bool { !(configuration.publicKeyBase64 ?? "").isEmpty }
    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 로그를 붙일 수 있는가: 기록이 허용돼 있고(배포 빌드에서는 사용자의 동의), 실어 보낼 길(Mac이나 암호화 키)이 있을 때.
    private var canAttachLogs: Bool { RemoteDebugFeedback.isRecordingAllowed && (hasMac || hasKey) }
    private var attachesLogs: Bool { includesLogs && canAttachLogs }
    /// 보낼 것이 있는가. 글이 없어도 첨부, 로그, 확인 목록의 답 가운데 하나가 있으면 보낸다.
    private var hasContent: Bool {
        var has = !trimmed.isEmpty || !files.items.isEmpty || attachesLogs
        #if DEBUG
        has = has || !checks.answeredIDs.isEmpty
        #endif
        return has
    }

    public var body: some View {
        NavigationStack {
            Form {
                #if DEBUG
                checklistSections
                #endif
                Section {
                    TextEditor(text: $message)
                        .frame(minHeight: 140)
                        .accessibilityLabel(labels.prompt)
                } header: {
                    Text(labels.prompt)
                }
                attachmentSection
                Section {
                    // 기록에 동의하지 않았으면 붙일 로그가 없으므로 스위치를 보이지 않는다.
                    if canAttachLogs { Toggle(labels.includeLogs, isOn: $includesLogs) }
                } footer: {
                    Text(hasMac || hasMail ? labels.disclosure : labels.notConfigured)
                }
                if let progress {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(progress)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else if let status = notice ?? mail.status {
                    Section { Text(status).font(.footnote) }
                }
            }
            .disabled(progress != nil)
            .navigationTitle(labels.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(labels.close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(labels.send) { Task { await send() } }
                        .disabled(progress != nil || !hasContent || !(hasMac || hasMail))
                }
            }
            #if DEBUG
            .confirmationDialog(labels.unreachable, isPresented: $asksRoute, titleVisibility: .visible) {
                if hasMail { Button(labels.sendByMail) { Task { await sendMail() } } }
                Button(labels.sendLater) { Task { await sendLater() } }
            }
            .confirmationDialog(labels.resetChecksConfirm, isPresented: $asksReset, titleVisibility: .visible) {
                Button(labels.resetChecks, role: .destructive) {
                    checks.reset()
                    hiddenChecks = hiddenChecks == nil ? nil : []
                    resetCount += 1
                }
            }
            #endif
            .sheet(item: $mail.composing) { mail in
                FeedbackMailComposer(mail: mail, onFinish: self.mail.finish).ignoresSafeArea()
            }
            .onChange(of: includesLogs) { _, _ in collectedLogs = nil }
            #if DEBUG
            .task {
                // Mac에 남겨 둔 목록이 있으면 그것으로 바꾼다. 닿지 않으면 마지막으로 받은 것이나 코드로 정한 것을 쓴다.
                guard let client = RemoteDebugFeedback.client,
                      let data = await client.fetchChecklist(bundleID: RemoteDebugFeedback.bundleID) else { return }
                checks.apply(remote: data)
            }
            #endif
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                Task {
                    attachNotice = nil
                    for item in items {
                        guard let data = try? await item.loadTransferable(type: Data.self) else {
                            attachNotice = labels.attachmentUnreadable
                            continue
                        }
                        attach { (files: inout FeedbackFiles) throws(FeedbackFiles.Refusal) in try files.addImage(data) }
                    }
                }
            }
            .fileImporter(isPresented: $picksFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                attachNotice = nil
                for url in (try? result.get()) ?? [] {
                    attach { (files: inout FeedbackFiles) throws(FeedbackFiles.Refusal) in try files.addFile(at: url) }
                }
            }
        }
    }

    #if DEBUG
    @ViewBuilder private var checklistSections: some View {
        if !checks.items.isEmpty {
            Section {
                LabeledContent(labels.unansweredChecks, value: "\(checks.unansweredCount)/\(checks.items.count)")
                Toggle(labels.unansweredOnly, isOn: Binding(get: { hiddenChecks != nil },
                                                            set: { hiddenChecks = $0 ? checks.answeredIDs : nil }))
                Button(labels.resetChecks, role: .destructive) { asksReset = true }
                    .disabled(checks.answers.isEmpty)
            } header: {
                Text(labels.checklist)
            } footer: {
                Text(labels.checklistFooter)
            }
            ForEach(checks.stages(hiding: hiddenChecks ?? []), id: \.title) { stage in
                Section {
                    ForEach(stage.items) { item in
                        FeedbackCheckRow(item: item, store: checks, labels: labels)
                            .id("\(item.id)#\(resetCount)")
                    }
                } header: {
                    if !stage.title.isEmpty { Text(stage.title) }
                }
            }
        }
    }
    #endif

    private var attachmentSection: some View {
        Section {
            ForEach(files.items) { file in fileRow(file) }
            PhotosPicker(selection: $pickedPhotos, maxSelectionCount: max(1, FeedbackFiles.maxCount - files.items.count),
                         matching: .images) {
                Label(labels.attachPhoto, systemImage: "photo")
            }
            .disabled(files.isFull)
            Button {
                picksFile = true
            } label: {
                Label(labels.attachFile, systemImage: "paperclip")
            }
            .disabled(files.isFull)
        } header: {
            Text(labels.attachments)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(labels.attachmentLimits)
                if let attachNotice { Text(attachNotice).foregroundStyle(.red) }
            }
        }
    }

    private func fileRow(_ file: FeedbackFile) -> some View {
        HStack(spacing: 10) {
            if file.isImage, let preview = UIImage(data: file.data) {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc")
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text(Int64(file.data.count).formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                files.remove(file.id)
                attachNotice = nil
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(file.name) \(labels.removeAttachment)")
        }
    }

    /// 한도 안이면 붙이고, 아니면 까닭을 알린다.
    private func attach(_ add: (inout FeedbackFiles) throws(FeedbackFiles.Refusal) -> Void) {
        do throws(FeedbackFiles.Refusal) {
            try add(&files)
        } catch {
            attachNotice = labels.message(for: error)
        }
    }

    /// 붙일 로그. 한 번 모은 것은 이 화면에서 다시 모으지 않는다.
    private func logLines() async -> [String] {
        guard attachesLogs else { return [] }
        if let collectedLogs { return collectedLogs }
        progress = labels.collectingLogs
        let lines = await Task.detached { FeedbackLog.shared.collect() }.value
        collectedLogs = lines
        return lines
    }

    #if DEBUG
    private func report() async -> FeedbackReport {
        let lines = await logLines()
        let details = lines.isEmpty ? "" : "\n최근 로그\n" + lines.joined(separator: "\n")
        var report = RemoteDebugFeedback.report(message: trimmed, details: details, attachments: files.items, date: Date())
        if !checks.items.isEmpty { report.checks = checks.reportChecks }
        return report
    }
    #endif

    private func send() async {
        notice = nil
        #if DEBUG
        guard let client = RemoteDebugFeedback.client else {
            await sendMail()
            return
        }
        let report = await report()
        progress = labels.sendingToMac
        let delivered = await client.trySend(report)
        progress = nil
        if delivered {
            dismiss()
        } else {
            asksRoute = true
        }
        #else
        await sendMail()
        #endif
    }

    #if DEBUG
    private func sendLater() async {
        guard let client = RemoteDebugFeedback.client else { return }
        let report = await report()
        progress = labels.saving
        let delivered = await client.submit(report)
        progress = nil
        if delivered {
            dismiss()
        } else {
            notice = labels.saved
            message = ""
            files = FeedbackFiles()
        }
    }
    #endif

    private func sendMail() async {
        draft.message = trimmed
        // 사용자가 고른 사진과 파일은 메일에 그대로 붙인다. 로그만 암호화한 진단 파일에 넣는다.
        mail.files = files.items
        var hasDiagnostics = attachesLogs
        #if DEBUG
        // 확인 목록의 답은 메일에서는 암호화한 진단 파일에 넣는다.
        mail.checklist = checks.mailChecks
        hasDiagnostics = hasDiagnostics || !checks.items.isEmpty
        #endif
        if let key = configuration.publicKeyBase64, !key.isEmpty, hasDiagnostics {
            let lines = await logLines()
            // 어느 빌드에서 온 것인지 진단 파일만 받아도 알 수 있게 앱·기기 정보를 함께 넣는다. 개인을 가리키는 값은 없다.
            let info = mail.appInfo
            let app = ["bundleId": info.bundleID, "name": info.name, "version": info.version, "build": info.build,
                       "os": info.system, "device": info.device]
            mail.diagnostics = FeedbackDiagnostics(publicKeyBase64: key, disclosure: labels.disclosure) {
                try JSONSerialization.data(withJSONObject: ["logs": lines, "app": app])
            }
            mail.attachesDiagnostics = true
        } else {
            mail.diagnostics = nil
        }
        progress = labels.preparingMail
        let url = await mail.prepare(canSendMail: MFMailComposeViewController.canSendMail())
        progress = nil
        if let url { openURL(url) { mail.openedMailLink(accepted: $0) } }
    }
}

#if DEBUG
/// 확인할 것 한 줄: 펼치면 어디서·할 일·보여야 하는 것이 보이고, 답을 고르고 메모를 적는다.
private struct FeedbackCheckRow: View {
    let item: FeedbackCheckItem
    @ObservedObject var store: FeedbackCheckStore
    let labels: RemoteDebugFeedbackLabels
    @State private var note = ""

    var body: some View {
        let answer = store.answer(for: item)
        DisclosureGroup {
            if !item.place.isEmpty { detail(labels.checkPlace, item.place) }
            if !item.steps.isEmpty { detail(labels.checkSteps, item.steps) }
            if !item.expect.isEmpty { detail(labels.checkExpect, item.expect.map { "• " + $0 }.joined(separator: "\n")) }
            if let stale = store.staleAnswer(for: item), let choice = stale.choice {
                Text("\(labels.staleAnswer): \(choice) (\(stale.build))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Picker(labels.checkAnswer, selection: Binding(get: { answer.choice ?? "" },
                                                         set: { store.choose($0.isEmpty ? nil : $0, for: item) })) {
                Text(labels.noAnswer).tag("")
                ForEach(item.choices, id: \.self) { Text($0).tag($0) }
            }
            TextField(labels.checkNote, text: $note, axis: .vertical)
                .lineLimit(1...4)
                .onChange(of: note) { _, text in store.setNote(text, for: item) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: answer.choice == nil ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(answer.choice == nil ? Color.secondary : Color.accentColor)
                    .accessibilityHidden(true)
                Text(item.title)
                Spacer()
                Text(answer.choice ?? labels.noAnswer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .onAppear { note = answer.note }
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif

/// 메일 본문에 넣을 글을 세션의 `content` 클로저에 넘기는 상자.
@MainActor
final class FeedbackDraft {
    var message = ""
}

private struct FeedbackPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let labels: RemoteDebugFeedbackLabels

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                RemoteDebugFeedbackSheet(labels: labels)
            }
    }
}

public extension View {
    /// `isPresented`가 참이 되면 피드백 화면을 띄운다.
    func remoteDebugFeedback(isPresented: Binding<Bool>, labels: RemoteDebugFeedbackLabels = RemoteDebugFeedbackLabels()) -> some View {
        modifier(FeedbackPresenter(isPresented: isPresented, labels: labels))
    }
}
#endif
