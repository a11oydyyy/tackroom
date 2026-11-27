import Foundation
import Testing
@testable import TackroomKit

/// Everything happens inside a throwaway folder: agents, store and Trash.
struct OpsBox {
    let box: Sandbox
    let adapters: [HarnessAdapter]
    let ops: Operations

    init(failTrash: Bool = false, withDSH: Bool = false, extra: [HarnessAdapter] = []) throws {
        box = try Sandbox()
        adapters = [box.adapt(DefaultAdapters.claudeCode), box.adapt(DefaultAdapters.codex)]
            + ((withDSH ? [DefaultAdapters.deepseek] : []) + extra).map(box.adapt)
        let trashDir = box.root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let fail = failTrash
        ops = Operations(store: Store(root: box.root.appendingPathComponent(".tackroom/store")), adapters: adapters,
                         trash: { url in
                             if fail { throw TackroomError.invalid("simulated crash") }
                             try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent + UUID().uuidString))
                         })
    }

    func group(_ name: String) -> SkillGroup? {
        Overview.groups(from: Inventory.scan(adapters: adapters, codexDisabled: [])).first { $0.name == name }
    }

    func isLink(_ rel: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: box.path(rel))[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

@Suite(.serialized) struct OperationsTests {
    @Test func lockfileRoundTrip() {
        var lock = Lockfile()
        lock.skills["a-b"] = LockEntry(source: "github:o/r", path: "skills/a-b", ref: "main", commit: "abc",
                                       contentHash: "sha256:1", harnesses: ["codex"], tags: ["前端"], installedAt: "t")
        #expect(Lockfile.parse(lock.serialized()) == lock)
    }

    @Test func adoptMovesFilesIntoStoreAndLinksBack() throws {
        let t = try OpsBox()
        try t.box.skill(".codex/skills", "tk-adopt")
        let plan = t.ops.planAdopt(try #require(t.group("tk-adopt")))
        #expect(plan.blocker == nil)
        try t.ops.execute(plan)
        #expect(t.isLink(".codex/skills/tk-adopt"))
        #expect(FileManager.default.fileExists(atPath: t.ops.store.skillDir("tk-adopt").appendingPathComponent("SKILL.md").path))
        #expect(t.ops.store.readLock().skills["tk-adopt"]?.harnesses == ["codex"])
        // The agent still finds it, through the link.
        #expect(t.group("tk-adopt")?.activeHarnessIDs == ["codex"])
        #expect(Activity.load(store: t.ops.store).first?.op == .adopt(name: "tk-adopt", originals: [t.box.path(".codex/skills/tk-adopt")]))
    }

    @Test func adoptManyIsOneConfirmButEachSkillHasItsOwnEntry() throws {
        let t = try OpsBox()
        try t.box.skill(".codex/skills", "tk-many-a")
        try t.box.skill(".codex/skills", "tk-many-b")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-many-b"))))  // already managed: skipped
        try t.box.skill(".codex/skills", "tk-many-c")
        let plan = t.ops.planAdoptMany([try #require(t.group("tk-many-a")), try #require(t.group("tk-many-b")),
                                        try #require(t.group("tk-many-c"))])
        #expect(plan.blocker == nil)
        #expect(plan.title == "納入 Tackroom 管理 2 個 skill")
        #expect(plan.preview.contains { $0.text.hasPrefix("tk-many-b 不動") })
        try t.ops.execute(plan)
        #expect(Set(t.ops.store.readLock().skills.keys) == ["tk-many-a", "tk-many-b", "tk-many-c"])
        #expect(t.isLink(".codex/skills/tk-many-a") && t.isLink(".codex/skills/tk-many-c"))
        let entries = Activity.load(store: t.ops.store)
        #expect(entries.prefix(2).map(\.op) == [.adopt(name: "tk-many-c", originals: [t.box.path(".codex/skills/tk-many-c")]),
                                                 .adopt(name: "tk-many-a", originals: [t.box.path(".codex/skills/tk-many-a")])])
        // Each one can be put back by itself.
        try t.ops.execute(t.ops.planUndo(try #require(entries.first)))
        #expect(!t.isLink(".codex/skills/tk-many-c"))
        #expect(t.isLink(".codex/skills/tk-many-a"))
    }

    @Test func toggleAddsAndRemovesOnlyItsLink() throws {
        let t = try OpsBox()
        try t.box.skill(".codex/skills", "tk-toggle")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-toggle"))))
        try t.ops.execute(t.ops.planToggle("tk-toggle", harness: "claude-code", on: true))
        #expect(t.isLink(".claude/skills/tk-toggle"))
        #expect(Set(t.ops.store.readLock().skills["tk-toggle"]!.harnesses) == ["codex", "claude-code"])
        try t.ops.execute(t.ops.planToggle("tk-toggle", harness: "claude-code", on: false))
        #expect(!FileManager.default.fileExists(atPath: t.box.path(".claude/skills/tk-toggle")))
        #expect(t.isLink(".codex/skills/tk-toggle"))
    }

    @Test func toggleRefusesSomeoneElsesFolder() throws {
        let t = try OpsBox()
        try t.box.skill(".codex/skills", "tk-clash")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-clash"))))
        try t.box.skill(".claude/skills", "tk-clash", description: "different")
        #expect(t.ops.planToggle("tk-clash", harness: "claude-code", on: true).blocker != nil)
    }

    @Test func removeThenUndoBringsItBack() throws {
        let t = try OpsBox()
        try t.box.skill(".codex/skills", "tk-remove")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-remove"))))
        try t.ops.execute(t.ops.planRemove("tk-remove"))
        #expect(t.ops.store.readLock().skills["tk-remove"] == nil)
        #expect(!FileManager.default.fileExists(atPath: t.box.path(".codex/skills/tk-remove")))

        let removed = try #require(Activity.load(store: t.ops.store).first)
        #expect(removed.canUndo)
        try t.ops.execute(t.ops.planUndo(removed))
        #expect(t.ops.store.readLock().skills["tk-remove"] != nil)
        #expect(t.isLink(".codex/skills/tk-remove"))
        #expect(FileManager.default.fileExists(atPath: t.box.path(".codex/skills/tk-remove/SKILL.md")))
        #expect(Activity.load(store: t.ops.store).contains { $0.id == removed.id && $0.undone })
    }

    @Test func undoAdoptPutsTheFolderBack() throws {
        let t = try OpsBox()
        try t.box.skill(".codex/skills", "tk-unadopt")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-unadopt"))))
        let adopted = try #require(Activity.load(store: t.ops.store).first)
        try t.ops.execute(t.ops.planUndo(adopted))
        #expect(!t.isLink(".codex/skills/tk-unadopt"))
        #expect(FileManager.default.fileExists(atPath: t.box.path(".codex/skills/tk-unadopt/SKILL.md")))
        #expect(t.ops.store.readLock().skills.isEmpty)
    }

    @Test func addInstallsEveryFoundSkillAndBlocksClashes() throws {
        let t = try OpsBox()
        try t.box.skill("download/pack/skills", "tk-one")
        try t.box.skill("download/pack/skills", "tk-two")
        let found = SkillFinder.find(in: t.box.path("download/pack"))
        #expect(Set(found.map(\.name)) == ["tk-one", "tk-two"])
        try t.ops.execute(t.ops.planAdd(found, harnesses: ["claude-code", "codex"], source: "local:pack"))
        #expect(t.isLink(".claude/skills/tk-one") && t.isLink(".codex/skills/tk-two"))
        #expect(t.ops.planAdd(found, harnesses: ["codex"], source: "local:pack").blocker != nil)
    }

    @Test func linkedSkillStaysInYourFolder() throws {
        let t = try OpsBox()
        let own = try t.box.skill("my-repo/skills", "tk-own")
        try t.box.link(".codex/skills/tk-own", to: own)
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-own"))))
        #expect(t.ops.store.readLock().skills["tk-own"]?.linkedPath == Paths.realpath(own))
        #expect(FileManager.default.fileExists(atPath: own + "/SKILL.md"))
        #expect(!FileManager.default.fileExists(atPath: t.ops.store.skillDir("tk-own").path))
    }

    @Test func interruptedPlanCanBeFinished() throws {
        let crashing = try OpsBox(failTrash: true)
        try crashing.box.skill(".codex/skills", "tk-crash")
        let plan = crashing.ops.planAdopt(try #require(crashing.group("tk-crash")))
        #expect(throws: (any Error).self) { try crashing.ops.execute(plan) }
        #expect(crashing.ops.pendingPlan() != nil)

        // Same folders, Trash working again: finish where it stopped.
        var fixed = crashing.ops
        let trashDir = crashing.box.root.appendingPathComponent(".Trash")
        fixed.trash = { url in try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString)) }
        try fixed.resumePending()
        #expect(fixed.pendingPlan() == nil)
        #expect(crashing.isLink(".codex/skills/tk-crash"))
        #expect(fixed.store.readLock().skills["tk-crash"] != nil)
    }

    @Test func projectInstallCopiesAndCanBeUndone() throws {
        let t = try OpsBox()
        try t.box.skill("download", "tk-proj")
        try FileManager.default.createDirectory(atPath: t.box.path("repo/.git"), withIntermediateDirectories: true)
        let project = Project(name: "repo", path: t.box.path("repo"))
        let found = SkillFinder.find(in: t.box.path("download/tk-proj"))
        let plan = t.ops.planProjectAdd(found, project: project, harnesses: ["claude-code", "codex"], source: "local:download")
        #expect(plan.blocker == nil)
        // Codex writes to .agents/skills, which Antigravity also reads: the preview says so.
        let withAntigravity = Operations(store: t.ops.store, adapters: t.adapters + [t.box.adapt(DefaultAdapters.antigravity)], trash: t.ops.trash)
        #expect(withAntigravity.planProjectAdd(found, project: project, harnesses: ["codex"], source: "x").preview
                    .contains { $0.kind == .warning && $0.text.contains("Antigravity") })
        try t.ops.execute(plan)
        // Real folders, not links, so the project works elsewhere.
        #expect(!t.isLink("repo/.claude/skills/tk-proj"))
        #expect(FileManager.default.fileExists(atPath: t.box.path("repo/.claude/skills/tk-proj/SKILL.md")))
        #expect(FileManager.default.fileExists(atPath: t.box.path("repo/.agents/skills/tk-proj/SKILL.md")))
        #expect(t.ops.store.readProjectLock(project).skills["tk-proj"] != nil)
        // Nothing of Tackroom's own goes into the project.
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.box.path("repo")).sorted() == [".agents", ".claude", ".git"])

        try t.ops.execute(t.ops.planProjectRemove("tk-proj", project: project))
        #expect(!FileManager.default.fileExists(atPath: t.box.path("repo/.claude/skills/tk-proj")))
        #expect(t.ops.store.readProjectLock(project).skills.isEmpty)

        let removed = try #require(Activity.load(store: t.ops.store).first)
        try t.ops.execute(t.ops.planUndo(removed))
        #expect(FileManager.default.fileExists(atPath: t.box.path("repo/.agents/skills/tk-proj/SKILL.md")))
        #expect(t.ops.store.readProjectLock(project).skills["tk-proj"] != nil)
    }

    @Test func occupiedInstallDestinationStopsBeforeAnyCopy() throws {
        let t = try OpsBox()
        let project = Project(name: "Studio", path: t.box.path("Studio"))
        let source = try t.box.skill("source", "late")
        let install = t.ops.planProjectAdd(SkillFinder.find(in: source), project: project,
                                           harnesses: ["claude-code", "codex"], source: "local:source")
        let existing = try t.box.skill("Studio/.agents/skills", "late")
        let draft = URL(fileURLWithPath: existing).appendingPathComponent("draft.txt")
        try "my draft".write(to: draft, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try t.ops.execute(install) }
        #expect(try String(contentsOf: draft, encoding: .utf8) == "my draft")
        #expect(!FileManager.default.fileExists(atPath: t.box.path("Studio/.claude/skills/late")))
        #expect(!FileManager.default.fileExists(atPath: t.ops.store.projectSnapshot(project, "late").path))
        #expect(t.ops.store.readProjectLock(project).skills.isEmpty)
        #expect(t.ops.pendingPlan() == nil)
    }

    @Test func separatePreviewsMergeOnlyTheirProjectRecords() throws {
        let t = try OpsBox()
        let project = Project(name: "Studio", path: t.box.path("Studio"))
        func add(_ name: String) throws -> Plan {
            let path = try t.box.skill("source", name)
            return t.ops.planProjectAdd(SkillFinder.find(in: path), project: project,
                                        harnesses: ["claude-code", "codex"], source: "local:source")
        }
        let a = try add("a"), b = try add("b")
        try t.ops.execute(a)
        let removeA = t.ops.planProjectRemove("a", project: project)
        try t.ops.execute(b)
        #expect(Set(t.ops.store.readProjectLock(project).skills.keys) == ["a", "b"])
        try t.ops.execute(removeA)
        #expect(Set(t.ops.store.readProjectLock(project).skills.keys) == ["b"])
        let undo = t.ops.planUndo(try #require(Activity.load(store: t.ops.store).first))
        try t.ops.execute(add("c"))
        try t.ops.execute(undo)
        #expect(Set(t.ops.store.readProjectLock(project).skills.keys) == ["a", "b", "c"])
        for name in ["a", "b", "c"] {
            for root in [".claude", ".agents"] {
                #expect(FileManager.default.fileExists(atPath: t.box.path("Studio/\(root)/skills/\(name)/SKILL.md")))
            }
        }
    }

    @Test func recoveryPreservesAnIndependentFolderAndLegacyProjectRecords() throws {
        let t = try OpsBox()
        let project = Project(name: "Studio", path: t.box.path("Studio"))
        let dir = try t.box.skill("source", "a")
        let other = try t.box.skill("source", "b")
        var plan = t.ops.planProjectAdd(SkillFinder.find(in: dir), project: project, harnesses: ["codex"], source: "x")
        // 模擬舊版的計畫，已複製保管區快照，但還未記錄第一步完成。
        let snapshot = t.ops.store.projectSnapshot(project, "a")
        for i in plan.steps.indices {
            if case .patchLock(_, let lock, _) = plan.steps[i] {
                plan.steps[i] = .writeFile(path: t.ops.store.projectLockURL(project).path, contents: t.ops.projectLockText(lock, project))
            }
        }
        try t.ops.execute(t.ops.planProjectAdd(SkillFinder.find(in: other), project: project, harnesses: ["codex"], source: "y"))
        try FileManager.default.copyItem(atPath: dir, toPath: snapshot.path)
        let note = snapshot.appendingPathComponent("draft.swp")
        try "mine".write(to: note, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(Operations.Pending(plan: plan, done: 0)).write(to: t.ops.pendingURL)
        #expect(throws: (any Error).self) { try t.ops.resumePending() }
        #expect(try String(contentsOf: note, encoding: .utf8) == "mine")
        try FileManager.default.removeItem(at: note)
        try t.ops.resumePending()
        #expect(Set(t.ops.store.readProjectLock(project).skills.keys) == ["a", "b"])
        #expect(t.ops.pendingPlan() == nil)
    }

    @Test func projectRemovalProposalCanOnlyRemoveFromTheRequestedProject() throws {
        let t = try OpsBox()
        let project = Project(name: "Studio", path: t.box.path("Studio"))
        let found = SkillFinder.find(in: try t.box.skill("source", "a"))
        try t.ops.execute(t.ops.planAdd(found, harnesses: ["claude-code", "codex"], source: "x"))
        try t.ops.execute(t.ops.planProjectAdd(found, project: project, harnesses: ["claude-code", "codex"], source: "x"))
        let request = Proposal(agent: "codex", kind: .projectRemove(name: "a", path: project.path), reason: "test")
        #expect(t.ops.plan(for: request, groups: []).blocker != nil)
        let legacy = try JSONDecoder().decode(Proposal.Kind.self, from: Data(#"{"remove":{"name":"a"}}"#.utf8))
        #expect(t.ops.plan(for: Proposal(agent: "codex", kind: legacy, reason: "test"), groups: []).blocker != nil)
        try t.ops.execute(t.ops.plan(for: request, groups: [], project: project))
        #expect(t.ops.store.readProjectLock(project).skills.isEmpty)
        #expect(t.ops.store.readLock().skills["a"] != nil)
        #expect(t.isLink(".claude/skills/a") && t.isLink(".codex/skills/a"))
        #expect(Activity.load(store: t.ops.store).first?.op == .projectRemove(name: "a", project: project))
    }

    @Test func projectRemoveLeavesOtherFoldersAlone() throws {
        let t = try OpsBox()
        try t.box.skill("repo/.claude/skills", "tk-theirs")
        let project = Project(name: "repo", path: t.box.path("repo"))
        #expect(t.ops.planProjectRemove("tk-theirs", project: project).blocker != nil)
    }
}
