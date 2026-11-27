import Foundation
import Testing
@testable import TackroomKit

@Test func usageCountsCallsSlashCommandsAndReadsButNotSkillLists() throws {
    let box = try Sandbox()
    let claude = box.root.appendingPathComponent("claude/proj")
    let codex = box.root.appendingPathComponent("codex/2026/11/26")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    // Two conversations use pdf-tools (one twice: still counts once).
    try """
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Skill","input":{"skill":"pdf-tools"}}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","id":"b","name":"Skill","input":{"skill":"pdf-tools"}}]}}
    {"type":"user","message":{"content":"<command-name>/meeting-notes</command-name>"}}
    """.write(to: claude.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
    try """
    {"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"sed -n 1,200p /Users/x/.codex/skills/pdf-tools/SKILL.md\\"}"}}
    {"type":"session_meta","payload":{"instructions":"- web-search: Search (file: /Users/x/.codex/skills/web-search/SKILL.md)"}}
    """.write(to: codex.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)

    let counts = UsageCounter.count(names: ["pdf-tools", "meeting-notes", "web-search"],
                                    roots: [box.path("claude"), box.path("codex")])
    #expect(counts["pdf-tools"] == 2)
    #expect(counts["meeting-notes"] == 1)
    #expect(counts["web-search"] == nil)  // only listed, never opened
}

@Test func pinsPersist() throws {
    let box = try Sandbox()
    var pins = Pins(url: box.root.appendingPathComponent("pins.json"))
    try pins.set("a", pinned: true)
    try pins.set("b", pinned: true)
    try pins.set("a", pinned: false)
    #expect(Pins(url: pins.url).names == ["b"])
}
