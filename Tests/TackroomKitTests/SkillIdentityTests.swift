import Foundation
import Testing
@testable import TackroomKit

@Suite(.serialized) struct SkillIdentityTests {
    @Test func aliasSurvivesToggleRemoveAndRestore() throws {
        let t = try OpsBox()
        let original = try t.box.skill(".codex/skills", "skill-name")
        let alias = t.box.path(".codex/skills/folder-name")
        try FileManager.default.moveItem(atPath: original, toPath: alias)
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("skill-name"))))
        #expect(t.ops.store.readLock().skills["skill-name"]?.entryFolders == ["codex": ["folder-name"]])
        try t.ops.execute(t.ops.planToggle("skill-name", harness: "codex", on: false))
        #expect(t.group("skill-name") == nil)
        try t.ops.execute(t.ops.planToggle("skill-name", harness: "codex", on: true))
        #expect(t.group("skill-name")?.placements.map(\.copy.entryPath) == [alias])
        try t.ops.execute(t.ops.planRemove("skill-name"))
        #expect(!t.isLink(".codex/skills/folder-name"))
        try t.ops.execute(t.ops.planUndo(try #require(Activity.load(store: t.ops.store).first)))
        #expect(t.group("skill-name")?.placements.map(\.copy.entryPath) == [alias])
    }

    @Test func oldRecordWithDuplicateAliasReopensOnlyOriginal() throws {
        let t = try OpsBox()
        let found = SkillFinder.find(in: try t.box.skill("src", "a"))
        try t.ops.execute(t.ops.planAdd(found, harnesses: ["codex"], source: "x"))
        try t.box.link(".codex/skills/old-folder", to: t.ops.store.skillDir("a").path)
        try t.ops.execute(t.ops.planToggle("a", harness: "codex", on: false))
        #expect(t.group("a") == nil)
        try t.ops.execute(t.ops.planToggle("a", harness: "codex", on: true))
        #expect(t.group("a")?.placements.map(\.copy.entryPath) == [t.box.path(".codex/skills/old-folder")])
    }

    @Test func undoRestoresOriginalRelativeSymlinkAndProtectsOccupiedPaths() throws {
        let t = try OpsBox()
        let folder = try t.box.skill(".claude/skills", "shared")
        let destination = "../../.claude/skills/shared"
        try t.box.link(".codex/skills/shared", to: destination)
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("shared"))))
        let adopted = try #require(Activity.load(store: t.ops.store).first)
        let plan = t.ops.planUndo(adopted)
        let path = t.box.path(".codex/skills/shared")
        try FileManager.default.removeItem(atPath: path)
        try t.box.link(".codex/skills/shared", to: t.box.path("foreign"))
        #expect(throws: (any Error).self) { try t.ops.execute(plan) }
        #expect(t.isLink(".claude/skills/shared"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == t.box.path("foreign"))
        try FileManager.default.removeItem(atPath: path)
        try t.ops.execute(t.ops.planUndo(adopted))
        #expect(!t.isLink(".claude/skills/shared"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == destination)
        #expect(Paths.realpath(path) == Paths.realpath(folder))
        #expect(Set(try #require(t.group("shared")).activeHarnessIDs) == ["codex", "claude-code"])
    }

    @Test func legacyAdoptionRecoversKnownTargetAndRefusesAmbiguousAliases() throws {
        let t = try OpsBox()
        let original = try t.box.skill(".claude/skills", "shared")
        try t.box.link(".codex/skills/shared", to: original)
        var plan = t.ops.planAdopt(try #require(t.group("shared")))
        let oldJournal = #"{"adopt":{"name":"shared","originals":[]}}"#
        guard case .adopt(_, _, let missing) = try JSONDecoder().decode(JournalOp.self, from: Data(oldJournal.utf8)) else {
            Issue.record("舊版收編紀錄無法讀取"); return
        }
        #expect(missing == nil)
        plan.op = .adopt(name: "shared", originals: [original], links: missing)
        try t.ops.execute(plan)
        let adopted = try #require(Activity.load(store: t.ops.store).first)
        let target = t.ops.store.skillDir("shared").path
        try t.box.link(".codex/skills/another", to: target)
        #expect(t.ops.planUndo(adopted).blocker != nil)
        #expect(t.isLink(".claude/skills/shared"))
        try FileManager.default.removeItem(atPath: t.box.path(".codex/skills/another"))
        try t.ops.execute(t.ops.planUndo(adopted))
        #expect(!t.isLink(".claude/skills/shared"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: t.box.path(".codex/skills/shared")) == original)
    }

    @Test func renameMovesBothEntriesAndCanBeReversedAfterToggle() throws {
        let (t, up, checker) = try UpdatesTests().installed()
        try t.ops.execute(t.ops.planToggle("tk-up", harness: "claude-code", on: true))
        try up.write("skills/tk-up/SKILL.md", "---\nname: new-name\ndescription: v2\n---\n")
        try up.commit("rename")
        let update = try #require(checker.run().updates.first)
        let before = t.ops.planApplyUpdate(update)
        let collision = try t.box.skill(".claude/skills", "new-name")
        #expect(throws: (any Error).self) { try t.ops.execute(before) }
        #expect(t.ops.planApplyUpdate(update).blocker != nil)
        try FileManager.default.removeItem(atPath: collision)
        try t.ops.execute(t.ops.planApplyUpdate(update))
        let applied = try #require(Activity.load(store: t.ops.store).first)
        #expect(applied.op == .update(name: "tk-up", renamedTo: "new-name"))
        #expect(Set(t.ops.store.readLock().skills.keys) == ["new-name"])
        #expect(t.group("tk-up") == nil)
        #expect(Set(try #require(t.group("new-name")).activeHarnessIDs) == ["codex", "claude-code"])
        #expect(checker.run().updates.isEmpty)
        try t.ops.execute(t.ops.planToggle("new-name", harness: "codex", on: false))
        try t.ops.execute(t.ops.planUndo(applied))
        #expect(Set(t.ops.store.readLock().skills.keys) == ["tk-up"])
        #expect(t.group("new-name") == nil)
        #expect(t.group("tk-up")?.activeHarnessIDs == ["claude-code"])
        #expect(checker.run().updates.first?.renamedTo == "new-name")
    }

    @Test func caseOnlyUpdateJournalsExactNamesInBothDirections() throws {
        let (t, up, checker) = try UpdatesTests().installed()
        try t.ops.execute(t.ops.planToggle("tk-up", harness: "claude-code", on: true))
        let store = t.ops.store
        func verify(_ name: String) throws {
            let expected = Set(["codex", "claude-code"])
            #expect(Set(store.readLock().skills.keys) == [name])
            #expect(Set(store.readLock().skills[name]?.harnesses ?? []) == expected)
            #expect(Set(try #require(t.group(name)).activeHarnessIDs) == expected)
            let files = FileManager.default
            #expect(try files.contentsOfDirectory(atPath: store.skillsDir.path) == [name])
            for root in [".codex/skills", ".claude/skills"] {
                #expect(try files.contentsOfDirectory(atPath: t.box.path(root)) == [name])
                #expect(try files.destinationOfSymbolicLink(atPath: t.box.path(root + "/" + name)) == store.skillDir(name).path)
            }
            let tree = try store.git.run(["ls-tree", "--name-only", "HEAD:skills"])
            #expect(tree.split(separator: "\n").map(String.init) == [name])
            #expect(try store.git.run(["show", "HEAD:skills/\(name)/SKILL.md"]).contains("name: " + name))
        }
        try up.write("skills/tk-up/SKILL.md", "---\nname: TK-up\ndescription: v1\n---\nDo the thing.\n")
        try up.commit("change case")
        let plan = t.ops.planApplyUpdate(try #require(checker.run().updates.first))
        #expect(plan.blocker == nil)
        // 模擬原件已移到暫存、程序還沒記下這一步就中斷。
        if let index = plan.steps.firstIndex(where: {
            if case .stageForCaseRename = $0 { return true }
            return false
        }), case .stageForCaseRename(_, _, _, let staging) = plan.steps[index] {
            try FileManager.default.moveItem(atPath: store.skillDir("tk-up").path, toPath: staging)
            try JSONEncoder().encode(Operations.Pending(plan: plan, done: index)).write(to: t.ops.pendingURL)
            try t.ops.resumePending()
        } else {
            try t.ops.execute(plan)
        }
        try verify("TK-up")
        let update = try #require(Activity.load(store: store).first)
        #expect(update.op == .update(name: "tk-up", renamedTo: "TK-up"))
        try t.ops.execute(t.ops.planUndo(update))
        try verify("tk-up")
        #expect(Activity.load(store: store).first?.op == .undo(of: update.id))
    }

    @Test func legacySplitCanBeReconciledWithoutDroppingLocalFiles() throws {
        let (t, up, checker) = try UpdatesTests().installed()
        try up.write("skills/tk-up/SKILL.md", "---\nname: renamed\ndescription: v2\n---\n")
        try up.commit("rename")
        let change = try #require(checker.run().updates.first)
        let base = t.ops.store.readLock()
        var lock = base
        lock.skills["tk-up"]?.commit = change.toCommit
        lock.skills["tk-up"]?.contentHash = change.newHash
        lock.skills["tk-up"]?.upstreamHash = change.newHash
        let oldPlan = Plan(title: "legacy", op: .update(name: "tk-up"), actor: "gui", preview: [],
                           steps: [.copyDir(from: change.newPath, to: change.oldPath), .patchLock(base: base, new: lock), .commit("legacy")], blocker: nil)
        try t.ops.execute(oldPlan)
        let historical = try #require(Activity.load(store: t.ops.store).first)
        let draft = "draft.swp"
        try "saved".write(to: t.ops.store.skillDir("tk-up").appendingPathComponent(draft), atomically: true, encoding: .utf8)
        try t.ops.execute(t.ops.planApplyUpdate(try #require(checker.run().updates.first)))
        #expect(try String(contentsOf: t.ops.store.skillDir("renamed").appendingPathComponent(draft), encoding: .utf8) == "saved")
        #expect(Set(t.ops.store.readLock().skills.keys) == ["renamed"])
        try t.ops.execute(t.ops.planUndo(historical))
        #expect(t.group("tk-up")?.activeHarnessIDs == ["codex"])
        #expect(t.group("renamed") == nil)
    }
}
