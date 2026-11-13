#if os(iOS) && !targetEnvironment(macCatalyst)
import MessageUI
import SwiftUI
import UIKit

extension FeedbackOutcome {
    init(_ result: MFMailComposeResult, failed: Bool) {
        guard !failed else { self = .failed; return }
        switch result {
        case .sent: self = .handedOff
        case .saved: self = .savedDraft
        case .cancelled: self = .cancelled
        default: self = .failed
        }
    }
}

struct FeedbackMailComposer: UIViewControllerRepresentable {
    let mail: FeedbackMail
    let onFinish: (FeedbackOutcome) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([mail.recipient])
        controller.setSubject(mail.content.subject)
        controller.setMessageBody(mail.body, isHTML: false)
        #if DEBUG
        if let attachment = mail.attachment {
            controller.addAttachmentData(attachment.data, mimeType: FeedbackAttachment.mimeType,
                                         fileName: attachment.fileName)
        }
        #endif
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (FeedbackOutcome) -> Void
        init(onFinish: @escaping (FeedbackOutcome) -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(FeedbackOutcome(result, failed: error != nil))
        }
    }
}
#endif
