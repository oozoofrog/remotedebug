import Foundation

/// 에이전트가 개발 빌드의 사용자에게 남기는 확인 목록(docs/protocol-addenda.md L.4). 앱 하나(번들 ID)에 하나다.
/// `RemoteDebugFeedback`을 넣은 앱의 Debug 빌드가 피드백 화면을 열 때 받아 가고, 답은 피드백과 함께 돌아온다.
public struct FeedbackChecklist: Codable, Sendable, Hashable {
    /// 확인할 것 하나: 어디서, 무엇을 하고, 무엇이 보여야 하는지와 고를 답.
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        /// 어디서(기기와 화면).
        public var place: String?
        /// 할 일.
        public var steps: String?
        /// 보여야 하는 것.
        public var expect: [String]
        /// 고를 답. 주지 않으면 `통과`, `실패`, `확인 못함`.
        public var choices: [String]
        /// 이 항목이 바뀐 빌드 번호. 그보다 앞선 빌드에서 고른 답은 세지 않는다.
        public var since: Int?
        /// 묶음 이름. 같은 이름끼리 모아 보인다.
        public var stage: String?
    }

    public var bundleId: String
    public var updatedAt: Date
    public var items: [Item]

    public init(bundleId: String, updatedAt: Date, items: [Item]) {
        self.bundleId = bundleId
        self.updatedAt = updatedAt
        self.items = items
    }

    /// 목록 하나의 항목 수 한도.
    public static let maxItems = 50
    /// 항목 하나의 답 수 한도(2개부터).
    public static let maxChoices = 6
    /// 항목 하나의 `expect` 줄 수 한도.
    public static let maxExpect = 10
    /// 해 보지 못했다는 답. 실패와도, 아직 답하지 않은 것과도 다르다.
    public static let untestedChoice = "확인 못함"
    public static let defaultChoices = ["통과", "실패", untestedChoice]
    /// 글자 수 한도.
    public static let maxIDLength = 64, maxTitleLength = 200, maxPlaceLength = 200, maxStepsLength = 2000
    public static let maxExpectLength = 300, maxChoiceLength = 40, maxStageLength = 80

    /// 받아들일 수 없는 목록. `message`가 고칠 곳을 알려 준다.
    public struct Invalid: Error, Equatable, Sendable {
        public var message: String
    }

    /// 번들 ID로 쓸 수 있는 글자(영문, 숫자, 점, 붙임표)이고 255바이트 이하인가. 파일 이름과 주소에 그대로 쓴다.
    public static func isValidBundleID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 255 && !text.hasPrefix(".") && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45
        }
    }

    /// 저장 폴더: 호스트 저장 폴더(게시 폴더의 부모) 아래 `FeedbackChecklists/`.
    public static func directory(publishDirectory: String) -> URL {
        URL(fileURLWithPath: publishDirectory, isDirectory: true).deletingLastPathComponent()
            .appendingPathComponent("FeedbackChecklists", isDirectory: true)
    }

    /// 번들 ID의 목록 파일. `bundleId`는 `isValidBundleID`를 지난 것이어야 한다.
    public static func file(bundleId: String, publishDirectory: String) -> URL {
        directory(publishDirectory: publishDirectory).appendingPathComponent(bundleId + ".json")
    }

    /// 에이전트가 준 JSON(항목 배열이나 `{"items":[…]}`)에서 목록을 만든다. 한도를 넘는 것은 자르지 않고 거절한다.
    public static func make(bundleId: String, json: Data, now: Date) throws(Invalid) -> FeedbackChecklist {
        guard isValidBundleID(bundleId) else { throw Invalid(message: "번들 ID가 올바르지 않습니다: \(bundleId)") }
        let parsed = try? JSONSerialization.jsonObject(with: json)
        guard let raw = parsed as? [Any] ?? (parsed as? [String: Any])?["items"] as? [Any] else {
            throw Invalid(message: "항목 배열이나 {\"items\": […]} 모양의 JSON이 필요합니다.")
        }
        guard !raw.isEmpty, raw.count <= maxItems else { throw Invalid(message: "항목은 1~\(maxItems)개여야 합니다(지금 \(raw.count)개). 비우려면 clear를 쓰세요.") }
        var items: [Item] = []
        for (index, value) in raw.enumerated() {
            guard let object = value as? [String: Any] else { throw Invalid(message: "항목 \(index + 1)이 객체가 아닙니다.") }
            func text(_ key: String, max: Int, required: Bool = false) throws(Invalid) -> String? {
                guard let value = object[key], !(value is NSNull) else {
                    if required { throw Invalid(message: "항목 \(index + 1)에 \(key)가 없습니다.") }
                    return nil
                }
                guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw Invalid(message: "항목 \(index + 1)의 \(key)가 문자열이 아닙니다.")
                }
                guard string.count <= max else { throw Invalid(message: "항목 \(index + 1)의 \(key)가 \(max)자를 넘습니다.") }
                if string.isEmpty && required { throw Invalid(message: "항목 \(index + 1)의 \(key)가 비어 있습니다.") }
                return string.isEmpty ? nil : string
            }
            func list(_ key: String, maxCount: Int, maxLength: Int) throws(Invalid) -> [String] {
                guard let value = object[key], !(value is NSNull) else { return [] }
                guard let strings = value as? [String] else { throw Invalid(message: "항목 \(index + 1)의 \(key)가 문자열 배열이 아닙니다.") }
                let trimmed = strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard trimmed.count <= maxCount else { throw Invalid(message: "항목 \(index + 1)의 \(key)는 \(maxCount)개까지입니다.") }
                guard trimmed.allSatisfy({ !$0.isEmpty && $0.count <= maxLength }) else {
                    throw Invalid(message: "항목 \(index + 1)의 \(key)는 비어 있지 않고 \(maxLength)자 이하여야 합니다.")
                }
                return trimmed
            }
            let id = try text("id", max: maxIDLength, required: true) ?? ""
            guard id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }) else {
                throw Invalid(message: "항목 \(index + 1)의 id는 영문, 숫자, 점, 밑줄, 붙임표만 씁니다: \(id)")
            }
            guard !items.contains(where: { $0.id == id }) else { throw Invalid(message: "id가 겹칩니다: \(id)") }
            var choices = try list("choices", maxCount: maxChoices, maxLength: maxChoiceLength)
            if choices.isEmpty { choices = defaultChoices }
            guard choices.count >= 2, Set(choices).count == choices.count else {
                throw Invalid(message: "항목 \(index + 1)의 choices는 서로 다른 답 2~\(maxChoices)개여야 합니다.")
            }
            var since: Int?
            if let value = object["since"], !(value is NSNull) {
                guard let number = value as? Int, number >= 0 else { throw Invalid(message: "항목 \(index + 1)의 since는 0 이상의 빌드 번호(정수)여야 합니다.") }
                since = number == 0 ? nil : number
            }
            items.append(Item(id: id, title: try text("title", max: maxTitleLength, required: true) ?? "",
                              place: try text("place", max: maxPlaceLength), steps: try text("steps", max: maxStepsLength),
                              expect: try list("expect", maxCount: maxExpect, maxLength: maxExpectLength),
                              choices: choices, since: since, stage: try text("stage", max: maxStageLength)))
        }
        return FeedbackChecklist(bundleId: bundleId, updatedAt: now, items: items)
    }
}

extension CrashReport {
    /// 확인 목록의 항목 하나에 사용자가 고른 답. 피드백과 함께 온다(JSON의 `checks`).
    public struct Check: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        /// 고른 답. 아직 고르지 않았으면 빈 글자.
        public var answer: String
        public var note: String
        /// 답을 고른 빌드 번호.
        public var build: String
        /// 답을 고른 시각(ISO-8601). 고르지 않았으면 빈 글자.
        public var answeredAt: String

        public init(id: String, title: String, answer: String = "", note: String = "", build: String = "", answeredAt: String = "") {
            self.id = id
            self.title = title
            self.answer = answer
            self.note = note
            self.build = build
            self.answeredAt = answeredAt
        }

        enum CodingKeys: String, CodingKey { case id, title, answer, note, build, answeredAt }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            build = try c.decodeIfPresent(String.self, forKey: .build) ?? ""
            answeredAt = try c.decodeIfPresent(String.self, forKey: .answeredAt) ?? ""
        }
    }

    /// 사람과 에이전트가 읽을 답 목록. 답이 없으면 빈 글자.
    public static func checksText(_ checks: [Check]) -> String {
        guard !checks.isEmpty else { return "" }
        let answered = checks.filter { !$0.answer.isEmpty }.count
        var lines = ["확인 목록의 답 (\(answered)/\(checks.count)개 답함)"]
        for check in checks {
            var line = "- [\(check.answer.isEmpty ? "답 없음" : check.answer)] \(check.id): \(check.title)"
            if !check.answer.isEmpty {
                let detail = [check.build.isEmpty ? "" : "빌드 \(check.build)", check.answeredAt].filter { !$0.isEmpty }.joined(separator: ", ")
                if !detail.isEmpty { line += " (\(detail))" }
            }
            if !check.note.isEmpty { line += "\n  메모: \(check.note.replacingOccurrences(of: "\n", with: " "))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
