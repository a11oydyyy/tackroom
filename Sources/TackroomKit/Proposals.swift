import Foundation

/// Something an agent asked for. Agents can only ask; the user approves in the app.
public struct Proposal: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: Codable, Sendable, Hashable {
        /// Install from `owner/repo`, a GitHub URL or a local folder.
        case install(source: String, skills: [String], agents: [String], projectPath: String?)
        case toggle(name: String, agent: String, on: Bool)
        case remove(name: String, explicitlyGlobal: Bool? = true)
        case projectRemove(name: String, path: String)
        case adopt(name: String)
    }

    public enum Status: String, Codable, Sendable {
        case pending, approved, rejected, failed
    }

    public var id: String
    public var createdAt: Date
    /// Who asked, e.g. `codex`.
    public var agent: String
    public var kind: Kind
    /// The agent's own words: why it wants this.
    public var reason: String
    public var status: Status
    public var decidedAt: Date?
    public var note: String?

    public init(agent: String, kind: Kind, reason: String) {
        self.id = String(UUID().uuidString.prefix(8)).lowercased()
        self.createdAt = Date()
        self.agent = agent
        self.kind = kind
        self.reason = reason
        self.status = .pending
    }

    /// One plain sentence.
    public var summary: String {
        switch kind {
        case .install(let source, let skills, let agents, let project):
            let from = source.hasPrefix("/") ? Paths.abbreviate(source) : source
            let what = skills.isEmpty ? from : skills.joined(separator: L("、")) + L("（\(from)）")
            let to = project.map { L("專案 \(Paths.abbreviate($0))") } ?? L("全域")
            return L("安裝 \(what) 到\(to)，給 \(agents.joined(separator: L("、")))")
        case .toggle(let name, let agent, let on):
            return on ? L("對 \(agent) 開啟 \(name)") : L("對 \(agent) 關閉 \(name)")
        case .projectRemove(let name, let path):
            return L("從專案 \(Paths.abbreviate(path)) 移除 \(name)")
        case .remove(let name, _):
            return L("移除 \(name)")
        case .adopt(let name):
            return L("將 \(name) 納入 Tackroom 管理")
        }
    }
}

/// Proposals live as small JSON files next to the store (not in its history).
public struct ProposalQueue: Sendable {
    public var dir: URL

    public init(dir: URL = Paths.home.appendingPathComponent(".tackroom/proposals", isDirectory: true)) {
        self.dir = dir
    }

    func url(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    @discardableResult
    public func submit(_ proposal: Proposal) throws -> Proposal {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try save(proposal)
        return proposal
    }

    public func save(_ proposal: Proposal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(proposal).write(to: url(proposal.id), options: .atomic)
    }

    public func all() -> [Proposal] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Proposal.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public var pending: [Proposal] { all().filter { $0.status == .pending } }

    public func get(_ id: String) -> Proposal? { all().first { $0.id == id } }

    public func decide(_ id: String, _ status: Proposal.Status, note: String? = nil) throws {
        guard var p = get(id) else { throw TackroomError.notFound(L("找不到提案 \(id)")) }
        p.status = status
        p.decidedAt = Date()
        p.note = note
        try save(p)
    }
}

public extension Operations {
    /// Turns a proposal into a plan, recorded as done by the agent that asked.
    /// Install proposals that need a download are prepared by the caller,
    /// which passes the found skills in.
    func plan(for proposal: Proposal, groups: [SkillGroup], found: [FoundSkill] = [],
              source: String = "", commit: String? = nil, project: Project? = nil) -> Plan {
        var ops = self
        ops.actor = "cli:" + proposal.agent
        var plan: Plan
        switch proposal.kind {
        case .toggle(let name, let agent, let on):
            plan = ops.planToggle(name, harness: agent, on: on)
        case .remove(let name, true):
            plan = ops.planRemove(name)
        case .projectRemove(let name, let path):
            guard let project, let requested = Paths.realpath(path),
                  Paths.realpath(project.path) == requested else {
                return Plan(title: proposal.summary, op: .setting(name: name), actor: ops.actor, preview: [], steps: [],
                            blocker: L("找不到這個已登記的專案，請確認專案路徑再送出移除請求。"))
            }
            plan = project.withAccess { resolved, access in
                var target = project
                target.path = resolved
                guard access == .ok else {
                    return Plan(title: proposal.summary, op: .projectRemove(name: name, project: target), actor: ops.actor,
                                preview: [], steps: [], blocker: L("無法讀取要移除 skill 的專案。"))
                }
                return ops.planProjectRemove(name, project: target)
            }
        case .remove(let name, _):
            // 舊 CLI 沒有保存 --project，核准時已無法判斷原先要求的範圍。
            return Plan(title: proposal.summary, op: .setting(name: name), actor: ops.actor, preview: [], steps: [],
                        blocker: L("這筆舊版移除請求沒有記錄作用範圍，請用新版命令列重新送出。"))
        case .adopt(let name):
            if let group = groups.first(where: { $0.name == name }) {
                plan = ops.planAdopt(group)
            } else {
                plan = Plan(title: proposal.summary, op: .adopt(name: name, originals: []), actor: ops.actor,
                            preview: [], steps: [], blocker: L("找不到「\(name)」。"))
            }
        case .install(_, let skills, let agents, _):
            let picked = skills.isEmpty ? found : found.filter { skills.contains($0.name) }
            if let project {
                plan = ops.planProjectAdd(picked, project: project, harnesses: agents, source: source)
            } else {
                plan = ops.planAdd(picked, harnesses: agents, source: source, commit: commit)
            }
        }
        return plan
    }
}
