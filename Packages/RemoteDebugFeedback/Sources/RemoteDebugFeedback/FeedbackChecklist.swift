#if DEBUG
import Combine
import Foundation

// 개발 빌드에만 있는 확인 목록. 에이전트나 개발자가 "이번 빌드에서 확인할 것"과 고를 답을 남기면,
// 사용자가 피드백 화면에서 답을 고르고 그 답이 피드백과 함께 간다. 배포 빌드에는 이 파일의 어떤 것도 들어가지 않는다.

/// 확인할 것 하나: 어디서, 무엇을 하고, 무엇이 보여야 하는지와 고를 답.
public struct FeedbackCheckItem: Codable, Identifiable, Equatable, Sendable {
    /// 해 보지 못했다는 답. 실패와도, 아직 답하지 않은 것과도 다르다.
    public static let untestedChoice = "확인 못함"
    public static let defaultChoices = ["통과", "실패", untestedChoice]

    public var id: String
    public var title: String
    /// 어디서(기기와 화면).
    public var place: String
    /// 할 일.
    public var steps: String
    /// 보여야 하는 것.
    public var expect: [String]
    /// 고를 답.
    public var choices: [String]
    /// 이 항목이 바뀐 빌드 번호. 그보다 앞선 빌드에서 고른 답은 세지 않아, 다시 답하지 않은 것으로 보인다. 0이면 모든 답을 센다.
    public var since: Int
    /// 묶음 이름. 같은 이름끼리 모아 보인다.
    public var stage: String

    public init(_ id: String, _ title: String, at place: String = "", do steps: String = "", expect: [String] = [],
                choices: [String] = FeedbackCheckItem.defaultChoices, since: Int = 0, stage: String = "") {
        self.id = id
        self.title = title
        self.place = place
        self.steps = steps
        self.expect = expect
        self.choices = choices
        self.since = since
        self.stage = stage
    }

    enum CodingKeys: String, CodingKey { case id, title, place, steps, expect, choices, since, stage }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
        steps = try c.decodeIfPresent(String.self, forKey: .steps) ?? ""
        expect = try c.decodeIfPresent([String].self, forKey: .expect) ?? []
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? Self.defaultChoices
        since = try c.decodeIfPresent(Int.self, forKey: .since) ?? 0
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
    }

    /// 화면과 저장이 끝없이 커지지 않게 줄인 항목.
    var bounded: FeedbackCheckItem {
        var item = self
        item.id = String(id.prefix(64))
        item.title = String(title.prefix(200))
        item.place = String(place.prefix(200))
        item.steps = String(steps.prefix(2000))
        item.expect = expect.prefix(10).map { String($0.prefix(300)) }
        item.choices = choices.prefix(FeedbackCheckStore.maxChoices).map { String($0.prefix(40)) }.filter { !$0.isEmpty }
        if item.choices.count < 2 { item.choices = Self.defaultChoices }
        item.stage = String(stage.prefix(80))
        return item
    }
}

public extension RemoteDebugFeedback {
    /// 앱이 코드로 정해 두는 확인 목록(Debug 빌드 전용). Mac에 닿지 않아도 보인다.
    /// 개발자의 Mac에서 에이전트가 이 앱의 목록을 남겼으면 그것이 대신 보인다.
    ///
    /// ```swift
    /// #if DEBUG
    /// RemoteDebugFeedback.checklist = [
    ///     .init("pay.sheet", "결제 화면이 열린다", at: "설정 › 결제", do: "결제 단추를 누른다", expect: ["금액이 보임"], since: 59),
    /// ]
    /// #endif
    /// ```
    static var checklist: [FeedbackCheckItem] {
        get { withState { $0.checklist } }
        set { withState { $0.checklist = newValue } }
    }
}

/// 확인 목록과 이 기기에서 고른 답. 답은 지금 목록에 있는 항목 것만 파일 하나에 남긴다.
@MainActor
final class FeedbackCheckStore: ObservableObject {
    struct Answer: Codable, Equatable, Sendable {
        var choice: String?
        var note = ""
        /// 답을 고른 빌드 번호. 뒤 빌드에서 바뀐 항목은 이 답을 물려받지 않는다.
        var build = ""
        var answeredAt: Date?

        var isEmpty: Bool { choice == nil && note.isEmpty }
    }

    /// 목록 하나의 항목 수 한도. 넘는 항목은 버린다.
    nonisolated static let maxItems = 50
    nonisolated static let maxChoices = 6
    /// 메모 글자 수 한도.
    nonisolated static let noteLimit = 200
    /// Mac에서 받는 목록의 크기 한도(바이트). 넘으면 받지 않는다.
    nonisolated static let maxResponseBytes = 512 << 10

    @Published private(set) var items: [FeedbackCheckItem] = []
    @Published private(set) var answers: [String: Answer] = [:]
    private let directory: URL?
    private let build: String
    private let declared: [FeedbackCheckItem]
    private let now: () -> Date

    /// 앱 데이터 폴더의 기본 위치. 파일은 `answers.json`과 Mac에서 받은 `checklist.json` 둘뿐이다.
    nonisolated static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RemoteDebugFeedbackChecks", isDirectory: true)
    }

    /// `directory`가 `nil`이면 메모리에만 둔다(시험).
    init(directory: URL? = FeedbackCheckStore.defaultDirectory(), build: String = RemoteDebugFeedback.buildNumber,
         declared: [FeedbackCheckItem] = RemoteDebugFeedback.checklist, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.build = build
        self.declared = declared
        self.now = now
        let cached = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("checklist.json")) }.flatMap(Self.parse) ?? []
        items = Self.bounded(cached.isEmpty ? declared : cached)
        answers = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("answers.json")) }
            .flatMap { try? JSONDecoder().decode([String: Answer].self, from: $0) } ?? [:]
        prune()
    }

    private static func parse(_ data: Data) -> [FeedbackCheckItem]? {
        struct Body: Decodable { var items: [FeedbackCheckItem] }
        return (try? JSONDecoder().decode(Body.self, from: data))?.items
    }

    private static func bounded(_ items: [FeedbackCheckItem]) -> [FeedbackCheckItem] {
        var seen: Set<String> = []
        return items.map(\.bounded).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.prefix(maxItems).map { $0 }
    }

    /// Mac이 준 목록(`{"items":[…]}`)을 받아들인다. 비어 있으면 코드로 정한 목록으로 돌아간다. 읽을 수 없으면 그대로 둔다.
    func apply(remote data: Data) {
        guard data.count <= Self.maxResponseBytes, let remote = Self.parse(data).map(Self.bounded) else { return }
        if let directory {
            let file = directory.appendingPathComponent("checklist.json")
            if remote.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else if let cache = try? JSONEncoder().encode(["items": remote]) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? cache.write(to: file, options: .atomic)
            }
        }
        items = remote.isEmpty ? Self.bounded(declared) : remote
        prune()
    }

    /// 지금 목록에 없는 항목의 답을 지운다. 목록이 바뀔 때마다 부른다.
    private func prune() {
        let ids = Set(items.map(\.id))
        let kept = answers.filter { ids.contains($0.key) }
        guard kept.count != answers.count else { return }
        answers = kept
        save()
    }

    private func save() {
        guard let directory else { return }
        let file = directory.appendingPathComponent("answers.json")
        guard !answers.isEmpty, let data = try? JSONEncoder().encode(answers) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// 지금 세는 답. 항목의 `since`보다 앞선 빌드에서 고른 답은 세지 않는다.
    func answer(for item: FeedbackCheckItem) -> Answer {
        staleAnswer(for: item) == nil ? answers[item.id] ?? Answer() : Answer()
    }

    /// 항목이 바뀌기 전에 고른 답. 그때 무엇을 봤는지 보여 주려고 남긴다.
    func staleAnswer(for item: FeedbackCheckItem) -> Answer? {
        guard let answer = answers[item.id], answer.choice != nil, (Int(answer.build) ?? 0) < item.since else { return nil }
        return answer
    }

    func choose(_ choice: String?, for item: FeedbackCheckItem) {
        update(item) { $0.choice = choice.flatMap { item.choices.contains($0) ? $0 : nil } }
    }

    /// 고른 답과 메모를 모두 지운다.
    func reset() {
        guard !answers.isEmpty else { return }
        answers = [:]
        save()
    }

    func setNote(_ note: String, for item: FeedbackCheckItem) {
        guard note != answer(for: item).note else { return }
        update(item) { $0.note = String(note.prefix(Self.noteLimit)) }
    }

    private func update(_ item: FeedbackCheckItem, _ change: (inout Answer) -> Void) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        var answer = answer(for: item)
        change(&answer)
        answer.build = build
        answer.answeredAt = now()
        answers[item.id] = answer.isEmpty ? nil : answer
        save()
    }

    /// 답을 고르지 않은 항목 수. 메모만 적은 것은 답한 것이 아니다.
    var unansweredCount: Int { items.filter { answer(for: $0).choice == nil }.count }

    /// 지금 답이 있는 항목의 id. 메모만 적은 것은 들어가지 않는다.
    var answeredIDs: Set<String> { Set(items.filter { answer(for: $0).choice != nil }.map(\.id)) }

    /// 묶음 이름이 처음 나온 차례대로 모은 항목.
    var stages: [(title: String, items: [FeedbackCheckItem])] { stages(hiding: []) }

    /// `hidden`에 든 항목을 뺀 묶음. "답하지 않은 것만 보기"에 쓴다. 항목이 남지 않은 묶음은 뺀다.
    func stages(hiding hidden: Set<String>) -> [(title: String, items: [FeedbackCheckItem])] {
        var order: [String] = []
        var groups: [String: [FeedbackCheckItem]] = [:]
        for item in items where !hidden.contains(item.id) {
            if groups[item.stage] == nil { order.append(item.stage) }
            groups[item.stage, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// 피드백과 함께 보낼 답. 답하지 않은 항목도 넣어, 받는 쪽이 무엇이 남았는지 안다.
    var reportChecks: [FeedbackReport.Check] {
        items.map { item in
            let answer = answer(for: item)
            return FeedbackReport.Check(id: item.id, title: item.title, answer: answer.choice ?? "", note: answer.note,
                                        build: answer.isEmpty ? "" : answer.build,
                                        answeredAt: answer.choice == nil ? "" : answer.answeredAt.map { ISO8601DateFormatter.fractional.string(from: $0) } ?? "")
        }
    }

    /// 메일에 붙는 암호화된 진단에 넣을 모양. 첫째 답을 통과로, `확인 못함`을 해 보지 못함으로, 나머지 답을 실패로 적고 고른 답은 `choice`에 둔다.
    var mailChecks: [FeedbackCheck] {
        items.map { item in
            let answer = answer(for: item)
            let state: FeedbackCheck.Answer = answer.choice.map {
                $0 == item.choices.first ? .passed : $0 == FeedbackCheckItem.untestedChoice ? .untested : .failed
            } ?? .unchecked
            return FeedbackCheck(id: item.id, title: item.title, answer: state, note: answer.note, choice: answer.choice)
        }
    }
}

extension FeedbackClient {
    /// Mac에 남겨 둔 이 앱의 확인 목록(`GET /v1/feedback/checklist/<번들 ID>`). 기록을 보내는 주소와 같은 Mac에,
    /// 같은 길(이 iPhone의 RemoteDebug VPN, 페어링한 기기)로 묻는다. Mac에 닿지 않으면 `nil`.
    func fetchChecklist(bundleID: String) async -> Data? {
        guard !bundleID.isEmpty, bundleID.utf8.count <= 255, !bundleID.hasPrefix("."),
              bundleID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }),
              let url = URL(string: "/v1/feedback/checklist/\(bundleID)", relativeTo: endpoint)?.absoluteURL else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await send(request), (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= FeedbackCheckStore.maxResponseBytes else { return nil }
        return data
    }
}
#endif
