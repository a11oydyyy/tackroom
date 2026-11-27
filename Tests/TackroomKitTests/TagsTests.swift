import Foundation
import Testing
@testable import TackroomKit

struct TagsTests {
    private func book() -> (TagBook, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-tags-\(UUID().uuidString)/tags.json")
        return (TagBook(url: url), url)
    }

    @Test func startsWithTheFourStarters() {
        let (b, _) = book()
        #expect(b.tags.map(\.name) == ["自動化", "寫作與文件", "前端與設計", "開發工具"])
        #expect(b.skills.isEmpty)
    }

    @Test func manySkillsManyTagsAndItSurvivesReload() throws {
        var (b, url) = book()
        let mine = try b.create("  客戶專案 ")
        #expect(mine == "客戶專案")
        #expect(b.tag(named: "客戶專案")?.color == "red")  // first palette color not yet used
        try b.set("客戶專案", on: true, for: ["a", "b"])
        try b.set("自動化", on: true, for: ["a"])
        #expect(b.tags(of: "a") == ["客戶專案", "自動化"])
        #expect(b.count(of: "客戶專案") == 2)

        let again = TagBook(url: url)
        #expect(again == b)
    }

    @Test func theMainTagCanBeChosen() throws {
        var (b, _) = book()
        try b.set("自動化", on: true, for: ["a"])
        try b.set("開發工具", on: true, for: ["a"])
        try b.makePrimary("開發工具", for: "a")
        #expect(b.tags(of: "a") == ["開發工具", "自動化"])
    }

    @Test func removingTheLastTagForgetsTheSkill() throws {
        var (b, _) = book()
        try b.set("自動化", on: true, for: ["a"])
        try b.set("自動化", on: false, for: ["a"])
        #expect(b.skills["a"] == nil)
    }

    @Test func renameRecolorDelete() throws {
        var (b, _) = book()
        try b.set("自動化", on: true, for: ["a", "b"])
        try b.rename("自動化", to: "腳本")
        #expect(b.tags(of: "a") == ["腳本"])
        #expect(throws: TagError.exists("開發工具")) { try b.rename("腳本", to: "開發工具") }
        #expect(throws: TagError.emptyName) { try b.create("   ") }
        try b.recolor("腳本", to: "teal")
        #expect(b.tag(named: "腳本")?.color == "teal")
        try b.delete("腳本")
        #expect(b.tag(named: "腳本") == nil)
        #expect(b.skills.isEmpty)
    }

    @Test func lockfileTagsMoveOverOnce() throws {
        var (b, _) = book()
        try b.adoptLegacy(["a": ["寫作與文件"], "b": ["舊的"]])
        #expect(b.tags(of: "a") == ["寫作與文件"])
        #expect(b.tag(named: "舊的") != nil)
        try b.set("寫作與文件", on: false, for: ["a"])
        try b.adoptLegacy(["a": ["寫作與文件"]])  // done once: a removal sticks
        #expect(b.tags(of: "a").isEmpty)
    }
}
