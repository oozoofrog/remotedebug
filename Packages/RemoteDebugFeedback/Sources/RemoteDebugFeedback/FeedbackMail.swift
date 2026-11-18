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

    /// The line under the separator that says what the information below is for, in the device language.
    public static var defaultUsageNotice: String { FeedbackStrings.text(.mailUsageNotice) }

    public static func standard(_ info: FeedbackAppInfo) -> Self {
        standard(info, message: "", usageNotice: defaultUsageNotice)
    }

    /// User text first, then a separator, one line on how the information is used, app version with build,
    /// OS, device kind, and a search tag. Carries no personal values.
    ///
    /// The subject and the usage notice follow the device language. The field labels `App:`, `OS:`, `Device:` and the
    /// tag line are fixed ASCII in every language, so mailbox search and any tool that reads the body keep working.
    public static func standard(_ info: FeedbackAppInfo, message: String, usageNotice: String) -> Self {
        var body = "\(message)\n\n\n---\n"
        if !usageNotice.isEmpty { body += usageNotice + "\n" }
        // 줄 이름 `App:`, `OS:`, `Device:`와 표시 줄은 번역하지 않는다. 메일함 검색과 본문을 읽는 도구가 이 글자에 기댄다.
        body += "App: \(info.name) \(info.version) (\(info.build))\nOS: \(info.system)\nDevice: \(info.device)"
        if let tag = searchTag(bundleID: info.bundleID, build: info.build) { body += "\n" + tag }
        return Self(subject: FeedbackStrings.text(.mailSubject, info.name), body: body)
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
                attachmentNotice: String = FeedbackLabels().attachmentNotice) {
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

/// The defaults follow the device language (Korean, English, Japanese, Simplified and Traditional Chinese; English
/// otherwise) and come from this package's own string catalog. Assign a property to use the host app's copy instead.
public struct FeedbackLabels: Sendable {
    public var title = FeedbackStrings.text(.mailTitle)
    public var write = FeedbackStrings.text(.mailWrite)
    public var collecting = FeedbackStrings.text(.mailCollecting)
    public var attach = FeedbackStrings.text(.mailAttach)
    public var share = FeedbackStrings.text(.mailShare)
    public var copyAddress = FeedbackStrings.text(.mailCopyAddress)
    public var copied = FeedbackStrings.text(.mailCopied)
    public var unavailable = FeedbackStrings.text(.mailUnavailable)
    public var separateAttachment = FeedbackStrings.text(.mailSeparateAttachment)
    public var collectionFailed = FeedbackStrings.text(.mailCollectionFailed)
    public var separateFiles = FeedbackStrings.text(.mailSeparateFiles)
    public var shareFailed = FeedbackStrings.text(.mailShareFailed)
    public var attachmentNotice = FeedbackStrings.text(.mailAttachmentNotice)
    /// The line in the mail body that says what the app and device information is for.
    public var usageNotice = FeedbackContent.defaultUsageNotice
    public var handedOff = FeedbackStrings.text(.mailHandedOff)
    public var savedDraft = FeedbackStrings.text(.mailSavedDraft)
    public var failed = FeedbackStrings.text(.mailFailed)
    public var checklist = FeedbackStrings.text(.mailChecklist)
    public var unchecked = FeedbackStrings.text(.mailUnchecked)
    public var passed = FeedbackStrings.text(.mailPassed)
    public var failedCheck = FeedbackStrings.text(.mailFailedCheck)
    public var untested = FeedbackStrings.text(.mailUntested)
    public var note = FeedbackStrings.text(.mailNote)

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
