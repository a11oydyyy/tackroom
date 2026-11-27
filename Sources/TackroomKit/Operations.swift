import Foundation
import Darwin

// MARK: - Plan

/// One file-system step. Every step is safe to run twice, so a plan that was
/// cut off halfway can simply be run again from where it stopped.
public enum Step: Codable, Sendable, Hashable {
    case copyDir(from: String, to: String)
    case renamePreferences(from: String, to: String)
    case createFromGit(commit: String, path: String)
    case createCopy(from: String, to: String)
    case verifyEntry(path: String, link: String?)
    case unlinkMatching(path: String, link: String)
    case trash(String)
    case trashReviewed(name: String, entry: LockEntry, fingerprint: String?)
    case stageForCaseRename(name: String, entry: LockEntry, fingerprint: String?, to: String)
    case link(at: String, to: String)
    case unlink(String)
    case restoreFromGit(commit: String, path: String)
    case writeLock(Lockfile)
    /// Writes only the skills this plan changed (base → new) onto the
    /// lockfile as it is when the step runs, so a plan prepared earlier
    /// can't undo another change made in the meantime.
    case patchLock(base: Lockfile, new: Lockfile, project: Project? = nil)
    /// Marks a store path to record in the next commit (files the plan
    /// keeps rather than writes, such as edits made outside Tackroom).
    case include(String)
    case writeFile(path: String, contents: String)
    /// Stops the plan if the files changed since the user reviewed them.
    case verifyHash(path: String, hash: String)
    /// Stops the plan if the installed files changed after the review, so
    /// edits made in the meantime are never overwritten.
    case verifyLocal(path: String, hash: String)
    case commit(String)
    /// A commit recorded under its own Activity entry (one plan doing several things).
    case commitAs(title: String, op: JournalOp)
}

/// A line in the preview the user approves before anything is written.
public struct PreviewLine: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case add, remove, change, keep, warning }
    public var id: String { kind.rawValue + text }
    public var kind: Kind
    public var text: String
}

/// What an operation did, kept in the commit so it can be undone later.
public enum JournalOp: Codable, Sendable, Hashable {
    case adopt(name: String, originals: [String], links: [String: String]? = [:])
    case add(name: String)
    case toggle(name: String, harness: String, on: Bool)
    case remove(name: String)
    case projectAdd(name: String, project: Project)
    case projectRemove(name: String, project: Project)
    case update(name: String, renamedTo: String? = nil)
    /// Skip a version, pin: recorded, not undone from Activity.
    case setting(name: String)
    case undo(of: String)
    /// An agent instruction file (CLAUDE.md, AGENTS.md, …) edited in Tackroom.
    case editDoc(path: String, project: Project?)
}

public struct Plan: Codable, Sendable, Hashable {
    /// One plain sentence for Activity.
    public var title: String
    public var op: JournalOp
    public var actor: String
    public var preview: [PreviewLine]
    public var steps: [Step]
    /// Something blocks this plan (shown instead of the confirm button).
    public var blocker: String?

    public init(title: String, op: JournalOp, actor: String, preview: [PreviewLine], steps: [Step], blocker: String?) {
        self.title = title
        self.op = op
        self.actor = actor
        self.preview = preview
        self.steps = steps
        self.blocker = blocker
    }
}

private extension Plan {
    var isInstall: Bool {
        switch op {
        case .add, .projectAdd: return true
        default: return false
        }
    }
}

// MARK: - Operations

public struct Operations: Sendable {
    public var store: Store
    public var adapters: [HarnessAdapter]
    public var actor: String
    /// Moves a path to the Trash. Tests swap in a folder of their own.
    public var trash: @Sendable (URL) throws -> Void

    public init(store: Store = Store(), adapters: [HarnessAdapter] = AdapterConfig.load(), actor: String = "gui",
                trash: @escaping @Sendable (URL) throws -> Void = Operations.defaultTrash) {
        self.store = store
        self.adapters = adapters
        self.actor = actor
        self.trash = trash
    }

    /// The system Trash; with a stand-in home (`TACKROOM_HOME`), that home's `.Trash`
    /// instead, so trying things out never fills the real Trash.
    public static let defaultTrash: @Sendable (URL) throws -> Void = { url in
        if let fake = ProcessInfo.processInfo.environment["TACKROOM_HOME"], !fake.isEmpty {
            let dir = URL(fileURLWithPath: fake).appendingPathComponent(".Trash")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent + "-" + UUID().uuidString.prefix(6)))
        } else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    var writable: [HarnessAdapter] { adapters.filter { $0.writeDir != nil } }

    func writeDir(_ adapter: HarnessAdapter) -> String? { adapter.writeDir.map(Paths.expand) }

    func linkPath(_ adapter: HarnessAdapter, _ name: String) -> String? {
        writeDir(adapter).map { ($0 as NSString).appendingPathComponent(SkillName.folder(name)) }
    }

    /// 舊版沒有保存入口名稱；仍啟用的捷徑可從實際目的地辨認。
    func entryPaths(_ adapter: HarnessAdapter, name: String, entry: LockEntry, discoverExisting: Bool = true) -> [String] {
        guard let root = writeDir(adapter) else { return [] }
        let target = store.location(of: name, entry: entry)
        let folders: [String]
        if let saved = entry.entryFolders?[adapter.id] {
            folders = saved.filter { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") }
        } else if discoverExisting {
            let fm = FileManager.default
            let live = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted().filter { folder in
                let p = (root as NSString).appendingPathComponent(folder)
                return !folder.hasPrefix(".") && isSymlink(p) && pointsTo(p, target)
            }
            folders = live.isEmpty ? [SkillName.folder(name)] : live
        } else {
            folders = [SkillName.folder(name)]
        }
        return folders.map { (root as NSString).appendingPathComponent($0) }
    }

    func pointsTo(_ path: String, _ target: String) -> Bool {
        if let real = Paths.realpath(path) { return real == Paths.realpath(target) }
        guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        return URL(fileURLWithPath: raw, relativeTo: parent).standardizedFileURL.path
            == URL(fileURLWithPath: target).standardizedFileURL.path
    }

    func rememberPaths(_ paths: [String], agent: String, name: String, entry: inout LockEntry) {
        let names = Array(Set(paths.map { ($0 as NSString).lastPathComponent })).sorted()
        var map = entry.entryFolders ?? [:]
        map[agent] = names == [name] || names.isEmpty ? nil : names
        entry.entryFolders = map.isEmpty ? nil : map
    }

    func short(_ path: String) -> String { Paths.abbreviate(path) }

    /// A single-file `<name>.md` skill in the agent's own folder (DSH reads those too).
    func hasFlatCopy(_ adapter: HarnessAdapter, name: String) -> Bool {
        guard adapter.acceptsFlatMarkdown, let dir = writeDir(adapter) else { return false }
        return FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(SkillName.folder(name) + ".md"))
    }

    /// Same-name copies in the agent's other global folders, which it still
    /// reads whatever Tackroom does with its own folder.
    func otherCopies(_ adapter: HarnessAdapter, name: String) -> [(path: String, rank: Int)] {
        guard let own = writeDir(adapter) else { return [] }
        let fm = FileManager.default
        return adapter.globalRoots.filter { $0.role != .builtin && !$0.path.contains("*") }.compactMap { root in
            let dir = Paths.expand(root.path)
            guard (Paths.realpath(dir) ?? dir) != (Paths.realpath(own) ?? own) else { return nil }
            var names = [SkillName.folder(name)]
            if adapter.acceptsFlatMarkdown { names.append(SkillName.folder(name) + ".md") }
            let hit = names.map { (dir as NSString).appendingPathComponent($0) }.first { fm.fileExists(atPath: $0) }
            return hit.map { ($0, root.rank) }
        }
    }

    /// Other agents that also read the folder this agent's links go into
    /// (Cursor and OpenCode read ~/.claude/skills, for example).
    func sharedReaders(of adapter: HarnessAdapter, besides chosen: [String] = []) -> [String] {
        guard let dir = writeDir(adapter) else { return [] }
        let real = Paths.realpath(dir) ?? dir
        return adapters.filter { other in
            other.id != adapter.id && !chosen.contains(other.id) && other.globalRoots.contains { root in
                let path = Paths.expand(root.path)
                return root.role != .builtin && (Paths.realpath(path) ?? path) == real
            }
        }.map(\.shortName)
    }

    /// What the agent reads after the switch, when another copy is involved.
    func otherCopyLines(_ adapter: HarnessAdapter, name: String, on: Bool) -> [PreviewLine] {
        let ownRank = adapter.globalRoots.first { Paths.expand($0.path) == writeDir(adapter) }?.rank ?? 0
        return otherCopies(adapter, name: name).compactMap { other in
            let at = short(other.path)
            switch (adapter.sameName, on) {
            case (.listsAll, false): return PreviewLine(kind: .warning, text: L("關閉後 \(adapter.shortName) 仍會讀到 \(at)"))
            case (.listsAll, true): return PreviewLine(kind: .warning, text: L("\(adapter.shortName) 也會讀到 \(at)，兩份同時出現"))
            case (.lowestRankWins, false): return PreviewLine(kind: .warning, text: L("關閉後 \(adapter.shortName) 會改用 \(at)"))
            case (.lowestRankWins, true):
                return other.rank < ownRank
                    ? PreviewLine(kind: .warning, text: L("\(adapter.shortName) 仍會優先使用 \(at)")) : nil
            }
        }
    }

    // MARK: Adopt

    /// Takes over a skill that is already installed: its files move into the
    /// store and the agent folders get links to it. Folders that are already
    /// links to your own folder, or that hold a git repo, stay where they are.
    public func planAdopt(_ group: SkillGroup, base: Lockfile? = nil) -> Plan {
        let name = group.name
        let lock = base ?? store.readLock()
        var preview: [PreviewLine] = []
        var steps: [Step] = []
        var blocker: String?
        if lock.skills[name] != nil { blocker = L("「\(name)」已經由 Tackroom 管理。") }
        if !SkillName.isSafe(name) { blocker = SkillName.problem }

        // Copies in folders Tackroom may write to.
        let writableIDs = Set(writable.map(\.id))
        let mine = group.placements.filter { p in
            guard writableIDs.contains(p.harnessID), p.scope == .global, !p.isHarnessOwned, !p.copy.isBrokenLink,
                  let adapter = adapters.first(where: { $0.id == p.harnessID }) else { return false }
            guard let dir = writeDir(adapter) else { return false }
            return (Paths.realpath(p.rootPath) ?? p.rootPath) == (Paths.realpath(dir) ?? dir)
        }
        guard !mine.isEmpty else {
            return Plan(title: L("納入 Tackroom 管理 \(name)"), op: .adopt(name: name, originals: []), actor: actor,
                        preview: [], steps: [], blocker: L("這個 skill 不在 Tackroom 可以寫入的資料夾（\(writable.map(\.name).joined(separator: L("、")))）。"))
        }

        let realCopies = mine.filter { !$0.copy.isSymlink }
        let ownFolder: String? = {
            if let real = realCopies.first, let path = real.copy.resolvedPath,
               FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return path }
            if realCopies.isEmpty, let target = mine.first?.copy.resolvedPath { return target }
            return nil
        }()

        var entry: LockEntry
        var originals: [String] = []
        var priorLinks: [String: String] = [:]
        var paths: [String: [String]] = [:]
        var harnesses: [String] = []

        if let own = ownFolder {
            // Stays in your folder; Tackroom only records it.
            preview.append(PreviewLine(kind: .keep, text: L("檔案留在 \(short(own))，不搬動")))
            for p in mine where p.copy.resolvedPath == own {
                paths[p.harnessID, default: []].append(p.copy.entryPath)
                harnesses.append(p.harnessID)
            }
            entry = LockEntry(source: "linked:" + own, contentHash: Scanner.hashFolder(own).0, harnesses: harnesses)
        } else {
            let canonical = realCopies[0]
            let source = canonical.copy.resolvedPath!
            let target = store.skillDir(name).path
            let hash = canonical.copy.contentHash ?? Scanner.hashFolder(source).0
            let moving = Set(realCopies.filter { $0.copy.contentHash == hash }.compactMap(\.copy.resolvedPath))
            steps.append(.verifyEntry(path: target, link: nil))
            steps.append(.createCopy(from: source, to: target))
            preview.append(PreviewLine(kind: .add, text: L("複製到 Tackroom：\(short(source))")))
            for p in mine {
                let entryPath = p.copy.entryPath
                if !p.copy.isSymlink {
                    guard p.copy.contentHash == hash else {
                        preview.append(PreviewLine(kind: .warning, text: L("內容不同，保持原樣：\(short(entryPath))")))
                        continue
                    }
                    steps.append(.trash(entryPath))
                    steps.append(.link(at: entryPath, to: target))
                    preview.append(PreviewLine(kind: .change, text: L("原資料夾移到垃圾桶，改成捷徑：\(short(entryPath))")))
                    originals.append(entryPath)
                } else if let resolved = p.copy.resolvedPath, moving.contains(resolved), let prior = p.copy.linkTarget {
                    // A link to the copy that is about to move: point it at the store instead.
                    priorLinks[entryPath] = prior
                    steps.append(.unlinkMatching(path: entryPath, link: prior))
                    steps.append(.link(at: entryPath, to: target))
                    preview.append(PreviewLine(kind: .change, text: L("捷徑改指向 Tackroom：\(short(entryPath))")))
                } else {
                    preview.append(PreviewLine(kind: .keep, text: L("捷徑指向別處，保持原樣：\(short(entryPath))")))
                    continue
                }
                paths[p.harnessID, default: []].append(entryPath)
                harnesses.append(p.harnessID)
            }
            entry = LockEntry(source: "adopted", contentHash: hash, harnesses: harnesses)
            if let known = SkillsShLock.load().source(for: name) {
                entry.source = known.source
                entry.path = known.path
            }
        }
        for p in group.placements where !writableIDs.contains(p.harnessID) && !p.isHarnessOwned {
            let agent = adapters.first { $0.id == p.harnessID }?.name ?? p.harnessID
            preview.append(PreviewLine(kind: .keep, text: L("\(agent) 的那一份不動（目前唯讀）：\(short(p.copy.entryPath))")))
        }

        for (id, entries) in paths { rememberPaths(entries, agent: id, name: name, entry: &entry) }
        entry.harnesses = harnesses.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        var newLock = lock
        newLock.skills[name] = entry
        steps.append(.patchLock(base: lock, new: newLock))
        let agents = entry.harnesses.compactMap { id in adapters.first { $0.id == id }?.shortName }.joined(separator: L("、"))
        let title = L("納入 Tackroom 管理 \(name)") + (agents.isEmpty ? "" : L("（\(agents)）"))
        steps.append(.commit(title))
        return Plan(title: title, op: .adopt(name: name, originals: originals, links: priorLinks), actor: actor,
                    preview: preview, steps: steps, blocker: blocker)
    }

    /// Several skills at once: one confirmation, but each skill gets its own
    /// Activity entry so it can be put back on its own. Skills that can't be
    /// adopted are listed and left alone.
    public func planAdoptMany(_ groups: [SkillGroup]) -> Plan {
        var lock = store.readLock()
        var steps: [Step] = []
        var preview: [PreviewLine] = []
        var skipped: [PreviewLine] = []
        var done: [String] = []
        var firstOp: JournalOp?
        for group in groups {
            let plan = planAdopt(group, base: lock)
            if let blocker = plan.blocker {
                skipped.append(PreviewLine(kind: .keep, text: L("\(group.name) 不動：\(blocker)")))
                continue
            }
            for step in plan.steps {
                switch step {
                case .commit(let title): steps.append(.commitAs(title: title, op: plan.op))
                case .patchLock(_, let l, _), .writeLock(let l): lock = l; steps.append(step)
                default: steps.append(step)
                }
            }
            firstOp = firstOp ?? plan.op
            done.append(group.name)
            preview.append(PreviewLine(kind: .add, text: group.name))
            preview += plan.preview.map { PreviewLine(kind: $0.kind, text: L("　") + $0.text) }
        }
        let title = L("納入 Tackroom 管理 \(done.count) 個 skill")
        return Plan(title: title, op: firstOp ?? .setting(name: ""), actor: actor, preview: preview + skipped, steps: steps,
                    blocker: done.isEmpty ? L("選取的 skill 都無法納入管理（已在管理中，或不在 \(writable.map(\.name).joined(separator: L("、"))) 的資料夾）。") : nil)
    }

    // MARK: Add

    /// Installs skills from a folder (already unpacked) into the store and
    /// turns them on for the chosen agents.
    public func planAdd(_ found: [FoundSkill], harnesses: [String], source: String,
                        ref: String? = nil, commit: String? = nil) -> Plan {
        let original = store.readLock()
        var lock = original
        var preview: [PreviewLine] = []
        var steps: [Step] = []
        var blocker: String?
        let several = found.count > 1
        for skill in found {
            if !SkillName.isSafe(skill.name) { blocker = L("「\(skill.name)」") + SkillName.problem; break }
            if let link = Differ.outsideLinks(in: skill.path).first {
                blocker = L("「\(skill.name)」內有指向 skill 以外的捷徑（\(link)），為了安全不安裝。")
                break
            }
            let target = store.skillDir(skill.name).path
            if lock.skills[skill.name] != nil {
                blocker = L("「\(skill.name)」已經由 Tackroom 管理。")
                break
            }
            steps.append(.copyDir(from: skill.path, to: target))
            preview.append(PreviewLine(kind: .add, text: L("加入 Tackroom：\(skill.name)")))
            for id in harnesses {
                guard let adapter = adapters.first(where: { $0.id == id }), let link = linkPath(adapter, skill.name) else { continue }
                if FileManager.default.fileExists(atPath: link) || isSymlink(link) {
                    blocker = L("\(adapter.name) 已經有一個叫「\(skill.name)」的 skill：\(short(link))")
                    break
                }
                steps.append(.link(at: link, to: target))
                preview.append(PreviewLine(kind: .add, text: L("\(adapter.name)：新增捷徑 \(short(link))")))
            }
            let hash = Scanner.hashFolder(skill.path).0
            var entry = LockEntry(source: source, path: skill.pathInSource, ref: ref, commit: commit,
                                  contentHash: hash, harnesses: harnesses)
            // Installed straight from its upstream: that version is the base for updates.
            if entry.remoteURL != nil { entry.upstreamHash = hash }
            let previous = lock
            lock.skills[skill.name] = entry
            if skill.hasScripts {
                preview.append(PreviewLine(kind: .warning, text: L("\(skill.name) 含有可以執行的程式")))
            }
            // Several at once: each skill gets its own entry in 紀錄, so each can be put back.
            if several {
                steps.append(.patchLock(base: previous, new: lock))
                steps.append(.commitAs(title: L("安裝 \(skill.name)"), op: .add(name: skill.name)))
            }
        }
        let readers = Set(writable.filter { harnesses.contains($0.id) }.flatMap { sharedReaders(of: $0, besides: harnesses) })
        if !found.isEmpty && !readers.isEmpty {
            preview.append(PreviewLine(kind: .warning, text: L("\(readers.sorted().joined(separator: L("、"))) 也會讀到這一份")))
        }
        let names = found.map(\.name).joined(separator: L("、"))
        let title = L("安裝 \(names)")
        if !several {
            steps.append(.patchLock(base: original, new: lock))
            steps.append(.commit(title))
        }
        return Plan(title: title, op: .add(name: found.first?.name ?? ""), actor: actor,
                    preview: preview, steps: steps, blocker: found.isEmpty ? L("沒有找到 skill（需要含有 SKILL.md 的資料夾）。") : blocker)
    }

    // MARK: Toggle

    public func planToggle(_ name: String, harness: String, on: Bool) -> Plan {
        let original = store.readLock()
        var lock = original
        let agent = adapters.first { $0.id == harness }
        let label = agent?.shortName ?? harness
        let title = on ? L("開啟 \(name)（\(label)）") : L("關閉 \(name)（\(label)）")
        func blocked(_ why: String) -> Plan {
            Plan(title: title, op: .toggle(name: name, harness: harness, on: on), actor: actor, preview: [], steps: [], blocker: why)
        }
        guard var entry = lock.skills[name] else { return blocked(L("「\(name)」尚未納入 Tackroom 管理。")) }
        guard let agent, agent.writeDir != nil else { return blocked(L("這個 agent 目前唯讀。")) }
        let target = store.location(of: name, entry: entry)
        var steps: [Step] = []
        var preview: [PreviewLine] = []
        let paths = entryPaths(agent, name: name, entry: entry)
        guard !paths.isEmpty else { return blocked(L("找不到有效的 agent 入口。")) }
        // 舊版可能在原入口旁多建了一個以名稱命名的捷徑；重新開啟只需要原入口。
        let canonical = linkPath(agent, name)
        let hasLegacyDuplicate = entry.entryFolders?[harness] == nil && paths.count > 1 && paths.contains { $0 == canonical }
        let wanted = hasLegacyDuplicate ? paths.filter { $0 != canonical } : paths
        rememberPaths(wanted, agent: harness, name: name, entry: &entry)
        for link in paths {
            if on && wanted.contains(link) {
                if FileManager.default.fileExists(atPath: link) || isSymlink(link) {
                    if !pointsTo(link, target) {
                        return blocked(L("\(agent.name) 已經有另一個同名的 skill：\(short(link))"))
                    }
                } else {
                    steps.append(.link(at: link, to: target))
                    preview.append(PreviewLine(kind: .add, text: L("新增捷徑 \(short(link))")))
                }
            } else {
                if isSymlink(link) {
                    guard pointsTo(link, target), let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
                        return blocked(L("\(short(link)) 指向別的地方，Tackroom 不會動它。"))
                    }
                    steps.append(.unlinkMatching(path: link, link: raw))
                    preview.append(PreviewLine(kind: .remove, text: L("移除捷徑 \(short(link))")))
                } else if FileManager.default.fileExists(atPath: link) {
                    return blocked(L("\(short(link)) 是一般資料夾，不是 Tackroom 建的捷徑。"))
                }
            }
        }
        if on {
            if !entry.harnesses.contains(harness) { entry.harnesses.append(harness) }
        } else {
            entry.harnesses.removeAll { $0 == harness }
        }
        if on, hasFlatCopy(agent, name: name) {
            return blocked(L("\(agent.name) 已經有另一個同名的 skill：\(short((writeDir(agent)! as NSString).appendingPathComponent(SkillName.folder(name) + ".md")))"))
        }
        preview += otherCopyLines(agent, name: name, on: on)
        let readers = sharedReaders(of: agent).joined(separator: L("、"))
        if !steps.isEmpty && !readers.isEmpty {
            preview.append(PreviewLine(kind: .warning, text: on ? L("\(readers) 也會讀到這一份") : L("\(readers) 也會讀不到這一份")))
        }
        lock.skills[name] = entry
        steps += [.patchLock(base: original, new: lock), .commit(title)]
        return Plan(title: title, op: .toggle(name: name, harness: harness, on: on), actor: actor,
                    preview: preview, steps: steps, blocker: nil)
    }

    // MARK: Remove

    public func planRemove(_ name: String) -> Plan {
        let original = store.readLock()
        var lock = original
        let title = L("移除 \(name)")
        guard let entry = lock.skills[name] else {
            return Plan(title: title, op: .remove(name: name), actor: actor, preview: [], steps: [],
                        blocker: L("「\(name)」不是由 Tackroom 管理的。"))
        }
        let target = store.location(of: name, entry: entry)
        var steps: [Step] = []
        var preview: [PreviewLine] = []
        for adapter in writable {
            for link in entryPaths(adapter, name: name, entry: entry) where pointsTo(link, target) {
                guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { continue }
                steps.append(.unlinkMatching(path: link, link: raw))
                preview.append(PreviewLine(kind: .remove, text: L("\(adapter.name)：移除捷徑 \(short(link))")))
            }
            if entry.harnesses.contains(adapter.id) { preview += otherCopyLines(adapter, name: name, on: false) }
        }
        if entry.linkedPath == nil {
            steps.append(.trash(target))
            preview.append(PreviewLine(kind: .remove, text: L("Tackroom 裡的檔案移到垃圾桶（紀錄裡可以恢復）")))
        } else {
            preview.append(PreviewLine(kind: .keep, text: L("你資料夾裡的檔案不動：\(short(target))")))
        }
        lock.skills[name] = nil
        steps += [.patchLock(base: original, new: lock), .commit(title)]
        return Plan(title: title, op: .remove(name: name), actor: actor, preview: preview, steps: steps, blocker: nil)
    }

    // MARK: Undo

    public func planUndo(_ entry: ActivityEntry) -> Plan {
        let title = L("恢復：\(entry.title)")
        func blocked(_ why: String) -> Plan {
            Plan(title: title, op: .undo(of: entry.id), actor: actor, preview: [], steps: [], blocker: why)
        }
        guard let op = entry.op else { return blocked(L("這筆紀錄不能恢復。")) }
        var plan: Plan
        switch op {
        case .toggle(let name, let harness, let on):
            plan = planToggle(name, harness: harness, on: !on)
        case .add(let name):
            plan = planRemove(name)
        case .remove(let name):
            plan = planRestoreRemoved(name, removedIn: entry.id)
        case .adopt(let name, let originals, let links):
            plan = planUnadopt(name, originals: originals, links: links, commit: entry.id)
        case .projectAdd(let name, let project):
            plan = planProjectRemove(name, project: project)
        case .projectRemove(let name, let project):
            plan = planProjectRestore(name, project: project, removedIn: entry.id)
        case .update(let name, let renamed):
            plan = planRevertUpdate(name, updatedIn: entry.id, renamedTo: renamed)
        case .setting:
            return blocked(L("這筆紀錄不能恢復。"))
        case .editDoc(let path, let project):
            plan = planRevertDoc(path: path, project: project, editedIn: entry.id)
        case .undo:
            return blocked(L("這筆是恢復操作本身。"))
        }
        plan.title = title
        plan.op = .undo(of: entry.id)
        if case .commit = plan.steps.last { plan.steps[plan.steps.count - 1] = .commit(title) }
        return plan
    }

    func planRestoreRemoved(_ name: String, removedIn commit: String) -> Plan {
        let original = store.readLock()
        var lock = original
        let title = L("恢復 \(name)")
        let old = (try? store.git.run(["show", "\(commit)^:tackroom.lock"])).map(Lockfile.parse)
        guard let entry = old?.skills[name] else {
            return Plan(title: title, op: .remove(name: name), actor: actor, preview: [], steps: [], blocker: L("找不到移除前的紀錄。"))
        }
        if lock.skills[name] != nil {
            return Plan(title: title, op: .remove(name: name), actor: actor, preview: [], steps: [], blocker: L("「\(name)」已存在。"))
        }
        var steps: [Step] = []
        var preview: [PreviewLine] = []
        if entry.linkedPath == nil {
            steps.append(.restoreFromGit(commit: commit + "^", path: "skills/\(name)"))
            preview.append(PreviewLine(kind: .add, text: L("從紀錄取回 \(name) 的檔案")))
        }
        let target = store.location(of: name, entry: entry)
        for id in entry.harnesses {
            guard let adapter = adapters.first(where: { $0.id == id }) else { continue }
            for link in entryPaths(adapter, name: name, entry: entry) {
                if FileManager.default.fileExists(atPath: link) || isSymlink(link) { continue }
                steps.append(.link(at: link, to: target))
                preview.append(PreviewLine(kind: .add, text: L("\(adapter.name)：新增捷徑 \(short(link))")))
            }
        }
        lock.skills[name] = entry
        steps += [.patchLock(base: original, new: lock), .commit(title)]
        return Plan(title: title, op: .remove(name: name), actor: actor, preview: preview, steps: steps, blocker: nil)
    }

    func planUnadopt(_ name: String, originals: [String], links: [String: String]?, commit: String) -> Plan {
        let original = store.readLock()
        var lock = original
        let title = L("取消管理 \(name)")
        guard let entry = lock.skills[name] else {
            return Plan(title: title, op: .adopt(name: name, originals: originals), actor: actor, preview: [], steps: [],
                        blocker: L("「\(name)」已經不在 Tackroom 裡。"))
        }
        var steps: [Step] = []
        var preview: [PreviewLine] = []
        let source = store.location(of: name, entry: entry)
        guard let text = try? store.git.run(["show", "\(commit):tackroom.lock"]),
              let adopted = Lockfile.parse(text).skills[name], entry.installedAt == adopted.installedAt,
              entry.source == adopted.source, entry.path == adopted.path else {
            return Plan(title: title, op: .undo(of: commit), actor: actor, preview: [], steps: [],
                        blocker: L("找不到相符的收編紀錄。"))
        }
        var restoreLinks = links ?? [:]
        // 舊版只重指向第一個實體原件的捷徑，且每個被接管的入口在 harnesses 各有一筆。
        if links == nil, let firstOriginal = originals.first {
            for adapter in writable {
                let originalsHere = originals.filter { ($0 as NSString).deletingLastPathComponent == writeDir(adapter) }
                let count = adopted.harnesses.filter { $0 == adapter.id }.count - originalsHere.count
                guard count > 0 else { continue }
                let candidates = entryPaths(adapter, name: name, entry: entry).filter {
                    !originals.contains($0) && (pointsTo($0, source) || entry.entryFolders?[adapter.id] != nil)
                }
                guard candidates.count == count else {
                    return Plan(title: title, op: .undo(of: commit), actor: actor, preview: [], steps: [],
                                blocker: L("舊版收編紀錄沒有保存捷徑位置，無法確認 \(adapter.name) 的原入口。"))
                }
                for path in candidates { restoreLinks[path] = firstOriginal }
            }
        }
        if entry.linkedPath == nil {
            var paths = Set(originals + Array(restoreLinks.keys))
            for adapter in writable {
                for path in entryPaths(adapter, name: name, entry: entry) where pointsTo(path, source) {
                    paths.insert(path)
                }
            }
            var checks: [Step] = []
            for path in paths.sorted() {
                let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
                if let raw, raw == restoreLinks[path] { continue }
                if FileManager.default.fileExists(atPath: path) || raw != nil {
                    guard let raw, pointsTo(path, source) else {
                        return Plan(title: title, op: .undo(of: commit), actor: actor, preview: [], steps: [],
                                    blocker: L("原入口已被其他檔案占用：\(short(path))"))
                    }
                    steps.append(.unlinkMatching(path: path, link: raw))
                }
                checks.append(.verifyEntry(path: path, link: raw))
                if originals.contains(path) {
                    steps.append(.createCopy(from: source, to: path))
                    preview.append(PreviewLine(kind: .change, text: L("把檔案放回原處：\(short(path))")))
                } else if let destination = restoreLinks[path] {
                    steps.append(.link(at: path, to: destination))
                    preview.append(PreviewLine(kind: .change, text: L("恢復原捷徑：\(short(path)) → \(destination)")))
                } else {
                    preview.append(PreviewLine(kind: .remove, text: L("移除之後新增的捷徑：\(short(path))")))
                }
            }
            steps = checks + steps + [.trash(source)]
        }
        lock.skills[name] = nil
        steps += [.patchLock(base: original, new: lock), .commit(title)]
        return Plan(title: title, op: .adopt(name: name, originals: originals), actor: actor,
                    preview: preview, steps: steps, blocker: nil)
    }

    // MARK: Projects (copies)

    /// Folders inside the project that a copy goes into, per chosen agent
    /// (agents that share a folder get one copy).
    func projectTargets(_ project: Project, harnesses: [String], name: String) -> [(dir: String, agents: [String])] {
        var order: [String] = []
        var byDir: [String: [String]] = [:]
        for id in harnesses {
            guard let adapter = adapters.first(where: { $0.id == id }), let rel = adapter.projectWriteDir else { continue }
            let dir = ((project.path as NSString).appendingPathComponent(rel) as NSString).appendingPathComponent(SkillName.folder(name))
            if byDir[dir] == nil { order.append(dir) }
            byDir[dir, default: []].append(id)
        }
        return order.map { ($0, byDir[$0]!) }
    }

    /// Other agents that also read a project folder (e.g. Antigravity reads .agents/skills too).
    func alsoReads(_ relativeDir: String, besides chosen: [String]) -> [String] {
        adapters.filter { a in
            !chosen.contains(a.id) && a.roots.contains { $0.scope == .project && relativeDir.hasPrefix($0.path) }
        }.map(\.name)
    }

    /// Copies skills into one project. Copies (not links) so the project still
    /// works on another computer after a git push.
    public func planProjectAdd(_ found: [FoundSkill], project: Project, harnesses: [String], source: String) -> Plan {
        let original = store.readProjectLock(project)
        var lock = original
        var preview: [PreviewLine] = []
        var steps: [Step] = []
        var blocker: String?
        var fileCount = 0
        for skill in found {
            if !SkillName.isSafe(skill.name) { blocker = L("「\(skill.name)」") + SkillName.problem; break }
            if lock.skills[skill.name] != nil { blocker = L("這個專案已經有 Tackroom 裝的「\(skill.name)」。"); break }
            let snapshot = store.projectSnapshot(project, skill.name).path
            steps.append(.copyDir(from: skill.path, to: snapshot))
            let (hash, count, _) = Scanner.hashFolder(skill.path)
            var agents: [String] = []
            for target in projectTargets(project, harnesses: harnesses, name: skill.name) {
                if FileManager.default.fileExists(atPath: target.dir) || isSymlink(target.dir) {
                    blocker = L("專案裡已經有「\(skill.name)」：\(short(target.dir))")
                    break
                }
                steps.append(.copyDir(from: snapshot, to: target.dir))
                let rel = String(target.dir.dropFirst(project.path.count + 1))
                let names = target.agents.compactMap { id in adapters.first { $0.id == id }?.name }
                preview.append(PreviewLine(kind: .add, text: L("新增 \(rel)（\(names.joined(separator: L("、")))）")))
                let others = alsoReads((rel as NSString).deletingLastPathComponent, besides: harnesses)
                if !others.isEmpty {
                    preview.append(PreviewLine(kind: .warning, text: L("\(others.joined(separator: L("、"))) 也會讀到這一份")))
                }
                agents += target.agents
                fileCount += count
            }
            var entry = LockEntry(source: source, path: skill.pathInSource, contentHash: hash, harnesses: agents)
            if entry.remoteURL != nil { entry.upstreamHash = hash }
            let previous = lock
            lock.skills[skill.name] = entry
            if skill.hasScripts { preview.append(PreviewLine(kind: .warning, text: L("\(skill.name) 含有可以執行的程式"))) }
            if found.count > 1 {
                steps.append(.patchLock(base: previous, new: lock, project: project))
                steps.append(.commitAs(title: L("安裝 \(skill.name) 到專案「\(project.name)」"), op: .projectAdd(name: skill.name, project: project)))
            }
        }
        if blocker == nil {
            preview.insert(PreviewLine(kind: .keep, text: L("會在專案資料夾新增 \(fileCount) 個檔案，可能隨 git commit 一起分享出去")), at: 0)
        }
        let title = L("安裝 \(found.map(\.name).joined(separator: L("、"))) 到專案「\(project.name)」")
        if found.count <= 1 {
            steps.append(.patchLock(base: original, new: lock, project: project))
            steps.append(.commit(title))
        }
        return Plan(title: title, op: .projectAdd(name: found.first?.name ?? "", project: project), actor: actor,
                    preview: preview, steps: steps,
                    blocker: found.isEmpty ? L("沒有找到 skill。") : (harnesses.isEmpty ? L("至少選一個 agent。") : blocker))
    }

    /// Removes the project's copies (only the ones Tackroom put there).
    public func planProjectRemove(_ name: String, project: Project) -> Plan {
        let original = store.readProjectLock(project)
        var lock = original
        let title = L("從專案「\(project.name)」移除 \(name)")
        guard let entry = lock.skills[name] else {
            return Plan(title: title, op: .projectRemove(name: name, project: project), actor: actor, preview: [], steps: [],
                        blocker: L("這個專案裡的「\(name)」不是 Tackroom 裝的。"))
        }
        var preview: [PreviewLine] = []
        var steps: [Step] = []
        for target in projectTargets(project, harnesses: entry.harnesses, name: name) {
            guard FileManager.default.fileExists(atPath: target.dir) else { continue }
            let rel = String(target.dir.dropFirst(project.path.count + 1))
            if Scanner.hashFolder(target.dir).0 != entry.contentHash {
                preview.append(PreviewLine(kind: .warning, text: L("\(rel) 在安裝後被改過，移除會連同修改一起移到垃圾桶")))
            }
            steps.append(.trash(target.dir))
            preview.append(PreviewLine(kind: .remove, text: L("移到垃圾桶：\(rel)")))
        }
        steps.append(.trash(store.projectSnapshot(project, name).path))
        lock.skills[name] = nil
        steps.append(.patchLock(base: original, new: lock, project: project))
        steps.append(.commit(title))
        return Plan(title: title, op: .projectRemove(name: name, project: project), actor: actor,
                    preview: preview, steps: steps, blocker: nil)
    }

    func planProjectRestore(_ name: String, project: Project, removedIn commit: String) -> Plan {
        let original = store.readProjectLock(project)
        var lock = original
        let title = L("恢復專案「\(project.name)」的 \(name)")
        let lockRel = String(store.projectLockURL(project).path.dropFirst(store.root.path.count + 1))
        let snapRel = String(store.projectSnapshot(project, name).path.dropFirst(store.root.path.count + 1))
        guard let text = try? store.git.run(["show", "\(commit)^:\(lockRel)"]),
              let entry = Lockfile.parse(text).skills[name] else {
            return Plan(title: title, op: .projectRemove(name: name, project: project), actor: actor, preview: [], steps: [],
                        blocker: L("找不到移除前的紀錄。"))
        }
        var steps: [Step] = [.restoreFromGit(commit: commit + "^", path: snapRel)]
        var preview: [PreviewLine] = []
        for target in projectTargets(project, harnesses: entry.harnesses, name: name) {
            if FileManager.default.fileExists(atPath: target.dir) { continue }
            steps.append(.copyDir(from: store.projectSnapshot(project, name).path, to: target.dir))
            preview.append(PreviewLine(kind: .add, text: L("放回 \(String(target.dir.dropFirst(project.path.count + 1)))")))
        }
        lock.skills[name] = entry
        steps.append(.patchLock(base: original, new: lock, project: project))
        steps.append(.commit(title))
        return Plan(title: title, op: .projectRemove(name: name, project: project), actor: actor,
                    preview: preview, steps: steps, blocker: nil)
    }

    func projectLockText(_ lock: Lockfile, _ project: Project) -> String {
        "# Project: \(project.path)\n" + lock.serialized()
    }

    // MARK: Tags

    public func planSetTag(_ tag: String?, for name: String) -> Plan {
        let original = store.readLock()
        var lock = original
        let title = tag.map { L("把 \(name) 歸到「\($0)」") } ?? L("取消 \(name) 的標籤")
        guard lock.skills[name] != nil else {
            return Plan(title: title, op: .setting(name: name), actor: actor, preview: [], steps: [], blocker: L("只有交由 Tackroom 管理的 skill 能加標籤。"))
        }
        lock.skills[name]?.tags = tag.map { [$0] } ?? []
        return Plan(title: title, op: .setting(name: name), actor: actor, preview: [], steps: [.patchLock(base: original, new: lock), .commit(title)], blocker: nil)
    }

    // MARK: Changes made outside Tackroom

    /// Puts back the version recorded in the lockfile (the last commit).
    public func planRestoreDrift(_ name: String) -> Plan {
        let title = L("把 \(name) 恢復成記錄的版本")
        guard let entry = store.readLock().skills[name], entry.linkedPath == nil else {
            return Plan(title: title, op: .setting(name: name), actor: actor, preview: [], steps: [],
                        blocker: L("此 skill 的檔案位於自訂資料夾，Tackroom 沒有備份；可選擇「接受目前的內容」。"))
        }
        return Plan(title: title, op: .setting(name: name), actor: actor,
                    preview: [PreviewLine(kind: .change, text: L("捨棄 Tackroom 之外的修改，換回記錄的版本"))],
                    // Trash the changed folder first, so files added outside Tackroom go too.
                    steps: [.trash(store.skillDir(name).path), .restoreFromGit(commit: "HEAD", path: "skills/\(name)"),
                            .commit(title)], blocker: nil)
    }

    /// Keeps the files as they are now and records them as approved.
    public func planAcceptDrift(_ name: String) -> Plan {
        let original = store.readLock()
        var lock = original
        let title = L("保留 \(name) 在 Tackroom 之外的修改")
        guard let entry = lock.skills[name] else {
            return Plan(title: title, op: .setting(name: name), actor: actor, preview: [], steps: [], blocker: L("「\(name)」不是由 Tackroom 管理的。"))
        }
        // Older records kept only one hash, written when the files came from
        // upstream at `commit`: keep it as the base before it is replaced,
        // so the kept edits are never mistaken for a new upstream version.
        if entry.upstreamHash == nil, entry.commit != nil, entry.remoteURL != nil {
            lock.skills[name]?.upstreamHash = entry.contentHash
        }
        lock.skills[name]?.contentHash = Scanner.hashFolder(store.location(of: name, entry: entry)).0
        return Plan(title: title, op: .update(name: name), actor: actor,
                    preview: [PreviewLine(kind: .keep, text: L("保留目前的檔案，記為本機版本"))]
                        + (entry.remoteURL != nil ? [PreviewLine(kind: .keep, text: L("之後上游有新版時，會分開顯示你的修改和作者的修改"))] : []),
                    steps: [.include("skills/\(SkillName.folder(name))"), .patchLock(base: original, new: lock), .commit(title)], blocker: nil)
    }

    // MARK: Execute

    var pendingURL: URL { store.stateDir.appendingPathComponent("pending.json") }

    struct Pending: Codable { var plan: Plan; var done: Int }

    /// Runs a plan. Progress is saved after every step, so an interrupted
    /// plan can be finished with `resumePending()`.
    public func execute(_ plan: Plan) throws {
        if let blocker = plan.blocker { throw TackroomError.invalid(blocker) }
        try withWriter {
            guard !FileManager.default.fileExists(atPath: pendingURL.path) else {
                throw TackroomError.conflict(L("請先處理上次未完成的操作。"))
            }
            try run(Pending(plan: plan, done: 0), resuming: false)
        }
    }

    /// 同一個保管區的 GUI、第二個程序與恢復操作共用作業系統的寫入鎖。
    private func withWriter(_ work: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: store.stateDir, withIntermediateDirectories: true)
        let fd = open(store.stateDir.path, O_RDONLY | O_DIRECTORY | O_EXLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try work()
    }

    /// The plan that was interrupted last time, if any.
    public func pendingPlan() -> Plan? {
        guard let data = try? Data(contentsOf: pendingURL),
              let pending = try? JSONDecoder().decode(Pending.self, from: data) else { return nil }
        return pending.plan
    }

    public func resumePending() throws {
        try withWriter {
            guard FileManager.default.fileExists(atPath: pendingURL.path) else { return }
            let data = try Data(contentsOf: pendingURL)
            var pending = try JSONDecoder().decode(Pending.self, from: data)
            try upgradeProjectInstall(&pending)
            try run(pending, resuming: true)
        }
    }

    /// 舊版專案安裝把整份登記存成 writeFile，續作時只取回該筆安裝的 skill。
    private func upgradeProjectInstall(_ pending: inout Pending) throws {
        guard case .projectAdd(var name, let project) = pending.plan.op else { return }
        let path = store.projectLockURL(project).path
        for i in pending.plan.steps.indices.reversed() where i >= pending.done {
            switch pending.plan.steps[i] {
            case .commitAs(_, .projectAdd(let next, _)):
                name = next
            case .writeFile(let target, let contents) where target == path:
                guard let entry = Lockfile.parse(contents).skills[name] else {
                    throw TackroomError.invalid(L("未完成的專案安裝缺少 skill 登記。"))
                }
                pending.plan.steps[i] = .patchLock(base: Lockfile(), new: Lockfile(skills: [name: entry]), project: project)
            default: break
            }
        }
    }

    public func discardPending() {
        try? withWriter { try FileManager.default.removeItem(at: pendingURL) }
    }

    private func run(_ start: Pending, resuming: Bool) throws {
        // 批次中的後續步驟依賴前面預計寫入的版本，先在記憶體裡驗完整批。
        guard (0...start.plan.steps.count).contains(start.done) else {
            throw TackroomError.invalid(L("未完成的操作紀錄無法讀取。"))
        }
        var projected = store.readLock()
        var projects: [Project: Lockfile] = [:]
        let installing = start.plan.isInstall
        for index in start.done..<start.plan.steps.count {
            switch start.plan.steps[index] {
            case .patchLock(let base, let new, let project?):
                try applyPatch(base: base, new: new, to: &projects[project, default: store.readProjectLock(project)],
                               replay: resuming && index == start.done)
            case .patchLock(let base, let new, nil):
                try applyPatch(base: base, new: new, to: &projected, replay: resuming)
            case .copyDir(let from, let to) where installing:
                _ = try alreadyInstalled(from: from, to: to, replay: resuming && index == start.done)
            case .link(let at, _) where installing && !(resuming && index == start.done):
                try requireVacant(at)
            case .writeLock(let legacy):
                projected = legacy
            case .trashReviewed(let name, let entry, let expected), .stageForCaseRename(let name, let entry, let expected, _):
                guard projected.skills[name] == entry else {
                    throw TackroomError.conflict(L("「\(name)」在預覽後已有變更，請重新檢視恢復內容。"))
                }
                try checkReviewedFolder(store.skillDir(name).path, expected: expected, mayAlreadyBeRemoved: resuming && index == start.done)
            default: break
            }
        }
        var pending = start
        // 審閱後過期的更新可直接重試，只有開始寫入才需要中斷復原紀錄。
        verification: while pending.done < pending.plan.steps.count {
            switch pending.plan.steps[pending.done] {
            case .verifyLocal, .verifyHash, .verifyEntry:
                try perform(pending.plan.steps[pending.done], plan: pending.plan, at: pending.done, replay: false)
                pending.done += 1
            default: break verification
            }
        }
        try store.ensureExists()
        try save(pending)
        while pending.done < pending.plan.steps.count {
            try perform(pending.plan.steps[pending.done], plan: pending.plan, at: pending.done,
                        replay: resuming && pending.done == start.done)
            pending.done += 1
            try save(pending)
        }
        try FileManager.default.removeItem(at: pendingURL)
    }

    private func save(_ pending: Pending) throws {
        try JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
    }

    private func applyPatch(base: Lockfile, new: Lockfile, to current: inout Lockfile, replay: Bool) throws {
        for name in Set(base.skills.keys).union(new.skills.keys) where base.skills[name] != new.skills[name] {
            guard current.skills[name] == base.skills[name] || (replay && current.skills[name] == new.skills[name]) else {
                throw TackroomError.conflict(L("「\(name)」在你確認之前已被另一個操作改過。請重新操作一次。"))
            }
            current.skills[name] = new.skills[name]
        }
    }

    private func checkReviewedFolder(_ path: String, expected: String?, mayAlreadyBeRemoved: Bool) throws {
        let current = try Scanner.removalFingerprint(at: path)
        guard current == expected || (mayAlreadyBeRemoved && current == nil) else {
            throw TackroomError.conflict(L("預覽後本機檔案已有變更，請重新檢視恢復內容。"))
        }
    }

    private func requireVacant(_ path: String) throws {
        if FileManager.default.fileExists(atPath: path) || isSymlink(path) {
            throw TackroomError.conflict(L("安裝位置已存在：\(short(path))。請重新檢視。"))
        }
    }

    private func alreadyInstalled(from: String, to: String, replay: Bool) throws -> Bool {
        if replay, let saved = try Scanner.removalFingerprint(at: to),
           saved == (try Scanner.removalFingerprint(at: from)) { return true }
        try requireVacant(to)
        return false
    }

    /// 在同一磁碟準備完整副本，發布時由檔案系統保證不會取代其他程序剛建立的目錄。
    private func installDirectory(from: String, to: String, replay: Bool) throws {
        let fm = FileManager.default
        if try alreadyInstalled(from: from, to: to, replay: replay) { return }
        let parent = URL(fileURLWithPath: to).deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: parent, create: true)
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appendingPathComponent("skill")
        try fm.copyItem(atPath: from, toPath: copy.path)
        guard renamex_np(copy.path, to, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw TackroomError.conflict(L("安裝位置已存在：\(short(to))。請重新檢視。")) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func perform(_ step: Step, plan: Plan, at index: Int, replay: Bool) throws {
        let fm = FileManager.default
        switch step {
        case .verifyEntry(let path, let expected):
            if let expected {
                guard (try? fm.destinationOfSymbolicLink(atPath: path)) == expected else {
                    throw TackroomError.conflict(L("入口已變更：\(short(path))"))
                }
            } else { try requireVacant(path) }
        case .unlinkMatching(let path, let expected):
            if replay, !fm.fileExists(atPath: path), !isSymlink(path) { return }
            guard (try? fm.destinationOfSymbolicLink(atPath: path)) == expected else {
                throw TackroomError.conflict(L("入口已變更：\(short(path))"))
            }
            try fm.removeItem(atPath: path)
        case .renamePreferences(let old, let new):
            let base = store.root.deletingLastPathComponent()
            var tags = TagBook(url: base.appendingPathComponent("tags.json"))
            try tags.renameSkill(old, to: new)
            var pins = Pins(url: base.appendingPathComponent("pins.json"))
            try pins.renameSkill(old, to: new)
        case .createFromGit(let commit, let path):
            let temp = fm.temporaryDirectory.appendingPathComponent("tackroom-restore-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temp) }
            try store.git.export(tree: "\(commit):\(path)", to: temp)
            try installDirectory(from: temp.path, to: store.root.appendingPathComponent(path).path, replay: replay)
        case .createCopy(let from, let to):
            try installDirectory(from: from, to: to, replay: replay)
        case .copyDir(let from, let to) where plan.isInstall:
            try installDirectory(from: from, to: to, replay: replay)
        case .copyDir(let from, let to):
            if fm.fileExists(atPath: to) || isSymlink(to) {
                // A half-finished copy from an earlier attempt: start it over.
                if Scanner.hashFolder(to).0 == Scanner.hashFolder(from).0 { return }
                try fm.removeItem(atPath: to)
            }
            try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.copyItem(atPath: from, toPath: to)
        case .stageForCaseRename(let name, _, let fingerprint, let staging):
            let path = store.skillDir(name).path
            try checkReviewedFolder(path, expected: fingerprint, mayAlreadyBeRemoved: replay)
            if replay && !fm.fileExists(atPath: path) {
                guard let fingerprint, try Scanner.removalFingerprint(at: staging) == fingerprint else {
                    throw TackroomError.conflict(L("找不到符合紀錄的暫存原件。"))
                }
            } else {
                guard renamex_np(path, staging, UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            // Git 在不區分大小寫的磁碟會沿用索引中的舊拼法；先移除舊路徑再登記新名稱。
            try store.git.run(["--literal-pathspecs", "rm", "--cached", "-qr", "--ignore-unmatch", "--", "skills/\(name)"])
        case .trashReviewed(let name, _, let fingerprint):
            let path = store.skillDir(name).path
            try checkReviewedFolder(path, expected: fingerprint, mayAlreadyBeRemoved: replay)
            if fm.fileExists(atPath: path) || isSymlink(path) { try trash(URL(fileURLWithPath: path)) }
        case .trash(let path):
            guard fm.fileExists(atPath: path) || isSymlink(path) else { return }
            if isSymlink(path) { try fm.removeItem(atPath: path) } else { try trash(URL(fileURLWithPath: path)) }
        case .link(let at, let to):
            if isSymlink(at) {
                if (try? fm.destinationOfSymbolicLink(atPath: at)) == to { return }
                throw TackroomError.conflict(L("\(short(at)) 已經是指向別處的捷徑。"))
            }
            if fm.fileExists(atPath: at) { throw TackroomError.conflict(L("\(short(at)) 已經存在。")) }
            try fm.createDirectory(atPath: (at as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: at, withDestinationPath: to)
        case .unlink(let path):
            guard isSymlink(path) else { return }
            try fm.removeItem(atPath: path)
        case .restoreFromGit(let commit, let path):
            try store.git.run(["checkout", commit, "--", path])
        case .writeLock(let lock):
            try store.writeLock(lock)
        case .patchLock(let base, let new, let project?):
            var current = store.readProjectLock(project)
            try applyPatch(base: base, new: new, to: &current, replay: replay)
            try projectLockText(current, project).write(to: store.projectLockURL(project), atomically: true, encoding: .utf8)
        case .patchLock(let base, let new, nil):
            var current = store.readLock()
            try applyPatch(base: base, new: new, to: &current, replay: true)
            try store.writeLock(current)
        case .include:
            break
        case .verifyHash(let path, let hash):
            guard Scanner.hashFolder(path).0 == hash else {
                throw TackroomError.conflict(L("審閱後新版本的檔案又有變更，請重新檢查更新後再審閱。"))
            }
        case .verifyLocal(let path, let hash):
            guard Scanner.hashFolder(path).0 == hash else {
                throw TackroomError.conflict(L("檢查更新之後，本機的檔案又有變更。請重新檢查更新，再審閱一次。"))
            }
        case .writeFile(let path, let contents):
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        case .commit(let title):
            try commit(title, op: plan.op, actor: plan.actor, paths: touched(plan, before: index))
        case .commitAs(let title, let op):
            try commit(title, op: op, actor: plan.actor, paths: touched(plan, before: index))
        }
    }

    /// Store paths written by the steps since the previous commit in this
    /// plan. Only these are committed, so changes made elsewhere in the
    /// store (another skill edited outside Tackroom) stay out of this entry.
    private func touched(_ plan: Plan, before index: Int) -> [String] {
        var start = index
        while start > 0 {
            if case .commit = plan.steps[start - 1] { break }
            if case .commitAs = plan.steps[start - 1] { break }
            start -= 1
        }
        let root = (Paths.realpath(store.root.path) ?? store.root.path) + "/"
        func rel(_ path: String) -> String? {
            let full = Paths.realpath((path as NSString).deletingLastPathComponent).map {
                ($0 as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            } ?? path
            guard full.hasPrefix(root), !full.hasPrefix(root + ".tackroom/") else { return nil }
            return String(full.dropFirst(root.count))
        }
        var paths: [String] = []
        for step in plan.steps[start..<index] {
            switch step {
            case .copyDir(_, let to), .createCopy(_, let to): if let r = rel(to) { paths.append(r) }
            case .trashReviewed(let name, _, _): paths.append("skills/\(SkillName.folder(name))")
            case .trash(let p), .link(let p, _), .unlink(let p), .unlinkMatching(let p, _): if let r = rel(p) { paths.append(r) }
            case .writeFile(let p, _): if let r = rel(p) { paths.append(r) }
            case .restoreFromGit(_, let p), .createFromGit(_, let p), .include(let p): paths.append(p)
            case .patchLock(_, _, let project?):
                if let r = rel(store.projectLockURL(project).path) { paths.append(r) }
            case .writeLock, .patchLock(_, _, nil): paths.append("tackroom.lock")
            default: break
            }
        }
        return Array(Set(paths)).sorted()
    }

    private func commit(_ title: String, op: JournalOp, actor: String, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        // A path that neither exists nor was ever recorded can't be added.
        let tracked = try store.git.run(["--literal-pathspecs", "ls-files", "--"] + paths).split(separator: "\n").map(String.init)
        let present = paths.filter { p in
            FileManager.default.fileExists(atPath: store.root.appendingPathComponent(p).path)
                || tracked.contains { $0 == p || $0.hasPrefix(p + "/") }
        }
        guard !present.isEmpty else { return }
        try store.git.run(["--literal-pathspecs", "add", "-A", "--"] + present)
        let staged = try store.git.run(["diff", "--cached", "--name-only"])
        if staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        try store.git.run(["commit", "-q", "-m", ActivityEntry.message(title: title, actor: actor, op: op)])
    }

    func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

// MARK: - Finding skills to install

public struct FoundSkill: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var description: String
    public var hasScripts: Bool
    /// Folder inside the source (for GitHub installs).
    public var pathInSource: String?
}

public enum SkillFinder {
    /// Skills inside a folder: the folder itself, or up to three levels below it.
    public static func find(in root: String) -> [FoundSkill] {
        let fm = FileManager.default
        var result: [FoundSkill] = []
        func visit(_ dir: String, depth: Int) {
            if fm.fileExists(atPath: (dir as NSString).appendingPathComponent("SKILL.md")) {
                let name = (dir as NSString).lastPathComponent
                guard let copy = Scanner.readEntry(dir, name: name, acceptFlatMarkdown: false) else { return }
                let rel = dir == root ? nil : String(dir.dropFirst(root.count + 1))
                result.append(FoundSkill(name: copy.name, path: dir, description: copy.description,
                                         hasScripts: copy.hasScripts, pathInSource: rel))
                return
            }
            guard depth < 3, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for child in names.sorted() where !child.hasPrefix(".") && child != "node_modules" {
                let path = (dir as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { visit(path, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return result
    }

    /// Unpacks a .zip into a new temporary folder.
    public static func unzip(_ zip: URL) throws -> URL {
        // Look at the names first: nothing may land outside the folder.
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", zip.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = FileHandle.nullDevice
        try list.run()
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        let entries = names.split(separator: "\n")
        if entries.count > 5000 { throw TackroomError.invalid(L("\(zip.lastPathComponent) 內的檔案太多（超過 5000 個），不像是 skill。")) }
        if entries.contains(where: { $0.hasPrefix("/") || $0.split(separator: "/").contains("..") }) {
            throw TackroomError.invalid(L("\(zip.lastPathComponent) 內有檔案會被解到資料夾以外，為了安全不解開。"))
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tackroom-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, out.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TackroomError.invalid(L("無法解開 \(zip.lastPathComponent)")) }
        // Links that lead out of the unpacked folder (to private files, say) are refused.
        if let walker = FileManager.default.enumerator(atPath: out.path) {
            var total = 0
            for case let rel as String in walker {
                let path = out.appendingPathComponent(rel).path
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path), Differ.pointsOutside(target, from: rel) {
                    try? FileManager.default.removeItem(at: out)
                    throw TackroomError.invalid(L("\(zip.lastPathComponent) 內有指向外部的捷徑（\(rel) → \(target)），為了安全不安裝。"))
                }
                total += ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
            }
            if total > 200 * 1024 * 1024 {
                try? FileManager.default.removeItem(at: out)
                throw TackroomError.invalid(L("\(zip.lastPathComponent) 解開後超過 200 MB，不像是 skill。"))
            }
        }
        return out
    }

    /// Downloads a GitHub repo (`owner/repo` or a github.com URL) into a temporary folder.
    public static func fetchGitHub(_ spec: String) throws -> (folder: URL, source: String, commit: String) {
        var repo = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "github:"] where repo.hasPrefix(prefix) {
            repo = String(repo.dropFirst(prefix.count))
        }
        let parts = repo.split(separator: "/").prefix(2).map { String($0).replacingOccurrences(of: ".git", with: "") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { throw TackroomError.invalid(L("無法辨識此網址：\(spec)")) }
        let ownerRepo = parts.joined(separator: "/")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tackroom-gh-\(UUID().uuidString)")
        try Git(directory: FileManager.default.temporaryDirectory)
            .run(["clone", "--depth", "1", "-q", "--", "https://github.com/\(ownerRepo).git", out.path])
        let commit = try Git(directory: out).run(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (out, "github:" + ownerRepo, commit)
    }
}

// MARK: - skills.sh

/// Reads `~/.agents/.skill-lock.json` (written by skills.sh) to learn where a skill came from.
public struct SkillsShLock: Sendable {
    var entries: [String: (source: String, path: String?)] = [:]

    public static func load(url: URL = Paths.home.appendingPathComponent(".agents/.skill-lock.json")) -> SkillsShLock {
        var lock = SkillsShLock()
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = json["skills"] as? [String: [String: Any]] else { return lock }
        for (name, info) in skills {
            guard let source = info["source"] as? String else { continue }
            let type = info["sourceType"] as? String ?? "github"
            let skillPath = (info["skillPath"] as? String).map { ($0 as NSString).deletingLastPathComponent }
            lock.entries[name] = ((type == "github" ? "github:" : "") + source, skillPath)
        }
        return lock
    }

    public func source(for name: String) -> (source: String, path: String?)? { entries[name] }

    /// The git tree id skills.sh recorded for each skill's folder when it
    /// installed it (`skillFolderHash`).
    public static func folderTrees(url: URL = Paths.home.appendingPathComponent(".agents/.skill-lock.json")) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = json["skills"] as? [String: [String: Any]] else { return [:] }
        return skills.compactMapValues { $0["skillFolderHash"] as? String }
    }
}
