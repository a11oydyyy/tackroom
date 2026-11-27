import Foundation
import Testing
@testable import TackroomKit

/// OpenCode and Gemini CLI take links; agents that only read shared folders
/// are listed only when they are on this Mac.
@Suite(.serialized) struct MoreAgentsTests {
    @Test func openCodeGetsItsOwnLink() throws {
        let t = try OpsBox(extra: [DefaultAdapters.opencode])
        try t.box.skill(".codex/skills", "tk-oc")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-oc"))))
        try t.ops.execute(t.ops.planToggle("tk-oc", harness: "opencode", on: true))
        #expect(t.isLink(".config/opencode/skills/tk-oc"))
        #expect(t.group("tk-oc")?.activeHarnessIDs.sorted() == ["codex", "opencode"])
    }

    @Test func turningOnForClaudeSaysWhoElseReadsIt() throws {
        let t = try OpsBox(extra: [DefaultAdapters.opencode, DefaultAdapters.geminiCLI])
        try t.box.skill(".codex/skills", "tk-shared")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-shared"))))
        let on = t.ops.planToggle("tk-shared", harness: "claude-code", on: true)
        #expect(on.preview.contains { $0.text == "OpenCode 也會讀到這一份" })
        try t.ops.execute(on)
        #expect(t.group("tk-shared")?.activeHarnessIDs.contains("opencode") == true)
        #expect(t.ops.planToggle("tk-shared", harness: "claude-code", on: false).preview.contains { $0.text == "OpenCode 也會讀不到這一份" })
    }

    @Test func geminiPrefersTheSharedAgentsFolder() throws {
        let t = try OpsBox(extra: [DefaultAdapters.geminiCLI])
        try t.box.skill(".codex/skills", "tk-gem")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-gem"))))
        try t.box.skill(".agents/skills", "tk-gem")
        let on = t.ops.planToggle("tk-gem", harness: "gemini-cli", on: true)
        #expect(on.preview.contains { $0.text.hasPrefix("Gemini 仍會優先使用") })
    }

    @Test func agentsNotOnThisMacAreLeftOut() {
        var gone = DefaultAdapters.devin
        gone.markers = ["~/.tackroom-test-not-here-\(UUID().uuidString)", "cmd:tackroom-test-not-here"]
        #expect(!gone.isPresent)
        #expect(DefaultAdapters.codex.isPresent)  // no markers: always listed
        #expect(DefaultAdapters.all.map(\.id) == ["claude-code", "codex", "antigravity", "deepseek", "cursor", "opencode", "gemini-cli", "copilot", "devin"])
    }
}

@Suite(.serialized) struct CursorTests {
    @Test func cursorGetsItsOwnLinkAndItWinsOverClaudes() throws {
        let t = try OpsBox(extra: [DefaultAdapters.cursor])
        try t.box.skill(".codex/skills", "tk-cu")
        try t.ops.execute(t.ops.planAdopt(try #require(t.group("tk-cu"))))
        // Cursor already reads ~/.codex/skills: Codex's link counts for it too.
        #expect(t.group("tk-cu")?.activeHarnessIDs.sorted() == ["codex", "cursor"])
        try t.ops.execute(t.ops.planToggle("tk-cu", harness: "cursor", on: true))
        #expect(t.isLink(".cursor/skills/tk-cu"))
        let off = t.ops.planToggle("tk-cu", harness: "cursor", on: false)
        #expect(off.preview.contains { $0.text.hasPrefix("關閉後 Cursor 會改用") })
    }
}
