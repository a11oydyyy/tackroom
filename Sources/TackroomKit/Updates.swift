import Foundation

// MARK: - Finding updates

/// How the installed files relate to the upstream version they came from.
public enum LocalChange: Sendable, Hashable {
    /// Same as that version: an update can simply replace them.
    case none
    /// Edited since then (by you or an agent).
    case edited(whitespaceOnly: Bool)
    /// The version they came from is unknown, so nobody can tell which side changed.
    case unknown
}

/// A newer upstream version of a managed skill, waiting for review.
public struct UpdateCandidate: Sendable, Hashable, Identifiable {
    public var id: String { name + "@" + newHash }
    public var name: String
    /// The upstream commit the installed files came from, when known.
    public var fromCommit: String?
    public var toCommit: String
    /// The new version's folder (inside the cache).
    public var newPath: String
    /// The installed version's folder (inside the store).
    public var oldPath: String
    /// Hash of exactly the version the user reviews; applying checks it again.
    public var newHash: String
    /// The upstream version the installed files came from, unpacked, when it
    /// could be found. Comparing it with the new version shows only what the
    /// author changed; comparing it with the installed files shows your edits.
    public var basePath: String?
    public var baseHash: String?
    /// Hash of the installed files when checked; applying checks it again so
    /// edits made after the review are never lost.
    public var localHash: String
    public var local: LocalChange
    /// The new version renames the skill (`name:` in SKILL.md).
    public var renamedTo: String?

    public init(name: String, fromCommit: String?, toCommit: String, newPath: String, oldPath: String, newHash: String,
                basePath: String? = nil, baseHash: String? = nil, localHash: String, local: LocalChange, renamedTo: String? = nil) {
        self.name = name
        self.fromCommit = fromCommit
        self.toCommit = toCommit
        self.newPath = newPath
        self.oldPath = oldPath
        self.newHash = newHash
        self.basePath = basePath
        self.baseHash = baseHash
        self.localHash = localHash
        self.local = local
        self.renamedTo = renamedTo
    }

    /// What the author changed: base → new when the base is known, else
    /// installed → new.
    public var authorChangesFrom: String { basePath ?? oldPath }
    public var hasLocalEdits: Bool { if case .edited = local { return true } else { return false } }
}

/// What one check found for one skill that has an upstream.
public enum UpstreamStatus: Sendable, Hashable {
    /// Upstream has nothing newer than the version installed.
    case current
    /// A newer version is waiting (see the update list).
    case update
    /// Newer upstream, skipped by the user.
    case skipped
    case failed(String)
}

public struct UpdateCheckResult: Sendable {
    public var updates: [UpdateCandidate] = []
    public var failures: [String: String] = [:]
    public var status: [String: UpstreamStatus] = [:]
    /// Skills whose upstream base was worked out during the check (older
    /// records): name → (commit, hash). Stored the next time the skill is written.
    public var foundBases: [String: (commit: String, hash: String)] = [:]
}

public struct UpdateChecker: Sendable {
    public var store: Store
    public var cacheRoot: URL
    /// Where skills.sh records what it installed (its folder hashes help find
    /// the upstream version of a skill taken over from it).
    public var skillsShLock: URL

    public init(store: Store = Store(),
                cacheRoot: URL = Paths.home.appendingPathComponent("Library/Caches/Tackroom/sources", isDirectory: true),
                skillsShLock: URL = Paths.home.appendingPathComponent(".agents/.skill-lock.json")) {
        self.store = store
        self.cacheRoot = cacheRoot
        self.skillsShLock = skillsShLock
    }

    func cacheDir(for remote: String, ref: String?) -> URL {
        let key = remote.replacingOccurrences(of: "https://", with: "") + (ref.map { "@" + $0 } ?? "")
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return cacheRoot.appendingPathComponent(String(safe), isDirectory: true)
    }

    /// Back-compat entry point.
    public func check() -> (updates: [UpdateCandidate], failures: [String: String]) {
        let r = run()
        return (r.updates, r.failures)
    }

    /// Fetches each upstream once (unless `fetch` is false: then the copies
    /// already downloaded are compared again, e.g. after a local change) and
    /// reports skills whose upstream folder changed since the installed
    /// version. Skills that are pinned or kept in your own folder are left out.
    public func run(fetch: Bool = true) -> UpdateCheckResult {
        let lock = store.readLock()
        var result = UpdateCheckResult()
        var fetched: [URL: Result<String, Error>] = [:]
        let treesFromSkillsSh = SkillsShLock.folderTrees(url: skillsShLock)

        for name in lock.skills.keys.sorted() {
            let entry = lock.skills[name]!
            guard !entry.pinned, entry.linkedPath == nil, let remote = entry.remoteURL else { continue }
            let dir = cacheDir(for: remote, ref: entry.ref)
            if fetched[dir] == nil {
                fetched[dir] = Result {
                    if !fetch, FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                        return try head(dir)
                    }
                    return try refresh(remote, into: dir, ref: entry.ref)
                }
            }
            func fail(_ why: String) { result.failures[name] = why; result.status[name] = .failed(why) }
            switch fetched[dir]! {
            case .failure(let error):
                fail(Self.plain(error))
            case .success(let commit):
                let newPath = entry.path.map { dir.appendingPathComponent($0).path } ?? dir.path
                guard FileManager.default.fileExists(atPath: (newPath as NSString).appendingPathComponent("SKILL.md")) else {
                    if let moved = SkillFinder.find(in: dir.path).first(where: { $0.name == name }), let rel = moved.pathInSource {
                        fail(L("上游把這個 skill 搬到了 \(rel)，目前的來源位置已經沒有它"))
                    } else {
                        fail(L("上游已經沒有這個 skill（\(entry.path ?? L("根目錄"))）"))
                    }
                    continue
                }
                let localPath = store.location(of: name, entry: entry)
                guard FileManager.default.fileExists(atPath: localPath) else { fail(L("本機的檔案不見了")); continue }
                let newHash = Scanner.hashFolder(newPath).0
                let localHash = Scanner.hashFolder(localPath).0

                let header = URL(fileURLWithPath: newPath).appendingPathComponent("SKILL.md")
                let declared = (try? String(contentsOf: header, encoding: .utf8)).flatMap(Frontmatter.parse)?.name
                let renamed = declared.flatMap { $0.isEmpty || $0 == name ? nil : $0 }
                // 舊版可能已套用改名的檔案，登記與入口卻仍是舊名。沿用審閱流程修復。
                if localHash == newHash, localHash == entry.contentHash, let renamed,
                   !entry.skipped.contains(newHash) {
                    result.updates.append(UpdateCandidate(name: name, fromCommit: entry.commit, toCommit: commit,
                        newPath: newPath, oldPath: localPath, newHash: newHash, localHash: localHash, local: .none, renamedTo: renamed))
                    result.status[name] = .update
                    continue
                }

                if localHash == newHash {
                    if entry.upstreamHash != newHash { result.foundBases[name] = (commit, newHash) }
                    result.status[name] = .current
                    continue
                }
                let base = findBase(name: name, entry: entry, repo: dir, head: commit, newHash: newHash,
                                    localPath: localPath, localHash: localHash, trees: treesFromSkillsSh)
                if let base, base.found { result.foundBases[name] = (base.commit ?? commit, base.hash) }
                if base?.hash == newHash { result.status[name] = .current; continue }
                if entry.skipped.contains(newHash) || entry.skipped.contains(commit) {
                    result.status[name] = .skipped
                    continue
                }
                let local: LocalChange
                if let base {
                    if localHash == base.hash { local = .none }
                    else { local = .edited(whitespaceOnly: base.path.map { Differ.whitespaceOnly(old: $0, new: localPath) } ?? false) }
                } else {
                    local = .unknown
                }
                result.updates.append(UpdateCandidate(
                    name: name, fromCommit: base?.commit, toCommit: commit, newPath: newPath, oldPath: localPath,
                    newHash: newHash, basePath: base?.path, baseHash: base?.hash, localHash: localHash, local: local,
                    renamedTo: renamed))
                result.status[name] = .update
            }
        }
        return result
    }

    struct Base { var commit: String?; var hash: String; var path: String?; var found: Bool }

    /// The upstream version the installed files came from.
    /// 1. Recorded (`upstreamHash`, with `commit` to unpack it).
    /// 2. Older records with only `commit`: unpack it and hash it.
    /// 3. Otherwise search the upstream history for a version that matches
    ///    the installed files, or the folder skills.sh recorded when it
    ///    installed the skill.
    func findBase(name: String, entry: LockEntry, repo: URL, head: String, newHash: String,
                  localPath: String, localHash: String, trees: [String: String]) -> Base? {
        let git = Git(directory: repo)
        let sub = entry.path ?? ""
        func unpack(_ commit: String) -> String? {
            let out = cacheRoot.appendingPathComponent("bases/\(repo.lastPathComponent)/\(commit)/\(name)", isDirectory: true)
            if FileManager.default.fileExists(atPath: out.appendingPathComponent("SKILL.md").path) { return out.path }
            do { try git.export(tree: "\(commit):\(sub)", to: out); return out.path } catch { return nil }
        }
        if let hash = entry.upstreamHash {
            // Without the commit the files can't be unpacked, but untouched
            // installed files are that version.
            let path = entry.commit.flatMap(unpack) ?? (localHash == hash ? localPath : nil)
            return Base(commit: entry.commit, hash: hash, path: path, found: false)
        }
        if let commit = entry.commit, let path = unpack(commit) {
            return Base(commit: commit, hash: Scanner.hashFolder(path).0, path: path, found: true)
        }
        // The recorded files equal the current upstream (installed before
        // Tackroom kept the base separately): that is the base.
        if entry.contentHash == newHash {
            let dir = sub.isEmpty ? repo.path : repo.appendingPathComponent(sub).path
            return Base(commit: head, hash: newHash, path: dir, found: true)
        }
        var wanted: [String] = []
        if let t = try? git.treeID(of: localPath) { wanted.append(t) }
        if let t = trees[name] { wanted.append(t) }
        guard !wanted.isEmpty, let commit = commitWithTree(wanted, path: sub, repo: git), let path = unpack(commit) else { return nil }
        return Base(commit: commit, hash: Scanner.hashFolder(path).0, path: path, found: true)
    }

    /// The newest commit whose folder at `path` is one of `trees`.
    func commitWithTree(_ trees: [String], path: String, repo git: Git) -> String? {
        let log = (try? git.run(["log", "-n", "400", "--format=%h", "HEAD", "--"] + (path.isEmpty ? [] : [path]))) ?? ""
        let commits = log.split(separator: "\n").map(String.init)
        guard !commits.isEmpty else { return nil }
        let query = commits.map { "\($0):\(path)" }.joined(separator: "\n") + "\n"
        guard let out = try? git.run(["cat-file", "--batch-check=%(objectname)"], allowFailure: true, input: query) else { return nil }
        let ids = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, commit) in commits.enumerated() where i < ids.count {
            if trees.contains(ids[i]) { return commit }
        }
        return nil
    }

    func head(_ dir: URL) throws -> String {
        try Git(directory: dir).run(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Brings the cached copy up to date and returns its short commit. The
    /// cache keeps the full history of commits and folders (file contents
    /// are fetched only when needed), so earlier versions can be unpacked.
    func refresh(_ remote: String, into dir: URL, ref: String?) throws -> String {
        guard Self.allowedRemote(remote), ref.map({ !$0.hasPrefix("-") }) ?? true else {
            throw TackroomError.invalid(L("來源位址不被接受：\(remote)"))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let gitDir = dir.appendingPathComponent(".git")
        // Older caches were shallow (latest commit only): start those over.
        if fm.fileExists(atPath: gitDir.appendingPathComponent("shallow").path) { try? fm.removeItem(at: dir) }
        if !fm.fileExists(atPath: gitDir.path) {
            try? fm.removeItem(at: dir)
            var args = ["clone", "-q", "--filter=blob:none"]
            if let ref { args += ["--branch", ref] }
            try Git(directory: cacheRoot).run(args + ["--", remote, dir.path])
        } else {
            let git = Git(directory: dir)
            try git.run(["fetch", "-q", "origin", ref ?? "HEAD"])
            try git.run(["reset", "-q", "--hard", "FETCH_HEAD"])
            try git.run(["clean", "-q", "-fdx"])
        }
        return try head(dir)
    }

    /// Only ordinary addresses: https, ssh, git@host:… and local file:// (tests).
    static func allowedRemote(_ remote: String) -> Bool {
        guard !remote.hasPrefix("-") else { return false }
        return ["https://", "ssh://", "git@", "file://"].contains { remote.hasPrefix($0) }
    }

    /// Git's message turned into a plain reason.
    static func plain(_ error: Error) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("could not resolve host") || lower.contains("unable to access") || lower.contains("network")
            || lower.contains("timed out") {
            return L("連不上來源（可能沒有網路）")
        }
        if lower.contains("not found") || lower.contains("repository") && lower.contains("does not exist") {
            return L("找不到來源 repo（可能已改名、刪除或設為私人）")
        }
        if lower.contains("authentication") || lower.contains("could not read username") {
            return L("來源需要登入才能讀取")
        }
        return text
    }
}

// MARK: - Comparing versions

public struct LineDiff: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case same, removed, added }
    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
}

public struct FileChange: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case added, removed, modified }
    public var id: String { path }
    public var path: String
    public var kind: Kind
    /// nil for binary or very large files.
    public var lines: [LineDiff]?
    public var risks: [RiskFinding]
    public var severity: RiskSeverity { risks.map(\.severity).max() ?? .none }
}

public enum Differ {
    static let maxLines = 4000

    /// Files that differ between two skill folders, riskiest first. Links
    /// inside a skill count as entries too (shown as 「捷徑 → 目標」), so
    /// a new link to a private file can't slip through as「沒有變更」.
    public static func compare(old: String, new: String) -> [FileChange] {
        let oldFiles = files(in: old), newFiles = files(in: new)
        var changes: [FileChange] = []
        for path in Set(oldFiles.keys).union(newFiles.keys).sorted() {
            let a = oldFiles[path], b = newFiles[path]
            if let a, let b, a == b { continue }
            let kind: FileChange.Kind = a == nil ? .added : (b == nil ? .removed : .modified)
            let oldText = a.flatMap(readable), newText = b.flatMap(readable)
            var lines: [LineDiff]?
            if (a == nil || oldText != nil) && (b == nil || newText != nil) {
                lines = diffLines(oldText ?? "", newText ?? "")
            }
            let isExecutable = b.flatMap(linkTarget) == nil
                && FileManager.default.isExecutableFile(atPath: (new as NSString).appendingPathComponent(path))
            var risks = RiskRules.findings(path: path, kind: kind, lines: lines, newIsExecutable: b != nil && isExecutable,
                                           newIsBinary: b != nil && newText == nil)
            if let target = b.flatMap(linkTarget), pointsOutside(target, from: path) {
                risks.insert(RiskFinding(severity: .high, text: L("捷徑指向 skill 以外的位置：\(path)"), line: "→ " + target), at: 0)
            }
            changes.append(FileChange(path: path, kind: kind, lines: lines, risks: risks))
        }
        return changes.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity
                : ($0.path == "SKILL.md") != ($1.path == "SKILL.md") ? $0.path == "SKILL.md" : $0.path < $1.path
        }
    }

    /// The two folders hold the same files and the texts differ only in
    /// spaces, tabs or line breaks.
    public static func whitespaceOnly(old: String, new: String) -> Bool {
        let a = files(in: old), b = files(in: new)
        guard Set(a.keys) == Set(b.keys), a != b else { return false }
        for (path, x) in a {
            guard let y = b[path], x != y else { continue }
            guard linkTarget(x) == nil, linkTarget(y) == nil,
                  let s = String(data: x, encoding: .utf8), let t = String(data: y, encoding: .utf8) else { return false }
            if s.filter({ !$0.isWhitespace }) != t.filter({ !$0.isWhitespace }) { return false }
        }
        return true
    }

    static let linkMark = Data("\u{1}tackroom-link\u{1}".utf8)

    /// Every file and link in a skill folder: files by their bytes, links as
    /// a marked entry holding their target.
    static func files(in root: String) -> [String: Data] {
        var result: [String: Data] = [:]
        let fm = FileManager.default
        let base = Paths.realpath(root) ?? root
        guard let walker = fm.enumerator(atPath: base) else { return result }
        for case let rel as String in walker {
            if Scanner.isIgnored((rel as NSString).lastPathComponent) { walker.skipDescendants(); continue }
            let path = (base as NSString).appendingPathComponent(rel)
            // attributesOfItem looks at the link itself, not where it points.
            let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                if let target = try? fm.destinationOfSymbolicLink(atPath: path) { result[rel] = linkMark + Data(target.utf8) }
            } else if type == .typeRegular {
                result[rel] = try? Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
        return result
    }

    static func linkTarget(_ data: Data) -> String? {
        guard data.starts(with: linkMark) else { return nil }
        return String(decoding: data.dropFirst(linkMark.count), as: UTF8.self)
    }

    /// Text to show for an entry: the file's text, or 「捷徑 → 目標」.
    static func readable(_ data: Data) -> String? {
        if let target = linkTarget(data) { return L("捷徑 → ") + target }
        return String(data: data, encoding: .utf8)
    }

    /// Links inside a skill folder that lead out of it.
    public static func outsideLinks(in folder: String) -> [String] {
        files(in: folder).compactMap { path, data in
            linkTarget(data).flatMap { pointsOutside($0, from: path) ? "\(path) → \($0)" : nil }
        }.sorted()
    }

    /// A link target that leaves the skill folder (absolute, `~`, or too many `..`).
    static func pointsOutside(_ target: String, from path: String) -> Bool {
        if target.hasPrefix("/") || target.hasPrefix("~") { return true }
        var depth = path.split(separator: "/").count - 1
        for part in target.split(separator: "/") {
            if part == ".." { depth -= 1; if depth < 0 { return true } } else if part != "." { depth += 1 }
        }
        return false
    }

    /// Line diff by longest common subsequence (skill files are small).
    public static func diffLines(_ old: String, _ new: String) -> [LineDiff]? {
        let allA = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let allB = new.isEmpty ? [] : new.components(separatedBy: "\n")
        // Lines the two share at the start and end need no table; only the
        // middle is compared, which keeps memory small for long files.
        var head = 0
        while head < allA.count, head < allB.count, allA[head] == allB[head] { head += 1 }
        var tail = 0
        while tail < allA.count - head, tail < allB.count - head, allA[allA.count - 1 - tail] == allB[allB.count - 1 - tail] { tail += 1 }
        let a = Array(allA[head..<(allA.count - tail)]), b = Array(allB[head..<(allB.count - tail)])
        guard a.count <= maxLines, b.count <= maxLines else { return nil }
        let n = a.count, m = b.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var out: [LineDiff] = (0..<head).map { LineDiff(kind: .same, text: allA[$0], oldNumber: $0 + 1, newNumber: $0 + 1) }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(LineDiff(kind: .same, text: a[i], oldNumber: head + i + 1, newNumber: head + j + 1)); i += 1; j += 1
            } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
                out.append(LineDiff(kind: .added, text: b[j], oldNumber: nil, newNumber: head + j + 1)); j += 1
            } else {
                out.append(LineDiff(kind: .removed, text: a[i], oldNumber: head + i + 1, newNumber: nil)); i += 1
            }
        }
        for k in 0..<tail {
            let ai = allA.count - tail + k, bi = allB.count - tail + k
            out.append(LineDiff(kind: .same, text: allA[ai], oldNumber: ai + 1, newNumber: bi + 1))
        }
        return out
    }
}

// MARK: - Merging

/// The author's changes laid over the user's edits, file by file.
public struct MergeResult: Sendable, Hashable {
    /// The merged folder (in a scratch place), ready to copy in.
    public var path: String
    public var hash: String
    /// Files both sides changed in the same place (or one deleted and the
    /// other edited); nothing is merged when any are listed.
    public var conflicts: [String]
    /// Files taken from the new upstream version.
    public var fromUpstream: [String]
    /// Files where the user's edits were kept (alone or merged).
    public var kept: [String]
}

public enum Merger {
    /// Three-way merge of skill folders. A file changed on one side only
    /// takes that side; changed on both, its lines are merged with
    /// `git merge-file` when the changes don't overlap.
    public static func merge(base: String, local: String, new: String, into out: URL) throws -> MergeResult {
        let b = Differ.files(in: base), l = Differ.files(in: local), n = Differ.files(in: new)
        let fm = FileManager.default
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        var conflicts: [String] = [], fromUpstream: [String] = [], kept: [String] = []
        var merged: [String: Data] = [:]
        for path in Set(b.keys).union(l.keys).union(n.keys).sorted() {
            let x = b[path], y = l[path], z = n[path]
            if y == z { if let y { merged[path] = y }; continue }
            if y == x { if let z { merged[path] = z }; fromUpstream.append(path); continue }
            if z == x { if let y { merged[path] = y }; kept.append(path); continue }
            // Both sides changed it.
            guard let y, let z else { conflicts.append(path); continue }
            guard let text = mergeText(base: x ?? Data(), local: y, new: z) else { conflicts.append(path); continue }
            merged[path] = text
            kept.append(path)
            fromUpstream.append(path)
        }
        guard conflicts.isEmpty else {
            return MergeResult(path: out.path, hash: "", conflicts: conflicts, fromUpstream: fromUpstream, kept: kept)
        }
        for (path, data) in merged {
            let url = out.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Links stay links, pointing where they pointed.
            if let target = Differ.linkTarget(data) {
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
                continue
            }
            try data.write(to: url)
            // Keep programs runnable as they were on the side the file came from.
            let source = [local, new].map { ($0 as NSString).appendingPathComponent(path) }.first { fm.fileExists(atPath: $0) }
            if let source, let mode = (try? fm.attributesOfItem(atPath: source))?[.posixPermissions] {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }
        }
        return MergeResult(path: out.path, hash: Scanner.hashFolder(out.path).0, conflicts: [], fromUpstream: fromUpstream, kept: kept)
    }

    /// nil when the texts can't be merged cleanly (or aren't text).
    static func mergeText(base: Data, local: Data, new: Data) -> Data? {
        guard [base, local, new].allSatisfy({ Differ.linkTarget($0) == nil }), String(data: base, encoding: .utf8) != nil, String(data: local, encoding: .utf8) != nil,
              String(data: new, encoding: .utf8) != nil else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tackroom-merge-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let files = [("mine", local), ("base", base), ("theirs", new)].map { (dir.appendingPathComponent($0.0), $0.1) }
            for (url, data) in files { try data.write(to: url) }
            let (out, status) = try Git(directory: dir).runStatus(["merge-file", "-p", "-q"] + files.map(\.0.path), allowFailure: true)
            return status == 0 ? Data(out.utf8) : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Risk rules

public enum RiskSeverity: Int, Sendable, Hashable, Comparable {
    case none = 0, low, medium, high
    public static func < (a: RiskSeverity, b: RiskSeverity) -> Bool { a.rawValue < b.rawValue }
}

public struct RiskFinding: Sendable, Hashable {
    /// What kind of risk, for the one-line summary (the text is translated).
    public enum Topic: Sendable, Hashable { case secrets, addsProgram, network, other }
    public var severity: RiskSeverity
    public var topic: Topic = .other
    /// Plain sentence, e.g. 「新增會把資料送到 example.com」.
    public var text: String
    /// The new line that triggered it, if any.
    public var line: String?
}

/// Looks only at what the new version adds: behavior changes come first.
public enum RiskRules {
    struct Rule: @unchecked Sendable {
        var severity: RiskSeverity
        var pattern: NSRegularExpression
        var topic: RiskFinding.Topic = .other
        var text: @Sendable (String) -> String
    }

    static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    static let rules: [Rule] = [
        Rule(severity: .high, pattern: rx(#"(curl|wget)[^\n|]*\|\s*(ba|z)?sh|base64\s+(-d|--decode)[^\n]*\|\s*(ba|z)?sh|eval\s*\(?\s*["$`]"#),
             text: { _ in L("下載或解碼後直接執行程式碼") }),
        Rule(severity: .high, pattern: rx(#"\b(sudo|rm\s+-rf\s+[~/$]|chmod\s+(-R\s+)?777|launchctl|crontab)\b"#),
             text: { _ in L("要求系統權限或會大範圍刪改檔案") }),
        Rule(severity: .high, pattern: rx(#"(\.ssh|id_rsa|keychain|security\s+find-|\.aws/credentials|\.netrc|\b[A-Z_]*(TOKEN|SECRET|API_KEY|PASSWORD)\b)"#), topic: .secrets,
             text: { _ in L("會讀取金鑰、密碼或登入資訊") }),
        Rule(severity: .high, pattern: rx(#"(ignore (all |any )?(previous|prior|above) instructions|do not (tell|inform) the user|without (asking|telling) the user)"#),
             text: { _ in L("說明文字要 AI 忽略你的指示或瞞著你") }),
        Rule(severity: .high, pattern: rx(#"((忽略|無視|无视|忽視|忽视)[^\n]{0,8}(之前|先前|上面|以上|前面|原本)[^\n]{0,6}(指示|指令|規則|规则|要求)|(不要|別|别|勿)(告訴|告诉|通知|讓|让)[^\n]{0,4}(使用者|用戶|用户)|(瞞著|瞒着|背著|背着)(使用者|用戶|用户))"#),
             text: { _ in L("說明文字要 AI 忽略你的指示或瞞著你") }),
        Rule(severity: .high, pattern: rx(#"\b(os\.system|subprocess\.|python3?\s+-c|node\s+-e|child_process)"#),
             text: { _ in L("新增會執行其他程式的指令") }),
        Rule(severity: .medium, pattern: rx(#"https?://([a-z0-9.-]+)"#), topic: .network,
             text: { host in L("新增連到 \(host) 的網址") }),
        Rule(severity: .medium, pattern: rx(#"\b(curl|wget|fetch\(|requests\.(get|post)|urllib|axios|http\.request|nc\s+-)"#), topic: .network,
             text: { _ in L("新增會連網的程式") }),
        Rule(severity: .medium, pattern: rx(#"(~/|\$HOME|/Users/|\.\./\.\.)"#),
             text: { _ in L("會讀寫專案以外的檔案") }),
        Rule(severity: .low, pattern: rx(#"\b(always|must|never) (run|execute|use)\b"#),
             text: { _ in L("說明文字新增了強制 AI 的用語") }),
    ]

    public static func findings(path: String, kind: FileChange.Kind, lines: [LineDiff]?,
                                newIsExecutable: Bool, newIsBinary: Bool) -> [RiskFinding] {
        var result: [RiskFinding] = []
        if kind == .added {
            let ext = (path as NSString).pathExtension.lowercased()
            if newIsExecutable || Scanner.scriptExtensions.contains(ext) {
                result.append(RiskFinding(severity: .high, topic: .addsProgram, text: L("新增會執行的程式：\(path)"), line: nil))
            } else if newIsBinary {
                result.append(RiskFinding(severity: .medium, text: L("新增無法閱讀的二進位檔：\(path)"), line: nil))
            }
        }
        for line in lines ?? [] where line.kind == .added {
            let text = line.text
            let range = NSRange(text.startIndex..., in: text)
            for rule in rules {
                guard let match = rule.pattern.firstMatch(in: text, range: range) else { continue }
                let captured = match.numberOfRanges > 1 ? Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? "" : ""
                let finding = RiskFinding(severity: rule.severity, topic: rule.topic, text: rule.text(captured),
                                          line: String(text.trimmingCharacters(in: .whitespaces).prefix(160)))
                if !result.contains(where: { $0.text == finding.text }) { result.append(finding) }
            }
        }
        return result
    }
}

// MARK: - Plans

public extension Operations {
    /// Replaces the installed files with exactly the reviewed version. When
    /// the installed files had edits of their own, those are replaced too;
    /// the previous files stay in the store's history, so 紀錄 can put them back.
    func planApplyUpdate(_ update: UpdateCandidate) -> Plan {
        let original = store.readLock()
        let dropsEdits = update.local != .none
        let title = dropsEdits ? L("改用 \(update.name) 的新版（\(update.toCommit)），取代本機版本")
            : L("更新 \(update.name) \(update.fromCommit ?? L("本機版")) → \(update.toCommit)")
        guard var entry = original.skills[update.name] else {
            return Plan(title: title, op: .update(name: update.name), actor: actor, preview: [], steps: [],
                        blocker: L("「\(update.name)」已經不由 Tackroom 管理。"))
        }
        let entryBefore = entry
        entry.commit = update.toCommit
        entry.contentHash = update.newHash
        entry.upstreamHash = update.newHash
        entry.skipped.removeAll()
        let changes = Differ.compare(old: update.oldPath, new: update.newPath)
        var preview = [PreviewLine(kind: .change, text: L("替換 \(update.name) 的 \(changes.count) 個檔案"))]
        if dropsEdits {
            preview.append(PreviewLine(kind: .warning, text: L("本機版本與上游不同的地方會被新版取代；可在「紀錄」退回")))
        }
        preview += agentsLine(entry)
        return updatedPlan(update, title: title, preview: preview, original: original, entry: entry,
                           files: update.newPath, checks: [.verifyHash(path: update.newPath, hash: update.newHash),
                                                           .verifyLocal(path: update.oldPath, hash: update.localHash)],
                           saveEdits: keepUnrecorded(update, recorded: entryBefore))
    }

    /// Takes the author's changes and keeps the user's edits. Only offered
    /// when the two touch different parts (`merge.conflicts` is empty).
    func planMergeUpdate(_ update: UpdateCandidate, merge: MergeResult) -> Plan {
        let original = store.readLock()
        let title = L("更新 \(update.name) 到 \(update.toCommit)，保留本機修改")
        guard var entry = original.skills[update.name] else {
            return Plan(title: title, op: .update(name: update.name), actor: actor, preview: [], steps: [],
                        blocker: L("「\(update.name)」已經不由 Tackroom 管理。"))
        }
        guard merge.conflicts.isEmpty else {
            return Plan(title: title, op: .update(name: update.name), actor: actor, preview: [], steps: [],
                        blocker: L("兩邊改到同一段：\(merge.conflicts.joined(separator: L("、")))，無法自動合併。"))
        }
        let entryBefore = entry
        entry.commit = update.toCommit
        entry.upstreamHash = update.newHash
        entry.contentHash = merge.hash
        entry.skipped.removeAll()
        let preview = [PreviewLine(kind: .change, text: L("套用上游的 \(merge.fromUpstream.count) 個檔案變更")),
                       PreviewLine(kind: .keep, text: L("保留你修改過的 \(merge.kept.count) 個檔案中的修改"))]
            + agentsLine(entry)
        return updatedPlan(update, title: title, preview: preview, original: original, entry: entry,
                           files: merge.path, checks: [.verifyHash(path: update.newPath, hash: update.newHash),
                                                      .verifyLocal(path: update.oldPath, hash: update.localHash),
                                                      .verifyHash(path: merge.path, hash: merge.hash)],
                           saveEdits: keepUnrecorded(update, recorded: entryBefore))
    }

    private func updatedPlan(_ update: UpdateCandidate, title: String, preview: [PreviewLine], original: Lockfile,
                             entry: LockEntry, files: String, checks: [Step], saveEdits: [Step]) -> Plan {
        let name = update.name
        // 合併可能保留本機對 name 的編輯，以實際要安裝的 SKILL.md 為準。
        let file = URL(fileURLWithPath: files).appendingPathComponent("SKILL.md")
        let declared = (try? String(contentsOf: file, encoding: .utf8)).flatMap(Frontmatter.parse)?.name
        let newName = declared.flatMap { $0.isEmpty ? nil : $0 } ?? name
        if newName != name {
            let repairing = update.localHash == update.newHash && original.skills[name]?.contentHash == update.newHash
            var renamed = repairing ? (original.skills[name] ?? entry) : entry
            renamed.entryFolders = nil
            return renamePlan(from: name, to: newName, original: original, entry: renamed,
                              install: .createCopy(from: repairing ? update.oldPath : files, to: store.skillDir(newName).path),
                              checks: checks, saveEdits: saveEdits, preview: preview,
                              title: repairing ? L("同步 \(name) 的新名稱 \(newName)") : title,
                              op: repairing ? .setting(name: newName) : .update(name: name, renamedTo: newName))
        }
        var lock = original
        lock.skills[name] = entry
        return Plan(title: title, op: .update(name: name), actor: actor, preview: preview,
                    steps: checks + saveEdits + [.copyDir(from: files, to: store.skillDir(name).path),
                                                 .patchLock(base: original, new: lock), .commit(title)], blocker: nil)
    }

    /// 分別檢查保管區與 agent 的磁碟；兩個真的存在的入口即使連到同一份檔案也不能混用。
    private func isCaseAlias(_ alternate: String, of path: String) -> Bool {
        let source = URL(fileURLWithPath: path), other = URL(fileURLWithPath: alternate)
        let parent = source.deletingLastPathComponent()
        guard parent.path == other.deletingLastPathComponent().path,
              source.lastPathComponent != other.lastPathComponent,
              source.lastPathComponent.caseInsensitiveCompare(other.lastPathComponent) == .orderedSame,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
              entries.contains(source.lastPathComponent), !entries.contains(other.lastPathComponent) else { return false }
        var first = stat(), second = stat()
        return lstat(path, &first) == 0 && lstat(alternate, &second) == 0
            && first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private func renamePlan(from name: String, to newName: String, original: Lockfile, entry: LockEntry,
                            install: Step, checks: [Step], saveEdits: [Step], preview: [PreviewLine],
                            title: String, op: JournalOp) -> Plan {
        func blocked(_ why: String) -> Plan {
            Plan(title: title, op: op, actor: actor, preview: [], steps: [], blocker: why)
        }
        guard SkillName.isSafe(newName) else { return blocked(SkillName.problem) }
        guard let before = original.skills[name], before.linkedPath == nil, original.skills[newName] == nil else {
            return blocked(L("無法將「\(name)」改名為「\(newName)」，請確認管理紀錄。"))
        }
        let fm = FileManager.default
        let oldDir = store.skillDir(name).path, newDir = store.skillDir(newName).path
        var expected = checks
        var replaceLinks: [Step] = []
        func occupied(_ path: String) -> Bool { fm.fileExists(atPath: path) || isSymlink(path) }
        let sameFolder = !isSymlink(oldDir) && isCaseAlias(newDir, of: oldDir)
        guard sameFolder || !occupied(newDir) else { return blocked(L("新版名稱的保管位置已存在：\(short(newDir))")) }
        let conflict = Inventory.scan(adapters: adapters, codexDisabled: []).flatMap(\.placements).first {
            $0.copy.name == newName && $0.copy.resolvedPath != Paths.realpath(oldDir)
        }
        if let conflict { return blocked(L("「\(newName)」已有另一份 skill：\(short(conflict.copy.entryPath))")) }
        if !sameFolder { expected.append(.verifyEntry(path: newDir, link: nil)) }
        for adapter in writable {
            let paths = entryPaths(adapter, name: name, entry: before)
            let destinations = entry.harnesses.contains(adapter.id)
                ? entryPaths(adapter, name: newName, entry: entry, discoverExisting: false) : []
            var retiring: [String] = []
            for path in paths where occupied(path) {
                guard let raw = try? fm.destinationOfSymbolicLink(atPath: path), pointsTo(path, oldDir) else {
                    if before.harnesses.contains(adapter.id) { return blocked(L("入口已改指別處：\(short(path))")) }
                    continue
                }
                retiring.append(path)
                expected.append(.verifyEntry(path: path, link: raw))
                replaceLinks.append(.unlinkMatching(path: path, link: raw))
            }
            for path in destinations {
                if !retiring.contains(where: { $0 == path || isCaseAlias(path, of: $0) }) {
                    guard !occupied(path) else { return blocked(L("新名稱的入口已存在：\(short(path))")) }
                    expected.append(.verifyEntry(path: path, link: nil))
                }
                replaceLinks.append(.link(at: path, to: newDir))
            }
        }
        let fingerprint: String?
        do { fingerprint = try Scanner.removalFingerprint(at: oldDir) }
        catch { return blocked(L("無法核對目前的檔案：\(error.localizedDescription)")) }
        var updated = original
        updated.skills[name] = nil
        updated.skills[newName] = entry
        let fileSteps: [Step]
        if sameFolder {
            let staging = store.stateDir.appendingPathComponent(name + "-" + UUID().uuidString).path
            // 先騰出同一個目錄項；舊版已套用內容的修復仍須從暫存原件複製本機檔案。
            var publish = install
            if case .createCopy(let from, let to) = install, from == oldDir {
                publish = .createCopy(from: staging, to: to)
            }
            fileSteps = [.stageForCaseRename(name: name, entry: before, fingerprint: fingerprint, to: staging), publish]
                + replaceLinks + [.trash(staging)]
        } else {
            fileSteps = [install] + replaceLinks + [.trashReviewed(name: name, entry: before, fingerprint: fingerprint)]
        }
        return Plan(title: title, op: op, actor: actor,
                    preview: preview + [PreviewLine(kind: .change, text: L("名稱與 agent 入口：\(name) → \(newName)"))],
                    steps: expected + saveEdits + fileSteps
                        + [.patchLock(base: original, new: updated), .renamePreferences(from: name, to: newName), .commit(title)], blocker: nil)
    }

    /// Edits made outside Tackroom and never recorded live only on disk.
    /// Commit them first, so undoing the update brings them back too.
    private func keepUnrecorded(_ update: UpdateCandidate, recorded entry: LockEntry) -> [Step] {
        guard update.localHash != entry.contentHash, entry.linkedPath == nil else { return [] }
        return [.include("skills/\(SkillName.folder(update.name))"),
                .commitAs(title: L("保存 \(update.name) 更新前的本機檔案"), op: .setting(name: update.name))]
    }

    /// Keeps the installed files; this upstream version (by content) is not
    /// offered again. A later, different upstream version still is.
    func planSkipUpdate(_ update: UpdateCandidate) -> Plan {
        let original = store.readLock()
        var lock = original
        let title = update.local == .none ? L("略過 \(update.name) 的 \(update.toCommit) 版")
            : L("保留 \(update.name) 的本機版本，略過上游 \(update.toCommit) 版")
        if var entry = lock.skills[update.name] {
            if !entry.skipped.contains(update.newHash) { entry.skipped.append(update.newHash) }
            // Remember the base found during the check, so the next check needn't search again.
            if entry.upstreamHash == nil, let hash = update.baseHash {
                entry.upstreamHash = hash
                entry.commit = update.fromCommit ?? entry.commit
            }
            lock.skills[update.name] = entry
        }
        return Plan(title: title, op: .setting(name: update.name), actor: actor, preview: [],
                    steps: [.patchLock(base: original, new: lock), .commit(title)], blocker: nil)
    }

    func planPin(_ name: String, pinned: Bool) -> Plan {
        let original = store.readLock()
        var lock = original
        let title = pinned ? L("固定 \(name) 目前的版本") : L("取消固定 \(name) 目前的版本")
        lock.skills[name]?.pinned = pinned
        return Plan(title: title, op: .setting(name: name), actor: actor, preview: [],
                    steps: [.patchLock(base: original, new: lock), .commit(title)], blocker: nil)
    }

    /// Puts back the version from before an update.
    internal func planRevertUpdate(_ name: String, updatedIn commit: String, renamedTo: String? = nil) -> Plan {
        let original = store.readLock()
        var lock = original
        let title = L("退回 \(name) 更新前的版本")
        func blocked(_ reason: String) -> Plan {
            Plan(title: title, op: .update(name: name), actor: actor, preview: [], steps: [], blocker: reason)
        }
        let dir = "skills/\(SkillName.folder(name))"
        guard let before = try? store.git.run(["show", "\(commit)^:tackroom.lock"]),
              let old = Lockfile.parse(before).skills[name],
              let after = try? store.git.run(["show", "\(commit):tackroom.lock"]),
              let applied = Lockfile.parse(after).skills[renamedTo ?? name] else { return blocked(L("找不到更新時的紀錄。")) }
        var activeName = renamedTo ?? name
        if renamedTo == nil, original.skills[name] == nil,
           let historical = try? store.git.run(["show", "\(commit):\(dir)/SKILL.md"]),
           let declared = Frontmatter.parse(historical)?.name, SkillName.isSafe(declared) {
            activeName = declared
        }
        guard old.linkedPath == nil else {
            return blocked(L("此 skill 的檔案在你自己的資料夾，Tackroom 沒有保存舊版本。"))
        }
        guard var current = original.skills[activeName], current.source == applied.source, current.path == applied.path,
              current.ref == applied.ref, current.installedAt == applied.installedAt,
              current.commit == applied.commit, current.contentHash == applied.contentHash,
              current.upstreamHash == applied.upstreamHash else {
            return blocked(L("此 skill 已經移除、更換來源或另存了其他版本。請先查看最近的紀錄。"))
        }
        guard (try? store.git.run(["cat-file", "-e", "\(commit)^:\(dir)"])) != nil else {
            return blocked(L("找不到更新前的檔案。"))
        }
        let path = store.skillDir(activeName).path
        let fingerprint: String?
        do { fingerprint = try Scanner.removalFingerprint(at: path) }
        catch { return blocked(L("無法核對目前的檔案：\(error.localizedDescription)")) }
        var preview = [PreviewLine(kind: .change, text: L("把 \(name) 換回 \(old.commit ?? L("更新前")) 的版本"))]
        // 編輯器暫存檔等內容不參與日常的版本雜湊，但恢復時會隨目錄移走。
        let status = try? store.git.run(["status", "--porcelain", "--ignored", "--untracked-files=normal", "--", "skills/\(SkillName.folder(activeName))"])
        if status?.isEmpty != true || Scanner.hashFolder(path).0 != current.contentHash {
            preview.append(PreviewLine(kind: .warning, text: L("更新之後又被改過的檔案會一起移到垃圾桶")))
        }
        let reviewed = current
        current.commit = old.commit
        current.contentHash = old.contentHash
        current.upstreamHash = old.upstreamHash
        if current.skipped == applied.skipped { current.skipped = old.skipped }
        if activeName != name {
            current.entryFolders = old.entryFolders
            return renamePlan(from: activeName, to: name, original: original, entry: current,
                              install: .createFromGit(commit: commit + "^", path: dir), checks: [], saveEdits: [],
                              preview: preview, title: title, op: .update(name: activeName, renamedTo: name))
        }
        lock.skills[name] = current
        return Plan(title: title, op: .update(name: name), actor: actor, preview: preview,
                    steps: [.trashReviewed(name: name, entry: reviewed, fingerprint: fingerprint),
                            .restoreFromGit(commit: commit + "^", path: dir),
                            .patchLock(base: original, new: lock), .commit(title)], blocker: nil)
    }

    private func agentsLine(_ entry: LockEntry) -> [PreviewLine] {
        let names = entry.harnesses.compactMap { id in adapters.first { $0.id == id }?.name }
        return names.isEmpty ? [] : [PreviewLine(kind: .keep, text: L("會影響：\(names.joined(separator: L("、")))"))]
    }
}
