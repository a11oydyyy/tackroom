import Foundation
import Testing
@testable import TackroomKit

/// DeepSeek Harness: Tackroom writes links into ~/.dsh/skills.
@Suite(.serialized) struct DSHWriteTests {
    @Test func adoptsFromTheDSHFolderAndTogglesIt() throws {
        let t = try OpsBox(withDSH: true)
        try t.box.skill(".dsh/skills", "tk-dsh")
        let plan = t.ops.planAdopt(try #require(t.group("tk-dsh")))
        #expect(plan.blocker == nil)
        try t.ops.execute(plan)
        #expect(t.isLink(".dsh/skills/tk-dsh"))
        #expect(t.ops.store.readLock().skills["tk-dsh"]?.harnesses == ["deepseek"])
        #expect(t.group("tk-dsh")?.activeHarnessIDs == ["deepseek"])

        try t.ops.execute(t.ops.planToggle("tk-dsh", harness: "codex", on: true))
        #expect(t.isLink(".codex/skills/tk-dsh"))
        try t.ops.execute(t.ops.planToggle("tk-dsh", harness: "deepseek", on: false))
        #expect(!FileManager.default.fileExists(atPath: t.box.path(".dsh/skills/tk-dsh")))
        #expect(t.ops.store.readLock().skills["tk-dsh"]?.harnesses == ["codex"])
    }

    @Test func turningOffSaysWhichCopyDSHFallsBackTo() throws {
        let t = try OpsBox(withDSH: true)
        try t.box.skill(".dsh/skills", "tk-dsh-fall")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-dsh-fall"))))
        try t.box.skill(".agents/skills", "tk-dsh-fall")
        let off = t.ops.planToggle("tk-dsh-fall", harness: "deepseek", on: false)
        #expect(off.preview.contains { $0.kind == .warning && $0.text.hasPrefix("關閉後 DSH 會改用") && $0.text.contains(".agents/skills/tk-dsh-fall") })
        // Its own folder beats ~/.agents/skills, so turning it on needs no note.
        try t.ops.execute(off)
        #expect(!t.ops.planToggle("tk-dsh-fall", harness: "deepseek", on: true).preview.contains { $0.kind == .warning })
        #expect(t.ops.planRemove("tk-dsh-fall").preview.isEmpty == false)
    }

    @Test func aSingleFileSkillOfTheSameNameBlocksTurningOn() throws {
        let t = try OpsBox(withDSH: true)
        try t.box.skill(".codex/skills", "tk-dsh-flat")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-dsh-flat"))))
        try FileManager.default.createDirectory(atPath: t.box.path(".dsh/skills"), withIntermediateDirectories: true)
        try "---\nname: tk-dsh-flat\ndescription: x\n---\n".write(toFile: t.box.path(".dsh/skills/tk-dsh-flat.md"), atomically: true, encoding: .utf8)
        #expect(t.ops.planToggle("tk-dsh-flat", harness: "deepseek", on: true).blocker?.contains("tk-dsh-flat.md") == true)
    }

    @Test func projectCopiesGoToTheDSHFolder() throws {
        let t = try OpsBox(withDSH: true)
        let dirs = t.ops.projectTargets(Project(name: "p", path: "/p"), harnesses: ["deepseek"], name: "x").map(\.dir)
        #expect(dirs == ["/p/.dsh/skills/x"])
    }
}
