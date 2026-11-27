import Foundation

/// The user's tags, in `~/.tackroom/tags.json`, outside the store's git history.
/// Any skill can carry any number of tags, managed by Tackroom or not: tagging
/// only organises the list and never touches a skill's files.
public struct TagBook: Sendable, Equatable {
    public struct Tag: Codable, Sendable, Equatable {
        public var name: String
        /// A palette key: blue, purple, green, orange, red, pink, teal, gray.
        public var color: String
        public init(name: String, color: String) { self.name = name; self.color = color }
    }

    public static let palette = ["blue", "purple", "green", "orange", "red", "pink", "teal", "gray"]
    /// The tags a new book starts with (the round-9 mockup's four).
    public static let starters: [Tag] = [
        Tag(name: L("自動化"), color: "blue"), Tag(name: L("寫作與文件"), color: "purple"),
        Tag(name: L("前端與設計"), color: "green"), Tag(name: L("開發工具"), color: "orange"),
    ]

    public var url: URL
    public private(set) var tags: [Tag] = TagBook.starters
    /// Skill name → its tag names, in the order they were added.
    public private(set) var skills: [String: [String]] = [:]

    /// Lockfile tags were moved over already (done once, so removals stick).
    public private(set) var migrated = false

    private struct File: Codable { var tags: [Tag]; var skills: [String: [String]]; var migrated: Bool? }

    public init(url: URL = Paths.home.appendingPathComponent(".tackroom/tags.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            tags = file.tags
            skills = file.skills
            migrated = file.migrated ?? false
        }
    }

    public static func == (a: TagBook, b: TagBook) -> Bool { a.tags == b.tags && a.skills == b.skills && a.migrated == b.migrated }

    public func tags(of skill: String) -> [String] { skills[skill] ?? [] }
    public func tag(named name: String) -> Tag? { tags.first { $0.name == name } }
    public func count(of tag: String) -> Int { skills.values.filter { $0.contains(tag) }.count }
    public func skills(tagged tag: String) -> Set<String> { Set(skills.filter { $0.value.contains(tag) }.keys) }

    /// Tags written in the lockfile by older versions; read once, kept here from then on.
    public mutating func adoptLegacy(_ legacy: [String: [String]]) throws {
        guard !migrated else { return }
        // Nothing to move: don't create files just for the flag.
        if legacy.values.allSatisfy(\.isEmpty) { migrated = true; return }
        for (skill, names) in legacy.sorted(by: { $0.key < $1.key }) where skills[skill] == nil && !names.isEmpty {
            for n in names where tag(named: n) == nil { tags.append(Tag(name: n, color: nextColor())) }
            skills[skill] = names
        }
        migrated = true
        try save()
    }

    // MARK: Tag list

    /// Adds a tag (trimmed); returns its final name. An existing name is reused.
    @discardableResult
    public mutating func create(_ raw: String, color: String? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TagError.emptyName }
        if tag(named: name) == nil {
            tags.append(Tag(name: name, color: color ?? nextColor()))
            try save()
        }
        return name
    }

    public mutating func rename(_ old: String, to raw: String) throws {
        let new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { throw TagError.emptyName }
        guard new != old else { return }
        guard tag(named: new) == nil else { throw TagError.exists(new) }
        guard let i = tags.firstIndex(where: { $0.name == old }) else { return }
        tags[i].name = new
        for (skill, names) in skills { skills[skill] = names.map { $0 == old ? new : $0 } }
        try save()
    }

    public mutating func recolor(_ name: String, to color: String) throws {
        guard let i = tags.firstIndex(where: { $0.name == name }) else { return }
        tags[i].color = color
        try save()
    }

    /// Removes the tag from the list and from every skill.
    public mutating func delete(_ name: String) throws {
        tags.removeAll { $0.name == name }
        for (skill, names) in skills {
            let left = names.filter { $0 != name }
            skills[skill] = left.isEmpty ? nil : left
        }
        try save()
    }

    // MARK: Tagging

    mutating func renameSkill(_ old: String, to new: String) throws {
        guard let names = skills.removeValue(forKey: old) else { return }
        skills[new] = names + (skills[new] ?? []).filter { !names.contains($0) }
        try save()
    }

    /// Adds or removes one tag on several skills at once.
    public mutating func set(_ tagName: String, on: Bool, for names: [String]) throws {
        for skill in names {
            var list = skills[skill] ?? []
            list.removeAll { $0 == tagName }
            if on { list.append(tagName) }
            skills[skill] = list.isEmpty ? nil : list
        }
        try save()
    }

    /// The first tag is the skill's main one: its icon and color show in the list.
    public mutating func makePrimary(_ tagName: String, for skill: String) throws {
        guard var list = skills[skill], list.contains(tagName), list.first != tagName else { return }
        list.removeAll { $0 == tagName }
        list.insert(tagName, at: 0)
        skills[skill] = list
        try save()
    }

    private func nextColor() -> String {
        let used = tags.map(\.color)
        return Self.palette.first { !used.contains($0) } ?? Self.palette[tags.count % Self.palette.count]
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(tags: tags, skills: skills, migrated: migrated)).write(to: url, options: .atomic)
    }
}

public enum TagError: LocalizedError, Equatable {
    case emptyName
    case exists(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return L("標籤名稱不能是空的。")
        case .exists(let n): return L("已經有叫「\(n)」的標籤了。")
        }
    }
}
