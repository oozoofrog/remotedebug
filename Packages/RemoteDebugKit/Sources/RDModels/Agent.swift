import Foundation

/// 에이전트 요청 기능을 화면에 내보일지. `false`면 Mac 사이드바와 iPhone 탭에서 숨기고 Mac은 요청을 받지 않는다.
public enum AgentFeature {
    public static let isEnabled = false
}

/// Mac에서 요청을 받아 실행하는 코딩 에이전트 명령줄 도구(docs/protocol-addenda.md K).
public enum AgentTool: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case claude, codex

    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude Code" : "Codex" }
}

/// 에이전트가 작업할 수 있는 프로젝트 폴더. `id`는 Mac 앱이 정한 값이다.
public struct AgentProjectRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 에이전트에 보낸 요청 하나와 그 진행·결과.
public struct AgentJob: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Hashable {
        case queued, running, done, failed, cancelled

        public var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
    }

    public var id: String
    public var text: String
    public var project: String
    public var projectName: String
    public var agent: AgentTool
    /// 요청을 보낸 곳: Mac이면 "Mac", iPhone이면 기기 이름.
    public var origin: String
    public var state: State
    public var createdAt: Date
    public var finishedAt: Date?
    /// 실행 중에 쌓이는 진행 내용(에이전트가 쓴 글과 쓴 도구). 끝 부분만 남긴다.
    public var activity: String
    /// 에이전트의 마지막 답. 실패면 이유.
    public var output: String
    /// 이어서 요청할 때 쓰는 에이전트 세션. 비어 있으면 이어 갈 수 없다.
    public var session: String
    /// 이 요청이 이어 간 앞 요청의 id.
    public var continues: String

    public init(id: String, text: String, project: String, projectName: String, agent: AgentTool, origin: String,
                state: State = .queued, createdAt: Date, finishedAt: Date? = nil, activity: String = "", output: String = "",
                session: String = "", continues: String = "") {
        self.id = id
        self.text = text
        self.project = project
        self.projectName = projectName
        self.agent = agent
        self.origin = origin
        self.state = state
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.activity = activity
        self.output = output
        self.session = session
        self.continues = continues
    }

    enum CodingKeys: String, CodingKey {
        case id, text, project, projectName, agent, origin, state, createdAt, finishedAt, activity, output, session, continues
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        agent = (try? c.decode(AgentTool.self, forKey: .agent)) ?? .claude
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        state = (try? c.decode(State.self, forKey: .state)) ?? .failed
        createdAt = try c.decodeRDDate(forKey: .createdAt)
        finishedAt = try c.decodeRDDateIfPresent(forKey: .finishedAt)
        activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? ""
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        continues = try c.decodeIfPresent(String.self, forKey: .continues) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(project, forKey: .project)
        try c.encode(projectName, forKey: .projectName)
        try c.encode(agent, forKey: .agent)
        try c.encode(origin, forKey: .origin)
        try c.encode(state, forKey: .state)
        try c.encodeRDDate(createdAt, forKey: .createdAt)
        if let finishedAt { try c.encodeRDDate(finishedAt, forKey: .finishedAt) }
        try c.encode(activity, forKey: .activity)
        try c.encode(output, forKey: .output)
        try c.encode(session, forKey: .session)
        try c.encode(continues, forKey: .continues)
    }

    public var canContinue: Bool { state.isFinished && !session.isEmpty }
}

/// `GET /v1/agent`의 본문. Mac 앱이 만들어 코어에 넘긴다.
public struct AgentBoard: Codable, Sendable, Hashable {
    /// Mac이 iPhone의 요청을 받는다.
    public var enabled: Bool
    public var projects: [AgentProjectRef]
    /// Mac에 설치된 에이전트. 첫 항목이 기본값이다.
    public var agents: [AgentTool]
    /// 최근 요청(새 것부터).
    public var requests: [AgentJob]

    public init(enabled: Bool = false, projects: [AgentProjectRef] = [], agents: [AgentTool] = [], requests: [AgentJob] = []) {
        self.enabled = enabled
        self.projects = projects
        self.agents = agents
        self.requests = requests
    }

    enum CodingKeys: String, CodingKey { case enabled, projects, agents, requests }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        projects = try c.decodeIfPresent([AgentProjectRef].self, forKey: .projects) ?? []
        // 모르는 에이전트 이름은 건너뛴다(새 Mac 앱과 이전 iPhone 앱).
        agents = (try c.decodeIfPresent([String].self, forKey: .agents) ?? []).compactMap(AgentTool.init(rawValue:))
        requests = try c.decodeIfPresent([AgentJob].self, forKey: .requests) ?? []
    }
}

/// `POST /v1/agent/requests`의 본문.
public struct AgentSubmission: Codable, Sendable, Hashable {
    public var text: String
    public var project: String
    public var agent: String
    /// 이어 갈 앞 요청의 id. 새 대화면 빈 문자열.
    public var continues: String

    public init(text: String, project: String, agent: AgentTool? = nil, continues: String = "") {
        self.text = text
        self.project = project
        self.agent = agent?.rawValue ?? ""
        self.continues = continues
    }

    /// 코어가 받는 한도(UTF-8 바이트).
    public static let maxTextBytes = 16 << 10
}

/// 코어 이벤트 `agent-request`: 허용 목록의 기기가 보낸 요청.
public struct AgentRequestEvent: Codable, Sendable, Hashable {
    public var requestId: String
    public var deviceId: String
    public var deviceName: String
    public var text: String
    public var project: String
    public var agent: String
    public var continues: String

    public init(requestId: String, deviceId: String, deviceName: String, text: String, project: String = "", agent: String = "", continues: String = "") {
        self.requestId = requestId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.text = text
        self.project = project
        self.agent = agent
        self.continues = continues
    }
}

/// 코어 이벤트 `agent-cancel`: 기기가 요청을 멈춰 달라고 했다.
public struct AgentCancelEvent: Codable, Sendable, Hashable {
    public var requestId: String
    public var deviceName: String

    public init(requestId: String, deviceName: String = "") {
        self.requestId = requestId
        self.deviceName = deviceName
    }
}
