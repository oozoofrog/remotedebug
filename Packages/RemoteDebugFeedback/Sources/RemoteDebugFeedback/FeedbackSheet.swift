#if os(iOS) && !targetEnvironment(macCatalyst)
import MessageUI
import PhotosUI
import SwiftUI
import UIKit

/// 피드백 화면에 쓰는 문구. 기본값은 기기 언어를 따른다(한국어·영어·일본어·중국어 간체·번체, 그 밖에는 영어).
/// 앱의 문구로 바꾸려면 값을 넣는다. 넣은 값은 언어와 상관없이 그대로 보인다.
public struct RemoteDebugFeedbackLabels: Sendable {
    public var title = FeedbackStrings.text(.sheetTitle)
    public var prompt = FeedbackStrings.text(.sheetPrompt)
    public var attachments = FeedbackStrings.text(.sheetAttachments)
    public var attachPhoto = FeedbackStrings.text(.sheetAttachPhoto)
    public var attachFile = FeedbackStrings.text(.sheetAttachFile)
    public var removeAttachment = FeedbackStrings.text(.sheetRemoveAttachment)
    public var attachmentLimits = FeedbackStrings.text(.sheetAttachmentLimits, FeedbackFiles.maxCount, FeedbackStrings.megabytes(FeedbackFiles.maxBytes), FeedbackStrings.megabytes(FeedbackFiles.maxTotalBytes))
    public var tooManyAttachments = FeedbackStrings.text(.sheetTooManyAttachments, FeedbackFiles.maxCount)
    public var attachmentTooLarge = FeedbackStrings.text(.sheetAttachmentTooLarge, FeedbackStrings.megabytes(FeedbackFiles.maxBytes))
    public var attachmentsTooLarge = FeedbackStrings.text(.sheetAttachmentsTooLarge, FeedbackStrings.megabytes(FeedbackFiles.maxTotalBytes))
    public var attachmentUnreadable = FeedbackStrings.text(.sheetAttachmentUnreadable)
    public var includeLogs = FeedbackStrings.text(.sheetIncludeLogs)
    public var send = FeedbackStrings.text(.sheetSend)
    public var close = FeedbackStrings.text(.sheetClose)
    public var disclosure = FeedbackStrings.text(.sheetDisclosure)
    public var notConfigured = FeedbackStrings.text(.sheetNotConfigured)
    public var collectingLogs = FeedbackStrings.text(.sheetCollectingLogs)
    public var preparingMail = FeedbackStrings.text(.sheetPreparingMail)
    public var sent = FeedbackStrings.text(.sheetSent)
    public var mail = FeedbackLabels()
    /// 설정 화면에 두는 로그 기록 동의 스위치의 문구(`RemoteDebugFeedbackConsentSection(labels: labels.consent)`).
    public var consent = RemoteDebugFeedbackConsentLabels()
    #if DEBUG
    // Mac으로 보내는 길과 확인 목록은 개발 빌드에만 있어, 그 문구도 배포 빌드에 들어가지 않는다.
    // 그래서 이 문구의 번역은 묶음의 카탈로그가 아니라 `#if DEBUG` 안의 코드(`FeedbackDebugStrings`)에 있다.
    public var sendingToMac = FeedbackDebugStrings.text(.sendingToMac)
    public var saving = FeedbackDebugStrings.text(.saving)
    public var unreachable = FeedbackDebugStrings.text(.unreachable)
    public var sendByMail = FeedbackDebugStrings.text(.sendByMail)
    public var sendLater = FeedbackDebugStrings.text(.sendLater)
    public var saved = FeedbackDebugStrings.text(.saved)
    public var unansweredOnly = FeedbackDebugStrings.text(.unansweredOnly)
    public var resetChecks = FeedbackDebugStrings.text(.resetChecks)
    public var resetChecksConfirm = FeedbackDebugStrings.text(.resetChecksConfirm)
    public var checklist = FeedbackDebugStrings.text(.checklist)
    public var checklistFooter = FeedbackDebugStrings.text(.checklistFooter)
    public var unansweredChecks = FeedbackDebugStrings.text(.unansweredChecks)
    public var checkAnswer = FeedbackDebugStrings.text(.checkAnswer)
    public var noAnswer = FeedbackDebugStrings.text(.noAnswer)
    public var checkNote = FeedbackDebugStrings.text(.checkNote)
    public var checkPlace = FeedbackDebugStrings.text(.checkPlace)
    public var checkSteps = FeedbackDebugStrings.text(.checkSteps)
    public var checkExpect = FeedbackDebugStrings.text(.checkExpect)
    public var staleAnswer = FeedbackDebugStrings.text(.staleAnswer)
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
            // 이름과 동작을 한 글로 잇지 않는다. 말의 차례가 언어마다 달라서다.
            .accessibilityLabel(labels.removeAttachment)
            .accessibilityValue(file.name)
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
        // Mac으로 가는 기록의 글이라 기기 언어로 바꾸지 않는다(`RemoteDebugFeedback.report`의 설명).
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
                Text(FeedbackDebugStrings.text(.staleAnswerLine, labels.staleAnswer, shown(choice), stale.build))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Picker(labels.checkAnswer, selection: Binding(get: { answer.choice ?? "" },
                                                         set: { store.choose($0.isEmpty ? nil : $0, for: item) })) {
                Text(labels.noAnswer).tag("")
                // 고르는 값(tag)은 저장하고 보내는 글 그대로이고, 보이는 이름만 기기 언어를 따른다.
                ForEach(item.choices, id: \.self) { Text(shown($0)).tag($0) }
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
                Text(answer.choice.map(shown) ?? labels.noAnswer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .onAppear { note = answer.note }
    }

    private func shown(_ choice: String) -> String { FeedbackCheckItem.displayName(for: choice, labels: labels.mail) }

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
