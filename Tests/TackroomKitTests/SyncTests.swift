import Foundation
import Testing
@testable import TackroomKit

/// Local edits and upstream updates are told apart (all in a throwaway
/// folder; a local git repo stands in for GitHub).
@Suite(.serialized) struct SyncTests {
    let body = "---\nname: tk-up\ndescription: v1\n---\nStep one.\n\nStep two.\n\nStep three.\n"

    func installed() throws -> (OpsBox, Upstream, UpdateChecker) {
        let t = try OpsBox()
        let up = try Upstream(in: t.box)
        try up.write("skills/tk-up/SKILL.md", body)
        try up.commit("v1 body")
        let checker = UpdateChecker(store: t.ops.store, cacheRoot: t.box.root.appendingPathComponent("cache"),
                                    skillsShLock: t.box.root.appendingPathComponent("no-skills-sh.json"))
        let found = SkillFinder.find(in: up.dir.path)
        let commit = try Git(directory: up.dir).run(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try t.ops.execute(t.ops.planAdd(found, harnesses: ["codex"], source: "git:" + up.url, commit: commit))
        return (t, up, checker)
    }

    func skillFile(_ t: OpsBox) -> URL { t.ops.store.skillDir("tk-up").appendingPathComponent("SKILL.md") }
    func installedText(_ t: OpsBox) throws -> String { try String(contentsOf: skillFile(t), encoding: .utf8) }

    @Test func installRecordsTheUpstreamBase() throws {
        let (t, _, _) = try installed()
        let entry = try #require(t.ops.store.readLock().skills["tk-up"])
        #expect(entry.upstreamHash == entry.contentHash)
        #expect(entry.hasLocalEdits == false)
    }

    @Test func aLocalEditIsNotAnUpdate() throws {
        let (t, _, checker) = try installed()
        // Even one extra space: a local change, not a new version.
        try (body + " ").write(to: skillFile(t), atomically: true, encoding: .utf8)
        let r = checker.run()
        #expect(r.updates.isEmpty)
        #expect(r.status["tk-up"] == .current)
        #expect(t.ops.store.driftedNames(t.ops.store.readLock()) == ["tk-up"])

        // Keeping the edit still doesn't turn it into an update.
        try t.ops.execute(t.ops.planAcceptDrift("tk-up"))
        #expect(checker.run().updates.isEmpty)
        #expect(t.ops.store.readLock().skills["tk-up"]?.hasLocalEdits == true)
    }

    @Test func editorLeftoversAreNotChanges() throws {
        let (t, _, _) = try installed()
        let dir = t.ops.store.skillDir("tk-up")
        try "x".write(to: dir.appendingPathComponent(".SKILL.md.swp"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("._SKILL.md"), atomically: true, encoding: .utf8)
        #expect(t.ops.store.driftedNames(t.ops.store.readLock()).isEmpty)
    }

    @Test func cleanUpdateWhenOnlyUpstreamChanged() throws {
        let (_, up, checker) = try installed()
        try up.write("skills/tk-up/SKILL.md", body.replacingOccurrences(of: "Step three.", with: "Step three, better."))
        try up.commit("v2")
        let u = try #require(checker.run().updates.first)
        #expect(u.local == LocalChange.none)
        #expect(u.basePath != nil)
    }

    @Test func bothChangedMergesWhenTheyDontOverlap() throws {
        let (t, up, checker) = try installed()
        try body.replacingOccurrences(of: "Step one.", with: "Step one, my way.").write(to: skillFile(t), atomically: true, encoding: .utf8)
        try t.ops.execute(t.ops.planAcceptDrift("tk-up"))
        try up.write("skills/tk-up/SKILL.md", body.replacingOccurrences(of: "Step three.", with: "Step three, new."))
        try up.write("skills/tk-up/notes.md", "new file\n")
        try up.commit("v2")

        let u = try #require(checker.run().updates.first)
        #expect(u.local == .edited(whitespaceOnly: false))
        // What the author changed leaves out the user's own edit.
        let authorChanges = Differ.compare(old: try #require(u.basePath), new: u.newPath)
        #expect(Set(authorChanges.map(\.path)) == ["SKILL.md", "notes.md"])
        #expect(!(authorChanges.first { $0.path == "SKILL.md" }?.lines ?? []).contains { $0.kind == .removed && $0.text.contains("my way") })

        let merge = try Merger.merge(base: u.basePath!, local: u.oldPath, new: u.newPath,
                                     into: t.box.root.appendingPathComponent("merged"))
        #expect(merge.conflicts.isEmpty)
        try t.ops.execute(t.ops.planMergeUpdate(u, merge: merge))
        let text = try installedText(t)
        #expect(text.contains("my way") && text.contains("Step three, new."))
        #expect(FileManager.default.fileExists(atPath: t.ops.store.skillDir("tk-up").appendingPathComponent("notes.md").path))
        // Merged: no update left, no outside change, and the edits are still known as edits.
        #expect(checker.run().updates.isEmpty)
        #expect(t.ops.store.driftedNames(t.ops.store.readLock()).isEmpty)
        #expect(t.ops.store.readLock().skills["tk-up"]?.hasLocalEdits == true)
    }

    @Test func overlappingChangesAreNotMerged() throws {
        let (t, up, checker) = try installed()
        try body.replacingOccurrences(of: "Step two.", with: "Step two, mine.").write(to: skillFile(t), atomically: true, encoding: .utf8)
        try up.write("skills/tk-up/SKILL.md", body.replacingOccurrences(of: "Step two.", with: "Step two, theirs."))
        try up.commit("v2")
        let u = try #require(checker.run().updates.first)
        let merge = try Merger.merge(base: u.basePath!, local: u.oldPath, new: u.newPath,
                                     into: t.box.root.appendingPathComponent("merged"))
        #expect(merge.conflicts == ["SKILL.md"])
        #expect(t.ops.planMergeUpdate(u, merge: merge).blocker != nil)

        // Using the new version replaces the edit, and undo brings it back.
        try t.ops.execute(t.ops.planApplyUpdate(u))
        #expect(try installedText(t).contains("theirs"))
        let entry = try #require(Activity.load(store: t.ops.store).first)
        try t.ops.execute(t.ops.planUndo(entry))
        // Undo brings back the edit, even though it was never recorded.
        #expect(try installedText(t).contains("mine"))
    }

    @Test func applyStopsIfLocalFilesChangedAfterReview() throws {
        let (t, up, checker) = try installed()
        try up.write("skills/tk-up/SKILL.md", body + "More.\n")
        try up.commit("v2")
        let u = try #require(checker.run().updates.first)
        try (body + "typed meanwhile\n").write(to: skillFile(t), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try t.ops.execute(t.ops.planApplyUpdate(u)) }
        #expect(try installedText(t).contains("typed meanwhile"))
    }

    @Test func skipIsByContentSoUnrelatedCommitsDontBringItBack() throws {
        let (t, up, checker) = try installed()
        try up.write("skills/tk-up/SKILL.md", body + "v2\n")
        try up.commit("v2")
        try t.ops.execute(t.ops.planSkipUpdate(try #require(checker.run().updates.first)))
        try up.write("README.md", "unrelated")
        try up.commit("docs")
        let r = checker.run()
        #expect(r.updates.isEmpty)
        #expect(r.status["tk-up"] == .skipped)
        try up.write("skills/tk-up/SKILL.md", body + "v3\n")
        try up.commit("v3")
        #expect(checker.run().updates.count == 1)
    }

    @Test func whitespaceOnlyEditsAreNamed() throws {
        let (t, up, checker) = try installed()
        try body.replacingOccurrences(of: "\n", with: "\r\n").write(to: skillFile(t), atomically: true, encoding: .utf8)
        try up.write("skills/tk-up/SKILL.md", body + "v2\n")
        try up.commit("v2")
        #expect(try #require(checker.run().updates.first).local == .edited(whitespaceOnly: true))
    }

    /// Records from before the base was kept (or taken over from skills.sh):
    /// the upstream history is searched for the matching version.
    func forgetBase(_ t: OpsBox) throws {
        var lock = t.ops.store.readLock()
        lock.skills["tk-up"]?.upstreamHash = nil
        lock.skills["tk-up"]?.commit = nil
        try t.ops.store.writeLock(lock)
    }

    @Test func oldRecordsFindTheirBaseInUpstreamHistory() throws {
        let (t, up, checker) = try installed()
        try forgetBase(t)
        try up.write("skills/tk-up/SKILL.md", body + "v2\n")
        try up.commit("v2")
        let r = checker.run()
        let u = try #require(r.updates.first)
        #expect(u.local == LocalChange.none)
        #expect(u.fromCommit != nil)
        #expect(r.foundBases["tk-up"] != nil)
    }

    @Test func oldRecordsWithEditsAndNoMatchSayUnknown() throws {
        let (t, up, checker) = try installed()
        try forgetBase(t)
        try (body + "mine\n").write(to: skillFile(t), atomically: true, encoding: .utf8)
        try t.ops.execute(t.ops.planAcceptDrift("tk-up"))
        try up.write("skills/tk-up/SKILL.md", body + "v2\n")
        try up.commit("v2")
        #expect(try #require(checker.run().updates.first).local == .unknown)
    }

    @Test func skillsShFolderHashGivesTheBaseOfAnEditedCopy() throws {
        let (t, up, _) = try installed()
        try forgetBase(t)
        try (body + "mine\n").write(to: skillFile(t), atomically: true, encoding: .utf8)
        try t.ops.execute(t.ops.planAcceptDrift("tk-up"))
        let tree = try Git(directory: up.dir).run(["rev-parse", "HEAD:skills/tk-up"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let skillsSh = t.box.root.appendingPathComponent("skill-lock.json")
        try #"{"version":3,"skills":{"tk-up":{"source":"x/y","skillFolderHash":"\#(tree)"}}}"#
            .write(to: skillsSh, atomically: true, encoding: .utf8)
        try up.write("skills/tk-up/SKILL.md", body + "v2\n")
        try up.commit("v2")
        let checker = UpdateChecker(store: t.ops.store, cacheRoot: t.box.root.appendingPathComponent("cache2"), skillsShLock: skillsSh)
        #expect(try #require(checker.run().updates.first).local == .edited(whitespaceOnly: false))
    }

    @Test func checkingAgainWithoutFetchingSeesLocalChanges() throws {
        let (t, up, checker) = try installed()
        try up.write("skills/tk-up/SKILL.md", body + "v2\n")
        try up.commit("v2")
        #expect(checker.run().updates.first?.local == LocalChange.none)
        try (body + "mine\n").write(to: skillFile(t), atomically: true, encoding: .utf8)
        #expect(checker.run(fetch: false).updates.first?.local == .edited(whitespaceOnly: false))
    }

    @Test func linkedSkillsAreNotOutsideChanges() throws {
        let t = try OpsBox()
        let own = try t.box.skill("own", "tk-own")
        try t.box.link(".codex/skills/tk-own", to: own)
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-own"))))
        #expect(t.ops.store.readLock().skills["tk-own"]?.linkedPath != nil)
        try "changed".write(toFile: own + "/SKILL.md", atomically: true, encoding: .utf8)
        #expect(t.ops.store.driftedNames(t.ops.store.readLock()).isEmpty)
    }

    @Test func lockfileKeepsTheBase() {
        var lock = Lockfile()
        lock.skills["a"] = LockEntry(source: "github:o/r", commit: "abc", contentHash: "sha256:2", upstreamHash: "sha256:1",
                                     harnesses: [], installedAt: "t")
        #expect(Lockfile.parse(lock.serialized()) == lock)
    }
}
