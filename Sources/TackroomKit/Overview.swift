import Foundation

/// Something about a skill the user may want to look at.
public enum SkillIssue: Sendable, Hashable {
    case brokenLink(entry: String)
    /// The same agent loads two or more copies with this name (Codex).
    case duplicate(harnessID: String)
    /// Agents load copies with different contents.
    case versionsDiffer
    /// The instruction file has a problem; some agents may skip it.
    case problem(String)
    /// A managed skill's files changed outside Tackroom.
    case drifted

    public var needsAttention: Bool { true }
}

/// One row of the Skill overview: every copy of one skill name, across agents.
public struct SkillGroup: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var placements: [Placement]
    public var issues: [SkillIssue]
    /// The copy kept in Tackroom's store, for a managed skill no agent has
    /// turned on right now (so it stays listed and can be turned back on).
    public var stored: SkillCopy?

    public init(name: String, description: String, placements: [Placement], issues: [SkillIssue], stored: SkillCopy? = nil) {
        self.name = name
        self.description = description
        self.placements = placements
        self.issues = issues
        self.stored = stored
    }

    /// Managed, kept in the store, and on for no agent.
    public var isOffEverywhere: Bool { placements.isEmpty && stored != nil }

    /// Agents that actually load some copy of this skill.
    public var activeHarnessIDs: [String] {
        var seen: [String] = []
        for p in placements where p.state.isActive && !seen.contains(p.harnessID) { seen.append(p.harnessID) }
        return seen
    }
    public var isHarnessOwned: Bool { !placements.isEmpty && placements.allSatisfy(\.isHarnessOwned) }
    public var needsAttention: Bool { !issues.isEmpty }
    public var hasProjectCopy: Bool { placements.contains { $0.scope == .project } }

    /// Distinct copies on disk (one folder may be seen by several agents).
    public var distinctCopies: [SkillCopy] {
        var seen: Set<String> = []
        var result: [SkillCopy] = []
        for p in placements {
            let key = p.copy.resolvedPath ?? p.copy.entryPath
            if seen.insert(key).inserted { result.append(p.copy) }
        }
        if result.isEmpty, let stored { result.append(stored) }
        return result
    }
}

public enum Overview {
    public static func groups(from results: [HarnessResult]) -> [SkillGroup] {
        groups(placements: results.flatMap(\.placements), harnessOrder: results.map(\.adapter.id))
    }

    /// Groups placements by skill name. Placements may come from several scans
    /// (the global scan plus one per project).
    public static func groups(placements all: [Placement], harnessOrder: [String]) -> [SkillGroup] {
        let byName = Dictionary(grouping: all, by: { $0.copy.name })
        return byName.map { name, placements in
            let sorted = placements.sorted { a, b in
                let ai = harnessOrder.firstIndex(of: a.harnessID) ?? 0
                let bi = harnessOrder.firstIndex(of: b.harnessID) ?? 0
                return ai != bi ? ai < bi : a.root.rank < b.root.rank
            }
            var issues: [SkillIssue] = []
            var brokenSeen: Set<String> = []
            for p in sorted where p.copy.isBrokenLink && brokenSeen.insert(p.copy.entryPath).inserted {
                issues.append(.brokenLink(entry: p.copy.entryPath))
            }
            for h in Set(sorted.filter { $0.state == .loadedDuplicate }.map(\.harnessID)).sorted() {
                issues.append(.duplicate(harnessID: h))
            }
            let activeHashes = Set(sorted.filter { $0.state.isActive && !$0.isHarnessOwned }.compactMap(\.copy.contentHash))
            if activeHashes.count > 1 { issues.append(.versionsDiffer) }
            if let problem = sorted.first(where: { $0.copy.problem != nil && !$0.copy.isBrokenLink })?.copy.problem {
                issues.append(.problem(problem))
            }
            let description = sorted.first(where: { !$0.copy.description.isEmpty })?.copy.description ?? ""
            return SkillGroup(name: name, description: description, placements: sorted, issues: issues)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
