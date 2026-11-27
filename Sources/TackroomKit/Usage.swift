import Foundation

/// Counts how often each skill was used, from the agents' own conversation
/// logs on this Mac. Only skill names are matched; no conversation text is
/// kept, stored or sent anywhere. A skill counts once per conversation.
public enum UsageCounter {
    /// Where Claude Code and Codex keep their conversation logs.
    public static var defaultLogRoots: [String] {
        ["~/.claude/projects", "~/.codex/sessions", "~/.codex/archived_sessions"].map(Paths.expand)
    }

    /// Times each name was used in conversations changed since `since`.
    public static func count(names: Set<String>, roots: [String] = defaultLogRoots,
                             since: Date = Date().addingTimeInterval(-30 * 86400)) -> [String: Int] {
        guard !names.isEmpty else { return [:] }
        var totals: [String: Int] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
                                        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= since else { continue }
                for name in used(in: url, names: names) { totals[name, default: 0] += 1 }
            }
        }
        return totals
    }

    /// Names used in one conversation log.
    static func used(in url: URL, names: Set<String>) -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var found: Set<String> = []
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            // Work line by line; keep the unfinished last line for the next chunk.
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            let complete = carry[carry.startIndex...lastNewline]
            scan(complete, names: names, into: &found)
            carry = Data(carry[(lastNewline + 1)...])
        }
        if !carry.isEmpty { scan(carry, names: names, into: &found) }
        return found
    }

    private static let skillCall = try! NSRegularExpression(pattern: #""name":"Skill","input":\{"(?:skill|command)":"/?([A-Za-z0-9_.:-]+)""#)
    private static let slashCommand = try! NSRegularExpression(pattern: #"<command-name>/([A-Za-z0-9_.:-]+)</command-name>"#)
    private static let skillFile = try! NSRegularExpression(pattern: #"skills/([A-Za-z0-9_.-]+)/SKILL\.md"#)

    static func scan(_ data: Data, names: Set<String>, into found: inout Set<String>) {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let isCall = line.contains("\"Skill\"")
            let isSlash = line.contains("<command-name>")
            // A SKILL.md path counts only when a tool actually opened it, not
            // when the file merely appears in a list of available skills.
            let isRead = line.contains("SKILL.md") && (line.contains("\"tool_use\"") || line.contains("\"function_call\"")
                                                       || line.contains("exec_command") || line.contains("\"custom_tool_call\""))
            guard isCall || isSlash || isRead else { continue }
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            var patterns: [NSRegularExpression] = []
            if isCall { patterns.append(skillCall) }
            if isSlash { patterns.append(slashCommand) }
            if isRead { patterns.append(skillFile) }
            for p in patterns {
                for m in p.matches(in: s, range: range) {
                    guard let r = Range(m.range(at: 1), in: s) else { continue }
                    var name = String(s[r])
                    if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }  // plugin:skill
                    if names.contains(name) { found.insert(name) }
                }
            }
        }
    }
}

/// Skills the user pinned to the top of the list, in `~/.tackroom/pins.json`.
public struct Pins: Sendable {
    public var url: URL
    public private(set) var names: [String] = []

    public init(url: URL = Paths.home.appendingPathComponent(".tackroom/pins.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) { names = list }
    }

    public func contains(_ name: String) -> Bool { names.contains(name) }

    mutating func renameSkill(_ old: String, to new: String) throws {
        guard names.contains(old) else { return }
        names.removeAll { $0 == new }
        names = names.map { $0 == old ? new : $0 }
        try JSONEncoder().encode(names).write(to: url, options: .atomic)
    }

    public mutating func set(_ name: String, pinned: Bool) throws {
        names.removeAll { $0 == name }
        if pinned { names.append(name) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(names).write(to: url, options: .atomic)
    }
}
