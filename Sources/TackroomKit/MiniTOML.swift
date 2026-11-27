import Foundation

/// A tolerant reader for the small part of TOML Tackroom needs: tables,
/// arrays of tables, and string / bool / number / string-array values.
/// Lines it does not understand are skipped, so it can read large config
/// files written by other tools (for example `~/.codex/config.toml`).
public indirect enum TOMLValue: Sendable, Hashable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case strings([String])
    /// An inline table: `{ KEY = "v", other = 1 }`.
    case table([String: TOMLValue])

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var strings: [String]? { if case .strings(let a) = self { return a } else { return nil } }
    public var table: [String: TOMLValue]? { if case .table(let t) = self { return t } else { return nil } }
}

public struct TOMLTable: Sendable {
    /// Dotted header, e.g. `harness.codex` or `skills.config`.
    public var name: String
    public var isArrayItem: Bool
    public var values: [String: TOMLValue]
}

public enum MiniTOML {
    public static func parse(_ text: String) -> [TOMLTable] {
        var tables: [TOMLTable] = [TOMLTable(name: "", isArrayItem: false, values: [:])]
        var lines = text.components(separatedBy: "\n")[...]
        while let rawLine = lines.popFirst() {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                let name = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                tables.append(TOMLTable(name: unquoteKey(name), isArrayItem: true, values: [:]))
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                tables.append(TOMLTable(name: unquoteKey(name), isArrayItem: false, values: [:]))
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = unquoteKey(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            var valueText = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            // Multi-line strings and arrays: gather lines until they close.
            if valueText.hasPrefix("\"\"\"") || valueText.hasPrefix("'''") {
                let fence = String(valueText.prefix(3))
                if valueText.dropFirst(3).contains(fence) == false {
                    while let next = lines.popFirst() { if next.contains(fence) { break } }
                }
                continue
            }
            if valueText.hasPrefix("[") || valueText.hasPrefix("{") {
                while !balanced(valueText), let next = lines.popFirst() {
                    valueText += " " + stripComment(next).trimmingCharacters(in: .whitespaces)
                }
            }
            if let value = parseValue(valueText) {
                tables[tables.count - 1].values[key] = value
            }
        }
        return tables
    }

    static func parseValue(_ text: String) -> TOMLValue? {
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if let s = parseString(text) { return .string(s) }
        if text.hasPrefix("[") && text.hasSuffix("]") {
            let inner = text.dropFirst().dropLast()
            var items: [String] = []
            for part in splitTopLevel(String(inner)) {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                guard let s = parseString(trimmed) else { return nil }
                items.append(s)
            }
            return .strings(items)
        }
        if text.hasPrefix("{") && text.hasSuffix("}") {
            var table: [String: TOMLValue] = [:]
            for part in splitTopLevel(String(text.dropFirst().dropLast())) {
                guard let eq = part.firstIndex(of: "=") else { continue }
                let key = unquoteKey(String(part[..<eq]).trimmingCharacters(in: .whitespaces))
                if let v = parseValue(String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespaces)) { table[key] = v }
            }
            return .table(table)
        }
        if let d = Double(text.replacingOccurrences(of: "_", with: "")) { return .number(d) }
        return nil
    }

    static func parseString(_ text: String) -> String? {
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\""), closingQuote(text) == text.index(before: text.endIndex) {
            var out = ""
            var escaped = false
            var chars = text.dropFirst().dropLast()[...]
            while let ch = chars.popFirst() {
                if escaped {
                    escaped = false
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "u", "U":
                        let n = ch == "u" ? 4 : 8
                        let hex = String(chars.prefix(n))
                        chars = chars.dropFirst(n)
                        if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) { out.unicodeScalars.append(scalar) }
                    default: out.append(ch)   // \" and \\ and anything else: the character itself
                    }
                } else if ch == "\\" {
                    escaped = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast())
        }
        return nil
    }

    /// Where the string that opens `text` closes (backslash escapes count in "…").
    static func closingQuote(_ text: String) -> String.Index? {
        guard let q = text.first, q == "\"" || q == "'" else { return nil }
        var escaped = false
        var i = text.index(after: text.startIndex)
        while i < text.endIndex {
            let ch = text[i]
            if escaped { escaped = false } else if q == "\"" && ch == "\\" { escaped = true } else if ch == q { return i }
            i = text.index(after: i)
        }
        return nil
    }

    /// Walks `text`, telling `visit` for every character whether it sits
    /// inside a quoted string (escapes in "…" included).
    static func walk(_ text: String, _ visit: (String.Index, Character, Bool) -> Bool) {
        var inString: Character? = nil
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            var quoted = inString != nil
            if let q = inString {
                if escaped { escaped = false } else if q == "\"" && ch == "\\" { escaped = true } else if ch == q { inString = nil }
            } else if ch == "\"" || ch == "'" {
                inString = ch
                quoted = true
            }
            if !visit(i, ch, quoted) { return }
            i = text.index(after: i)
        }
    }

    /// `a."b.c".d` → `a.b.c.d`, keeping dots inside quotes as part of the name.
    static func unquoteKey(_ key: String) -> String {
        var parts: [String] = []
        var current = ""
        walk(key) { _, ch, quoted in
            if ch == "." && !quoted { parts.append(current); current = "" } else { current.append(ch) }
            return true
        }
        parts.append(current)
        return parts.map { part -> String in
            let p = part.trimmingCharacters(in: .whitespaces)
            return parseString(p) ?? p
        }
        .joined(separator: ".")
    }

    static func stripComment(_ line: String) -> String {
        var cut: String.Index?
        walk(line) { i, ch, quoted in
            if ch == "#" && !quoted { cut = i; return false }
            return true
        }
        return cut.map { String(line[..<$0]) } ?? line
    }

    static func balanced(_ text: String) -> Bool {
        var depth = 0
        walk(text) { _, ch, quoted in
            if !quoted { if ch == "[" || ch == "{" { depth += 1 } else if ch == "]" || ch == "}" { depth -= 1 } }
            return true
        }
        return depth <= 0
    }

    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var nest = 0
        walk(text) { _, ch, quoted in
            if !quoted {
                if ch == "[" || ch == "{" { nest += 1 } else if ch == "]" || ch == "}" { nest -= 1 }
                if ch == "," && nest == 0 { parts.append(current); current = ""; return true }
            }
            current.append(ch)
            return true
        }
        parts.append(current)
        return parts
    }
}

// MARK: - adapters.toml

public enum AdapterConfig {
    /// `~/.tackroom/adapters.toml`. Each `[harness.<id>]` table replaces the
    /// folders of a built-in agent, or adds a new agent.
    public static var defaultURL: URL {
        Paths.home.appendingPathComponent(".tackroom/adapters.toml")
    }

    /// The agents on this Mac: built-in ones that are installed, plus any
    /// that `adapters.toml` adds or changes.
    public static func load(from url: URL = defaultURL, base: [HarnessAdapter] = DefaultAdapters.all) -> [HarnessAdapter] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return base.filter(\.isPresent) }
        return apply(MiniTOML.parse(text), to: base).filter(\.isPresent)
    }

    public static func apply(_ tables: [TOMLTable], to base: [HarnessAdapter]) -> [HarnessAdapter] {
        var adapters = base
        for table in tables where table.name.hasPrefix("harness.") {
            let id = String(table.name.dropFirst("harness.".count))
            let v = table.values
            var adapter = adapters.first(where: { $0.id == id })
                ?? HarnessAdapter(id: id, name: id, roots: [], sameName: .lowestRankWins, accentHex: "#8E8E93")
            if let name = v["name"]?.string { adapter.name = name; adapter.shortName = v["short_name"]?.string ?? name }
            if let rule = v["same_name"]?.string { adapter.sameName = rule == "lists_all" ? .listsAll : .lowestRankWins }
            if let app = v["app"]?.string { adapter.appPath = app }
            if let color = v["color"]?.string { adapter.accentHex = color }
            if let flat = v["flat_markdown"]?.bool { adapter.acceptsFlatMarkdown = flat }
            if let write = v["write_dir"]?.string { adapter.writeDir = write.isEmpty ? nil : write }
            if let write = v["project_write_dir"]?.string { adapter.projectWriteDir = write.isEmpty ? nil : write }
            if let files = v["mcp_files"]?.strings { adapter.mcpFiles = files }
            if let files = v["mcp_project_files"]?.strings { adapter.mcpProjectFiles = files }
            if let files = v["mcp_plugin_files"]?.strings { adapter.mcpPluginFiles = files }

            let keys = ["global_dirs", "legacy_dirs", "builtin_dirs", "project_dirs"]
            if keys.contains(where: { v[$0] != nil }) {
                let globalFirst = v["global_first"]?.bool ?? false
                func ranked(_ key: String, _ scope: RootScope, _ role: RootRole, _ base: Int) -> [SkillRoot] {
                    (v[key]?.strings ?? []).enumerated().map { SkillRoot($1, scope, rank: base + $0, role: role) }
                }
                let g = globalFirst ? 10 : 100
                let p = globalFirst ? 100 : 10
                adapter.roots = ranked("project_dirs", .project, .user, p)
                    + ranked("global_dirs", .global, .user, g)
                    + ranked("legacy_dirs", .global, .legacy, g + 30)
                    + ranked("builtin_dirs", .global, .builtin, g + 40)
            }
            if let index = adapters.firstIndex(where: { $0.id == id }) {
                adapters[index] = adapter
            } else {
                adapters.append(adapter)
            }
        }
        return adapters
    }
}

// MARK: - Codex per-skill switches

public enum CodexConfig {
    /// Paths turned off with `[[skills.config]] enabled = false` in `~/.codex/config.toml`.
    public static func disabledSkillFiles(configURL: URL = Paths.home.appendingPathComponent(".codex/config.toml")) -> Set<String> {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        var result: Set<String> = []
        for table in MiniTOML.parse(text) where table.isArrayItem && table.name == "skills.config" {
            guard let path = table.values["path"]?.string, table.values["enabled"]?.bool == false else { continue }
            let expanded = Paths.expand(path)
            result.insert(expanded)
            result.insert(Paths.realpath(expanded) ?? expanded)
        }
        return result
    }
}
