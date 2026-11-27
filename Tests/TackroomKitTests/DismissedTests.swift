import Foundation
import Testing
@testable import TackroomKit

@Test func dismissedNoticeComesBackWhenContentChanges() throws {
    let box = try Sandbox()
    try box.skill(".codex/skills", "notes", description: "one")
    let other = try box.skill(".claude/skills", "notes", description: "two")
    let adapters = [box.adapt(DefaultAdapters.codex), box.adapt(DefaultAdapters.claudeCode)]
    func group() -> SkillGroup? {
        Overview.groups(from: Inventory.scan(adapters: adapters, codexDisabled: [])).first { $0.name == "notes" }
    }
    let g = try #require(group())
    #expect(g.issues.contains(.versionsDiffer))

    var store = DismissedNotices(url: box.root.appendingPathComponent("dismissed.json"))
    try store.set(g, .versionsDiffer, dismissed: true)
    // Survives a reload, and the open list no longer has it.
    let reloaded = DismissedNotices(url: store.url)
    #expect(reloaded.open(try #require(group())).isEmpty)

    // A new change to one copy brings the notice back.
    try "---\nname: notes\ndescription: three\n---\nchanged\n".write(toFile: other + "/SKILL.md", atomically: true, encoding: .utf8)
    #expect(reloaded.open(try #require(group())).contains(.versionsDiffer))
}
