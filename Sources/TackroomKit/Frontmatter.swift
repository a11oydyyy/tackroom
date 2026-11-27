import Foundation

/// The few SKILL.md frontmatter fields Tackroom reads. A small parser on
/// purpose: it handles the YAML shapes skills use in practice (plain, quoted,
/// folded and literal values) and ignores everything else.
public struct Frontmatter: Sendable, Hashable {
    public var fields: [String: String]

    public var name: String? { fields["name"] }
    public var description: String? { fields["description"] }

    /// nil when the key is absent; throws-free: an unknown spelling reads as nil.
    public func bool(_ key: String) -> Bool? {
        guard let raw = fields[key]?.lowercased() else { return nil }
        switch raw {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    /// Splits `text` into frontmatter and body. Returns nil when the file has
    /// no frontmatter block.
    public static func parse(_ text: String) -> Frontmatter? {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let block = Array(lines[1..<end])

        var fields: [String: String] = [:]
        var i = 0
        while i < block.count {
            let line = block[i]
            i += 1
            guard let first = line.first, first != " ", first != "\t", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Indented lines that follow belong to this value.
            var continuation: [String] = []
            while i < block.count, block[i].isEmpty || block[i].first == " " || block[i].first == "\t" {
                continuation.append(block[i])
                i += 1
            }

            if value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = value.hasPrefix(">")
                let parts = continuation.map { $0.trimmingCharacters(in: .whitespaces) }
                value = folded
                    ? parts.split(separator: "", omittingEmptySubsequences: false)
                        .map { $0.joined(separator: " ") }.joined(separator: "\n")
                    : parts.joined(separator: "\n")
            } else if value.hasPrefix("\"") || value.hasPrefix("'") {
                let quote = value.first!
                var joined = value
                for extra in continuation { joined += " " + extra.trimmingCharacters(in: .whitespaces) }
                joined = String(joined.dropFirst())
                if let close = joined.lastIndex(of: quote) { joined = String(joined[..<close]) }
                if quote == "\"" {
                    joined = joined.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
                } else {
                    joined = joined.replacingOccurrences(of: "''", with: "'")
                }
                value = joined
            } else {
                if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
                let extra = continuation.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !extra.isEmpty { value = ([value] + extra).filter { !$0.isEmpty }.joined(separator: " ") }
            }
            fields[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Frontmatter(fields: fields)
    }
}
