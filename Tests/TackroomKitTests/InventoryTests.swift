import Foundation
import Testing
@testable import TackroomKit

/// Builds a throwaway home with skill folders, so tests never touch the real ones.
struct Sandbox {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tackroom-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    @discardableResult
    func skill(_ dir: String, _ name: String, description: String = "test", extra: String = "") throws -> String {
        let folder = root.appendingPathComponent(dir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n\(extra)---\nbody\n"
            .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return folder.path
    }

    func link(_ from: String, to target: String) throws {
        let url = root.appendingPathComponent(from)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    /// Rewrites an adapter's `~` roots to point inside the sandbox.
    func adapt(_ adapter: HarnessAdapter) -> HarnessAdapter {
        var a = adapter
        a.roots = a.roots.map { r in
            var r = r
            if r.path.hasPrefix("~/") { r.path = path(String(r.path.dropFirst(2))) }
            return r
        }
        if let w = a.writeDir, w.hasPrefix("~/") { a.writeDir = path(String(w.dropFirst(2))) }
        return a
    }
}

@Test func frontmatterShapes() {
    let fm = Frontmatter.parse("---\nname: x\ndescription: >\n  folded\n  text\ndisable-model-invocation: yes\n---\nbody")
    #expect(fm?.name == "x")
    #expect(fm?.description == "folded text")
    #expect(fm?.bool("disable-model-invocation") == true)
    let quoted = Frontmatter.parse("---\nname: \"y\"\ndescription: 'it''s fine'\n---\n")
    #expect(quoted?.name == "y")
    #expect(quoted?.description == "it's fine")
    #expect(Frontmatter.parse("no frontmatter") == nil)
}

@Test func symlinksAreFollowedAndBrokenOnesFlagged() throws {
    let box = try Sandbox()
    let target = try box.skill("elsewhere", "linked")
    try box.link(".claude/skills/linked", to: target)
    try box.link(".claude/skills/gone", to: box.path("nowhere/gone"))
    let results = Inventory.scan(adapters: [box.adapt(DefaultAdapters.claudeCode)], codexDisabled: [])
    let placements = results[0].placements
    let linked = try #require(placements.first { $0.copy.name == "linked" })
    #expect(linked.copy.isSymlink)
    #expect(linked.state == .loaded)
    let gone = try #require(placements.first { $0.copy.name == "gone" })
    #expect(gone.copy.isBrokenLink)
    #expect(gone.state == .notLoadable("連結失效"))
}

@Test func claudePrefersGlobalOverProject() throws {
    let box = try Sandbox()
    try box.skill(".claude/skills", "same", description: "global")
    try box.skill("proj/.claude/skills", "same", description: "project")
    let project = Project(name: "proj", path: box.path("proj"))
    let p = Inventory.scan(adapters: [box.adapt(DefaultAdapters.claudeCode)], project: project, codexDisabled: [])[0].placements
    #expect(p.first { $0.copy.description == "global" }?.state == .loaded)
    #expect(p.first { $0.copy.description == "project" }?.state.isActive == false)
}

@Test func codexListsEveryCopy() throws {
    let box = try Sandbox()
    try box.skill(".agents/skills", "same")
    try box.skill(".codex/skills", "same")
    let p = Inventory.scan(adapters: [box.adapt(DefaultAdapters.codex)], codexDisabled: [])[0].placements
    #expect(p.count == 2)
    #expect(p.allSatisfy { $0.state == .loadedDuplicate })
    let groups = Overview.groups(from: Inventory.scan(adapters: [box.adapt(DefaultAdapters.codex)], codexDisabled: []))
    #expect(groups.first?.issues.contains(.duplicate(harnessID: "codex")) == true)
}

@Test func codexConfigSwitchTurnsOneSkillOff() throws {
    let box = try Sandbox()
    let folder = try box.skill(".agents/skills", "off")
    let p = Inventory.scan(adapters: [box.adapt(DefaultAdapters.codex)],
                           codexDisabled: [folder + "/SKILL.md"])[0].placements
    #expect(p.first?.state == .disabledInConfig)
}

@Test func dshStubHidesSharedSkillOnlyForDSH() throws {
    let box = try Sandbox()
    try box.skill(".agents/skills", "shared")
    try box.skill(".dsh/skills", "shared", extra: "disable-model-invocation: true\nuser-invocable: false\n")
    let results = Inventory.scan(adapters: [box.adapt(DefaultAdapters.deepseek), box.adapt(DefaultAdapters.codex)], codexDisabled: [])
    let dsh = results[0].placements
    #expect(dsh.contains { $0.state == .disabledStub })
    #expect(dsh.contains { if case .hiddenByStub = $0.state { return true } else { return false } })
    #expect(results[1].placements.first?.state == .loaded)
}

@Test func dshProjectOrder() throws {
    let box = try Sandbox()
    try FileManager.default.createDirectory(atPath: box.path("repo/.git"), withIntermediateDirectories: true)
    try box.skill("repo/.agents/skills", "s", description: "project-agents")
    try box.skill("repo/.dsh/skills", "s", description: "project-dsh")
    try box.skill(".dsh/skills", "s", description: "user-dsh")
    let p = Inventory.scan(adapters: [box.adapt(DefaultAdapters.deepseek)],
                           project: Project(name: "repo", path: box.path("repo")), codexDisabled: [])[0].placements
    #expect(p.first { $0.state == .loaded }?.copy.description == "project-dsh")
}

@Test func sameFolderUnderTwoPathsCountsOnce() throws {
    let box = try Sandbox()
    try box.skill(".gemini/config/skills", "a")
    try FileManager.default.createDirectory(atPath: box.path(".gemini/antigravity"), withIntermediateDirectories: true)
    try box.link(".gemini/antigravity/skills", to: box.path(".gemini/config/skills"))
    let r = Inventory.scan(adapters: [box.adapt(DefaultAdapters.antigravity)], codexDisabled: [])[0]
    #expect(r.placements.count == 1)
    #expect(r.roots.contains { $0.sameFolderAs != nil })
}

@Test func adaptersTomlOverridesFolders() {
    let tables = MiniTOML.parse("""
    # comment
    [harness.deepseek]
    name = "DSH"
    global_dirs = ["~/.dsh/skills"]   # only this
    [harness.newagent]
    name = "New"
    project_dirs = [".new/skills"]
    [[skills.config]]
    path = "/x/SKILL.md"
    enabled = false
    """)
    let adapters = AdapterConfig.apply(tables, to: DefaultAdapters.all)
    let dsh = adapters.first { $0.id == "deepseek" }!
    #expect(dsh.name == "DSH")
    #expect(dsh.roots.map(\.path) == ["~/.dsh/skills"])
    #expect(adapters.contains { $0.id == "newagent" })
    #expect(tables.contains { $0.isArrayItem && $0.values["enabled"]?.bool == false })
}
