import Foundation

/// A project folder the user registered.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    /// Security-scoped bookmark, so the folder can be reopened after a relaunch.
    public var bookmark: Data?

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
    }
}

/// What an agent does with one copy of a skill.
public enum LoadState: Sendable, Hashable {
    case loaded
    /// Codex: loaded, but other copies with the same name are loaded too.
    case loadedDuplicate
    /// Another copy with the same name wins; this one is ignored.
    case shadowed(byEntry: String)
    /// DSH: a same-name stub with both switches off wins, so the skill is hidden.
    case hiddenByStub(stubEntry: String)
    /// This copy is such a stub.
    case disabledStub
    /// Turned off in the agent's own settings (`[[skills.config]]` for Codex).
    case disabledInConfig
    /// The agent cannot load it (for example a broken link).
    case notLoadable(String)

    public var isActive: Bool {
        switch self {
        case .loaded, .loadedDuplicate: return true
        default: return false
        }
    }
}

/// One copy of a skill as one agent sees it.
public struct Placement: Sendable, Hashable, Identifiable {
    public var id: String { harnessID + "|" + copy.entryPath }
    public var harnessID: String
    public var copy: SkillCopy
    public var root: SkillRoot
    public var rootPath: String
    public var state: LoadState
    /// The registered project this copy lives in (nil for global folders).
    public var projectID: UUID? = nil
    public var isHarnessOwned: Bool { root.role == .builtin }
    /// Whether the agent's AI can pick this skill on its own. When false the
    /// skill only runs when you ask for it by name.
    public var modelCanUse: Bool {
        copy.modelInvocable && !(harnessID == DefaultAdapters.codex.id && copy.codexImplicitOff)
    }
    public var scope: RootScope { root.scope }
}

/// A folder an agent reads, and what Tackroom found there.
public struct RootReport: Sendable, Hashable, Identifiable {
    public var id: String { harnessID + "|" + path }
    public var harnessID: String
    public var root: SkillRoot
    public var path: String
    public var exists: Bool
    public var error: String?
    /// Set when this folder is the same folder as another root of the same agent
    /// (for example Antigravity's old path pointing at the new one).
    public var sameFolderAs: String?
    public var skillCount: Int
}

public struct HarnessResult: Sendable, Hashable, Identifiable {
    public var id: String { adapter.id }
    public var adapter: HarnessAdapter
    public var placements: [Placement]
    public var roots: [RootReport]

    public var activeCount: Int { placements.filter { $0.state.isActive && !$0.isHarnessOwned }.count }
    public var isInstalled: Bool {
        if !adapter.markers.isEmpty { return adapter.isPresent }
        return roots.contains { $0.exists } || adapter.appPath.map { FileManager.default.fileExists(atPath: $0) } == true
    }
}

public enum Inventory {
    /// Reads every folder every agent uses, for the global scope or one project.
    public static func scan(adapters: [HarnessAdapter] = AdapterConfig.load(),
                            project: Project? = nil,
                            codexDisabled: Set<String> = CodexConfig.disabledSkillFiles()) -> [HarnessResult] {
        var cache: [String: RootScan] = [:]
        func scanCached(_ path: String, flat: Bool) -> RootScan {
            let key = path + (flat ? "|flat" : "")
            if let hit = cache[key] { return hit }
            let result = Scanner.scanRoot(path, acceptFlatMarkdown: flat)
            cache[key] = result
            return result
        }

        return adapters.map { adapter in
            var reports: [RootReport] = []
            var placements: [Placement] = []
            var seenReal: [String: String] = [:]

            for root in adapter.roots.sorted(by: { $0.rank < $1.rank }) {
                for path in absolutePaths(for: root, adapter: adapter, project: project) {
                    let scan = scanCached(path, flat: adapter.acceptsFlatMarkdown)
                    var report = RootReport(harnessID: adapter.id, root: root, path: path, exists: scan.exists,
                                            error: scan.error, sameFolderAs: nil, skillCount: scan.copies.count)
                    if let real = scan.realPath {
                        if let first = seenReal[real] {
                            report.sameFolderAs = first
                            reports.append(report)
                            continue
                        }
                        seenReal[real] = path
                    }
                    reports.append(report)
                    for copy in scan.copies {
                        placements.append(Placement(harnessID: adapter.id, copy: copy, root: root, rootPath: path, state: .loaded,
                                                 projectID: root.scope == .project ? project?.id : nil))
                    }
                }
            }
            resolve(&placements, adapter: adapter, codexDisabled: codexDisabled)
            return HarnessResult(adapter: adapter, placements: placements, roots: reports)
        }
    }

    static func absolutePaths(for root: SkillRoot, adapter: HarnessAdapter, project: Project?) -> [String] {
        switch root.scope {
        case .global:
            return Paths.glob(Paths.expand(root.path))
        case .project:
            guard let project else { return [] }
            var base = project.path
            if adapter.projectRoot == .nearestGitRoot, let git = Paths.gitRoot(above: project.path) { base = git }
            guard root.walkUpToGitRoot, let git = Paths.gitRoot(above: project.path) else {
                return [(base as NSString).appendingPathComponent(root.path)]
            }
            // From the project folder up to (and including) the git root.
            var dirs: [String] = []
            var url = URL(fileURLWithPath: project.path).standardizedFileURL
            while true {
                dirs.append(url.appendingPathComponent(root.path).path)
                if url.path == git { break }
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { break }
                url = parent
            }
            return dirs
        }
    }

    static func resolve(_ placements: inout [Placement], adapter: HarnessAdapter, codexDisabled: Set<String>) {
        // Copies the agent can't use don't compete for the name.
        for i in placements.indices {
            let copy = placements[i].copy
            if copy.isBrokenLink {
                placements[i].state = .notLoadable(L("連結失效"))
            } else if adapter.id == DefaultAdapters.codex.id, let file = copy.skillFile,
                      codexDisabled.contains(file) || codexDisabled.contains(Paths.realpath(file) ?? file)
                        || codexDisabled.contains((copy.entryPath as NSString).appendingPathComponent("SKILL.md")) {
                placements[i].state = .disabledInConfig
            }
        }

        let byName = Dictionary(grouping: placements.indices.filter { placements[$0].state == .loaded },
                                by: { placements[$0].copy.name })
        for (_, indices) in byName {
            let ordered = indices.sorted { placements[$0].root.rank < placements[$1].root.rank }
            switch adapter.sameName {
            case .listsAll:
                if ordered.count > 1 { for i in ordered { placements[i].state = .loadedDuplicate } }
            case .lowestRankWins:
                guard let winner = ordered.first else { continue }
                let w = placements[winner].copy
                let isStub = adapter.hidesFullyDisabledSkills && !w.modelInvocable && !w.userInvocable
                if isStub { placements[winner].state = .disabledStub }
                for i in ordered.dropFirst() {
                    placements[i].state = isStub ? .hiddenByStub(stubEntry: w.entryPath) : .shadowed(byEntry: w.entryPath)
                }
            }
        }
    }
}

public extension Inventory {
    /// Scans one project (plus the global folders), opening its bookmark first.
    static func scan(project: Project, adapters: [HarnessAdapter] = AdapterConfig.load()) -> (ProjectAccess, [HarnessResult]) {
        project.withAccess { path, access in
            var resolved = project
            resolved.path = path
            let results = access == .ok ? scan(adapters: adapters, project: resolved) : scan(adapters: adapters, project: nil)
            return (access, results)
        }
    }
}
