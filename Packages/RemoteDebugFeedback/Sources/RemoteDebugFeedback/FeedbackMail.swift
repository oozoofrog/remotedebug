import Foundation

public struct FeedbackAppInfo: Equatable, Sendable {
    public let name: String
    public let version: String
    public let build: String
    /// OS name and version, for example `iOS 18.1`.
    public let system: String
    /// Device kind (model identifier such as `iPhone16,2`). Never the name the user gave the device.
    public let device: String
    /// Bundle identifier. Goes into the search tag line; empty leaves the tag out.
    public let bundleID: String

    public init(name: String, version: String, build: String, system: String, device: String, bundleID: String = "") {
        self.name = name
        self.version = version
        self.build = build
        self.system = system
        self.device = device
        self.bundleID = bundleID
    }
}

public struct FeedbackContent: Equatable, Sendable {
    public let subject: String
    public let body: String

    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }

    /// The line under the separator that says what the information below is for. Replace it with localized copy.
    public static let defaultUsageNotice = "The information below is used only to look into this problem and may be deleted."

    public static func standard(_ info: FeedbackAppInfo) -> Self {
        standard(info, message: "", usageNotice: defaultUsageNotice)
    }

    /// User text first, then a separator, one line on how the information is used, app version with build,
    /// OS, device kind, and a search tag. Carries no personal values.
    public static func standard(_ info: FeedbackAppInfo, message: String, usageNotice: String) -> Self {
        var body = "\(message)\n\n\n---\n"
        if !usageNotice.isEmpty { body += usageNotice + "\n" }
        body += "App: \(info.name) \(info.version) (\(info.build))\nOS: \(info.system)\nDevice: \(info.device)"
        if let tag = searchTag(bundleID: info.bundleID, build: info.build) { body += "\n" + tag }
        return Self(subject: "\(info.name) feedback", body: body)
    }

    /// A stable line for mailbox search, `[rdfeedback:<bundle id>:<build>]`. The subject may be localized; this never is.
    /// Search `"[rdfeedback:<bundle id>:"` for every build of one app. `nil` without a bundle identifier.
    public static func searchTag(bundleID: String, build: String) -> String? {
        func safe(_ text: String) -> String {
            String(text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_") }.map(Character.init))
        }
        let id = safe(bundleID)
        guard !id.isEmpty else { return nil }
        return "[rdfeedback:\(id):\(safe(build))]"
    }
}

/// Only the Debug encryption path can construct an attachment.
public struct FeedbackAttachment: Equatable, Sendable {
    public let data: Data
    public let fileName: String
    public static let mimeType = "application/octet-stream"

    init(encryptedData: Data) {
        data = encryptedData
        fileName = "feedback-\(UUID().uuidString).afdiag"
    }
}

public struct FeedbackMail: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let recipient: String
    public let content: FeedbackContent
    public let attachment: FeedbackAttachment?
    /// Photos and files the user chose. Attached as they are; the user sees them in the compose sheet.
    public let files: [FeedbackFile]
    public let attachmentNotice: String

    public init(recipient: String, content: FeedbackContent,
                attachment: FeedbackAttachment? = nil, files: [FeedbackFile] = [],
                attachmentNotice: String = "Encrypted diagnostics attached.") {
        self.files = files
        self.recipient = recipient
        self.content = content
        self.attachment = attachment
        self.attachmentNotice = attachmentNotice
    }

    public var body: String {
        content.body + (attachment == nil ? "" : "\n" + attachmentNotice)
    }

    /// mailto cannot carry attachments, so it must not claim one is attached.
    public var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [URLQueryItem(name: "subject", value: content.subject),
                                 URLQueryItem(name: "body", value: content.body)]
        // Some mail handlers decode '+' as a space even outside form submissions.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

/// A composer handoff is not confirmation of delivery.
public enum FeedbackOutcome: Equatable, Sendable {
    case handedOff, savedDraft, cancelled, failed
}

/// Replace these strings with the host app's localized copy.
public struct FeedbackLabels: Sendable {
    public var title = "Feedback"
    public var write = "Write feedback email"
    public var collecting = "Collecting diagnostics"
    public var attach = "Attach encrypted diagnostics"
    public var share = "Share encrypted diagnostics"
    public var copyAddress = "Copy email address"
    public var copied = "Email address copied."
    public var unavailable = "Email is unavailable. Copy the address and use another email app."
    public var separateAttachment = "Email links cannot attach files. Share the encrypted file separately."
    public var collectionFailed = "Diagnostics could not be prepared. Continuing without an attachment."
    public var separateFiles = "Email links cannot attach files. Add your photos and files in your email app."
    public var shareFailed = "The encrypted file could not be prepared for sharing."
    public var attachmentNotice = "Encrypted diagnostics attached."
    /// The line in the mail body that says what the app and device information is for.
    public var usageNotice = FeedbackContent.defaultUsageNotice
    public var handedOff = "Email handed to Mail. Delivery cannot be confirmed here."
    public var savedDraft = "Draft saved. It has not been sent."
    public var failed = "Email could not be sent. Copy the address and use another email app."
    public var checklist = "Checks"
    public var unchecked = "Not checked"
    public var passed = "Passed"
    public var failedCheck = "Failed"
    public var untested = "Could not test"
    public var note = "Note (do not include personal information)"

    public init() {}

    public func message(for outcome: FeedbackOutcome) -> String? {
        switch outcome {
        case .handedOff: handedOff
        case .savedDraft: savedDraft
        case .cancelled: nil
        case .failed: failed
        }
    }
}
