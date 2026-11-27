import Foundation
import Testing
@testable import TackroomKit

@Suite(.serialized) struct DocsTests {
    @Test func editDocIsRecordedAndCanBeUndone() throws {
        let t = try OpsBox()
        let project = t.box.root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let doc = project.appendingPathComponent("AGENTS.md").path
        try "# Rules\nold text\n".write(toFile: doc, atomically: true, encoding: .utf8)
        try "notes".write(toFile: project.appendingPathComponent("DESIGN.md").path, atomically: true, encoding: .utf8)

        let docs = AgentDocs.inProject(project.path, id: nil)
        #expect(docs.map(\.name) == ["AGENTS.md", "DESIGN.md"])  // the one agents read comes first
        #expect(docs.first?.readBy != nil)

        let p = Project(name: "proj", path: project.path)
        try t.ops.execute(t.ops.planEditDoc(path: doc, newContents: "# Rules\nnew text\n", project: p))
        #expect(try String(contentsOfFile: doc, encoding: .utf8) == "# Rules\nnew text\n")
        let entry = try #require(Activity.load(store: t.ops.store).first)
        #expect(entry.op == .editDoc(path: doc, project: p))

        try t.ops.execute(t.ops.planUndo(entry))
        #expect(try String(contentsOfFile: doc, encoding: .utf8) == "# Rules\nold text\n")
    }
}
