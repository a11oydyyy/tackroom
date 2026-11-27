import Foundation

/// A small YAML reader for the shapes agent config files use: block maps and
/// sequences, quoted and plain scalars, one-line flow lists and maps, and tags
/// such as `!!js …` (kept as the scalar text). Anything it can't read is skipped.
public indirect enum YAMLValue: Sendable, Hashable {
    case scalar(String)
    case seq([YAMLValue])
    case map([String: YAMLValue])

    public var string: String? { if case .scalar(let s) = self { return s } else { return nil } }
    public var seq: [YAMLValue]? { if case .seq(let a) = self { return a } else { return nil } }
    public var map: [String: YAMLValue]? { if case .map(let m) = self { return m } else { return nil } }
    public subscript(_ key: String) -> YAMLValue? { map?[key] }
}

public enum MiniYAML {
    struct Line { var indent: Int; var text: String }

    public static func parse(_ text: String) -> YAMLValue? {
        var lines: [Line] = []
        var inBlockScalar: Int? = nil
        for raw in text.components(separatedBy: "\n") {
            let noTab = raw.replacingOccurrences(of: "\t", with: "  ")
            let indent = noTab.prefix { $0 == " " }.count
            if let blockIndent = inBlockScalar {
                if noTab.trimmingCharacters(in: .whitespaces).isEmpty || indent > blockIndent { continue }
                inBlockScalar = nil
            }
            let stripped = stripComment(String(noTab.dropFirst(indent))).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped == "---" || stripped.hasPrefix("%") { continue }
            if stripped.hasSuffix("|") || stripped.hasSuffix(">") || stripped.hasSuffix("|-") || stripped.hasSuffix(">-") {
                inBlockScalar = indent
            }
            lines.append(Line(indent: indent, text: stripped))
        }
        var i = 0
        return parseBlock(lines, &i, indent: lines.first?.indent ?? 0)
    }

    static func parseBlock(_ lines: [Line], _ i: inout Int, indent: Int) -> YAMLValue? {
        guard i < lines.count else { return nil }
        if lines[i].text.hasPrefix("- ") || lines[i].text == "-" {
            var items: [YAMLValue] = []
            while i < lines.count, lines[i].indent == indent, lines[i].text.hasPrefix("- ") || lines[i].text == "-" {
                let rest = lines[i].text == "-" ? "" : String(lines[i].text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    i += 1
                    items.append(i < lines.count && lines[i].indent > indent ? (parseBlock(lines, &i, indent: lines[i].indent) ?? .scalar("")) : .scalar(""))
                } else if isMapLine(rest) {
                    // "- key: value" starts a map whose other keys sit 2 deeper.
                    var sub = lines
                    sub[i] = Line(indent: indent + 2, text: rest)
                    items.append(parseBlock(sub, &i, indent: indent + 2) ?? .scalar(""))
                } else {
                    items.append(scalar(rest))
                    i += 1
                }
            }
            return .seq(items)
        }
        var map: [String: YAMLValue] = [:]
        while i < lines.count, lines[i].indent == indent, isMapLine(lines[i].text) {
            let (key, rest) = splitKey(lines[i].text)
            i += 1
            if rest.isEmpty || rest.hasPrefix("|") || rest.hasPrefix(">") || rest.hasPrefix("&") {
                if i < lines.count, lines[i].indent > indent || (lines[i].indent == indent && lines[i].text.hasPrefix("- ")) {
                    map[key] = parseBlock(lines, &i, indent: lines[i].indent) ?? .scalar("")
                } else {
                    map[key] = .scalar("")
                }
            } else {
                map[key] = scalar(rest)
            }
        }
        // Skip lines this reader didn't understand at this level.
        while i < lines.count, lines[i].indent > indent { i += 1 }
        return .map(map)
    }

    static func isMapLine(_ text: String) -> Bool {
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            let q = text.first!
            guard let close = text.dropFirst().firstIndex(of: q) else { return false }
            return text[text.index(after: close)...].hasPrefix(":")
        }
        guard let colon = text.firstIndex(of: ":") else { return false }
        let after = text[text.index(after: colon)...]
        let key = text[..<colon]
        return (after.isEmpty || after.hasPrefix(" ")) && !key.contains(" #") && !key.hasPrefix("[") && !key.hasPrefix("{")
    }

    static func splitKey(_ text: String) -> (String, String) {
        if let q = text.first, q == "\"" || q == "'", let close = text.dropFirst().firstIndex(of: q) {
            let key = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...].dropFirst().trimmingCharacters(in: .whitespaces)
            return (key, rest)
        }
        let colon = text.firstIndex(of: ":")!
        return (String(text[..<colon]).trimmingCharacters(in: .whitespaces),
                String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    static func scalar(_ text: String) -> YAMLValue {
        var t = text
        if t.hasPrefix("[") && t.hasSuffix("]") {
            return .seq(splitFlow(String(t.dropFirst().dropLast())).map { scalar($0) })
        }
        if t.hasPrefix("{") && t.hasSuffix("}") {
            var m: [String: YAMLValue] = [:]
            for part in splitFlow(String(t.dropFirst().dropLast())) where isMapLine(part) || part.contains(":") {
                let (k, v) = splitKey(part)
                m[unquote(k)] = scalar(v)
            }
            return .map(m)
        }
        if t.hasPrefix("&") || t.hasPrefix("*") { t = String(t.drop { $0 != " " }).trimmingCharacters(in: .whitespaces) }
        return .scalar(unquote(t))
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return s
    }

    static func splitFlow(_ s: String) -> [String] {
        var parts: [String] = [], cur = "", depth = 0
        var quote: Character? = nil
        for ch in s {
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; continue }
            switch ch {
            case "\"", "'": quote = ch; cur.append(ch)
            case "[", "{": depth += 1; cur.append(ch)
            case "]", "}": depth -= 1; cur.append(ch)
            case "," where depth == 0: parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            default: cur.append(ch)
            }
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    static func stripComment(_ line: String) -> String {
        var quote: Character? = nil
        var prev: Character = " "
        for (offset, ch) in line.enumerated() {
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "#" && (prev == " " || offset == 0) { return String(line.prefix(offset)) }
            prev = ch
        }
        return line
    }
}
