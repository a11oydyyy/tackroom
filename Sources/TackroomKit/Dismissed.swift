import Foundation

/// Notices the user marked 「不用處理」. Each is remembered by a fingerprint of
/// the situation, so it comes back by itself when the situation changes
/// (for example a copy's content changes again).
/// Kept in `~/.tackroom/dismissed.json`, outside the store's git history.
public struct DismissedNotices: Sendable {
    public var url: URL
    public private(set) var keys: Set<String> = []

    public init(url: URL = Paths.home.appendingPathComponent(".tackroom/dismissed.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: data) {
            keys = Set(list)
        }
    }

    /// The fingerprint of one issue on one skill.
    public static func key(skill group: SkillGroup, issue: SkillIssue) -> String {
        let hashes = Set(group.placements.compactMap(\.copy.contentHash)).sorted().joined(separator: ",")
        switch issue {
        case .versionsDiffer: return "\(group.name)|differ|\(hashes)"
        case .drifted: return "\(group.name)|drifted|\(hashes)"
        case .duplicate(let id):
            let entries = group.placements.filter { $0.harnessID == id }.map(\.copy.entryPath).sorted().joined(separator: ",")
            return "\(group.name)|duplicate|\(id)|\(entries)"
        case .brokenLink(let entry): return "\(group.name)|broken|\(entry)"
        case .problem(let text): return "\(group.name)|problem|\(text)|\(hashes)"
        }
    }

    public func contains(_ group: SkillGroup, _ issue: SkillIssue) -> Bool {
        keys.contains(Self.key(skill: group, issue: issue))
    }

    /// Issues still worth showing.
    public func open(_ group: SkillGroup) -> [SkillIssue] {
        group.issues.filter { !contains(group, $0) }
    }

    public mutating func set(_ group: SkillGroup, _ issue: SkillIssue, dismissed: Bool) throws {
        let k = Self.key(skill: group, issue: issue)
        if dismissed { keys.insert(k) } else { keys.remove(k) }
        try save()
    }

    public mutating func removeAll() throws {
        keys = []
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys.sorted()).write(to: url, options: .atomic)
    }
}
