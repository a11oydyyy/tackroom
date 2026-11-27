import Foundation
import CryptoKit

/// Instruction and reference files agents read: CLAUDE.md, AGENTS.md,
/// GEMINI.md, DESIGN.md and other Markdown at a project's top level.
public struct AgentDoc: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var projectID: UUID?
    /// Which agent reads it on its own, when known.
    public var readBy: String?
}

public enum AgentDocs {
    /// Global instruction files, when they exist.
    public static let globalFiles = ["~/.claude/CLAUDE.md", "~/.codex/AGENTS.md", "~/.gemini/GEMINI.md"]

    public static func global() -> [AgentDoc] {
        globalFiles.map(Paths.expand).filter { FileManager.default.fileExists(atPath: $0) }.map {
            AgentDoc(path: $0, name: ($0 as NSString).lastPathComponent, projectID: nil, readBy: readBy($0))
        }
    }

    /// Markdown files at the top of a project folder, plus `.claude/CLAUDE.md`.
    /// Agent instruction files come first.
    public static func inProject(_ folder: String, id: UUID?) -> [AgentDoc] {
        let fm = FileManager.default
        var paths = ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.lowercased().hasSuffix(".md") && !$0.hasPrefix(".") }
            .map { (folder as NSString).appendingPathComponent($0) }
        let nested = (folder as NSString).appendingPathComponent(".claude/CLAUDE.md")
        if fm.fileExists(atPath: nested) { paths.append(nested) }
        let docs = paths.filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && !d.boolValue }
            .map { AgentDoc(path: $0, name: $0.hasSuffix(".claude/CLAUDE.md") ? ".claude/CLAUDE.md" : ($0 as NSString).lastPathComponent,
                            projectID: id, readBy: readBy($0)) }
        return docs.sorted { a, b in
            if (a.readBy != nil) != (b.readBy != nil) { return a.readBy != nil }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Agents (adapter ids) that load this file by themselves.
    public static func readers(_ path: String) -> [String] {
        switch (path as NSString).lastPathComponent.uppercased() {
        case "CLAUDE.MD", "CLAUDE.LOCAL.MD": return ["claude-code"]
        case "AGENTS.MD": return ["codex"]
        case "GEMINI.MD": return ["antigravity"]
        default: return []
        }
    }

    static func readBy(_ path: String) -> String? {
        switch (path as NSString).lastPathComponent.uppercased() {
        case "CLAUDE.MD", "CLAUDE.LOCAL.MD": return L("Claude Code 會自動讀取")
        case "AGENTS.MD": return L("Codex 會自動讀取")
        case "GEMINI.MD": return L("Antigravity 會自動讀取")
        default: return nil
        }
    }

    /// Where the store keeps the text a document had before each edit.
    static func backupPath(for path: String) -> String {
        let key = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "docs/\(key)/before.md"
    }
}

extension Operations {
    /// Saves an edited document. The old text goes into the store, so the
    /// edit shows in Activity and can be undone.
    public func planEditDoc(path: String, newContents: String, project: Project?) -> Plan {
        let name = (path as NSString).lastPathComponent
        let title = L("修改 \(name)") + (project.map { L("（\($0.name)）") } ?? L("（全域）"))
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let backup = store.root.appendingPathComponent(AgentDocs.backupPath(for: path)).path
        return Plan(title: title, op: .editDoc(path: path, project: project), actor: actor,
                    preview: [PreviewLine(kind: .change, text: L("存檔 \(short(path))"))],
                    steps: [.writeFile(path: backup, contents: old), .writeFile(path: path, contents: newContents), .commit(title)],
                    blocker: nil)
    }

    /// Puts back the text a document had before the edit in `commit`.
    func planRevertDoc(path: String, project: Project?, editedIn commit: String) -> Plan {
        let name = (path as NSString).lastPathComponent
        let title = L("把 \(name) 改回修改前")
        guard let old = try? store.git.run(["show", "\(commit):\(AgentDocs.backupPath(for: path))"]) else {
            return Plan(title: title, op: .editDoc(path: path, project: project), actor: actor, preview: [], steps: [],
                        blocker: L("找不到修改前的內容。"))
        }
        let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let backup = store.root.appendingPathComponent(AgentDocs.backupPath(for: path)).path
        return Plan(title: title, op: .editDoc(path: path, project: project), actor: actor,
                    preview: [PreviewLine(kind: .change, text: L("\(short(path)) 改回修改前的內容"))],
                    steps: [.writeFile(path: backup, contents: current), .writeFile(path: path, contents: old), .commit(title)],
                    blocker: nil)
    }
}
