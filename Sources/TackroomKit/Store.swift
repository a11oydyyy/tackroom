import Darwin
import Foundation

// MARK: - Lockfile

/// One managed skill, as written in `tackroom.lock`.
public struct LockEntry: Sendable, Hashable, Codable {
    /// Where it came from: `adopted`, `local:<path>`, `github:<owner/repo>`, or
    /// `linked:<path>` for a skill that stays in your own folder.
    public var source: String
    /// Path of the skill inside the source repo (GitHub sources).
    public var path: String?
    public var ref: String?
    /// The upstream commit the installed files came from (the base for updates).
    public var commit: String?
    /// Hash of the files when Tackroom last wrote or accepted them. Differs
    /// from `upstreamHash` once the user keeps changes of their own.
    public var contentHash: String
    /// Hash of the upstream version at `commit`, as published. Updates are
    /// found by comparing the upstream with this, never with `contentHash`,
    /// so local edits are not mistaken for new versions. nil when unknown
    /// (older records, or skills taken over from another installer).
    public var upstreamHash: String?
    /// Agents that have it turned on (adapter ids).
    public var harnesses: [String]
    /// 各 agent 使用非預設名稱的入口；關閉後仍保留，供再次啟用。
    public var entryFolders: [String: [String]]?
    public var pinned: Bool
    /// Upstream versions the user chose to skip: content hashes (older
    /// records may hold commits).
    public var skipped: [String] = []
    public var tags: [String]
    public var installedAt: String

    public init(source: String, path: String? = nil, ref: String? = nil, commit: String? = nil,
                contentHash: String, upstreamHash: String? = nil, harnesses: [String], pinned: Bool = false, tags: [String] = [],
                installedAt: String = ISO8601DateFormatter().string(from: Date())) {
        self.source = source
        self.path = path
        self.ref = ref
        self.commit = commit
        self.contentHash = contentHash
        self.upstreamHash = upstreamHash
        self.harnesses = harnesses
        self.pinned = pinned
        self.tags = tags
        self.installedAt = installedAt
    }

    /// A git address Tackroom can check for new versions, if any.
    public var remoteURL: String? {
        if source.hasPrefix("github:") { return "https://github.com/\(source.dropFirst(7)).git" }
        if source.hasPrefix("git:") { return String(source.dropFirst(4)) }
        return nil
    }

    /// The skill's files differ from the upstream version they came from
    /// (the user kept edits of their own). nil when that version is unknown.
    public var hasLocalEdits: Bool? { upstreamHash.map { $0 != contentHash } }

    /// The skill's files live outside the store (your own folder); Tackroom only links to them.
    public var linkedPath: String? {
        source.hasPrefix("linked:") ? String(source.dropFirst("linked:".count)) : nil
    }
}

public struct Lockfile: Sendable, Hashable, Codable {
    public var skills: [String: LockEntry] = [:]

    public init(skills: [String: LockEntry] = [:]) { self.skills = skills }

    public static func parse(_ text: String) -> Lockfile {
        var lock = Lockfile()
        for table in MiniTOML.parse(text) where table.name.hasPrefix("skills.") && !table.isArrayItem {
            let name = String(table.name.dropFirst("skills.".count))
            let v = table.values
            guard let source = v["source"]?.string else { continue }
            lock.skills[name] = LockEntry(
                source: source, path: v["path"]?.string, ref: v["ref"]?.string, commit: v["commit"]?.string,
                contentHash: v["content_hash"]?.string ?? "", upstreamHash: v["upstream_hash"]?.string,
                harnesses: v["harnesses"]?.strings ?? [],
                pinned: v["pinned"]?.bool ?? false, tags: v["tags"]?.strings ?? [],
                installedAt: v["installed_at"]?.string ?? "")
            lock.skills[name]?.entryFolders = v["entry_folders"]?.table?.compactMapValues(\.strings)
            lock.skills[name]?.skipped = v["skipped"]?.strings ?? []
        }
        return lock
    }

    /// Readable TOML, skills sorted by name.
    public func serialized() -> String {
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\r", with: "\\r") + "\""
        }
        func list(_ a: [String]) -> String { "[" + a.map(q).joined(separator: ", ") + "]" }
        var out = "# Tackroom lockfile: the skills Tackroom manages.\n# Edited by Tackroom; safe to read.\nversion = 1\n"
        for name in skills.keys.sorted() {
            let e = skills[name]!
            out += "\n[skills.\(q(name))]\n"
            out += "source = \(q(e.source))\n"
            if let path = e.path { out += "path = \(q(path))\n" }
            if let ref = e.ref { out += "ref = \(q(ref))\n" }
            if let commit = e.commit { out += "commit = \(q(commit))\n" }
            out += "content_hash = \(q(e.contentHash))\n"
            if let up = e.upstreamHash { out += "upstream_hash = \(q(up))\n" }
            out += "harnesses = \(list(e.harnesses))\n"
            if let folders = e.entryFolders, !folders.isEmpty {
                let pairs = folders.keys.sorted().map { q($0) + " = " + list(folders[$0]!) }
                out += "entry_folders = { " + pairs.joined(separator: ", ") + " }\n"
            }
            out += "pinned = \(e.pinned)\n"
            if !e.skipped.isEmpty { out += "skipped = \(list(e.skipped))\n" }
            if !e.tags.isEmpty { out += "tags = \(list(e.tags))\n" }
            out += "installed_at = \(q(e.installedAt))\n"
        }
        return out
    }
}

// MARK: - Git

/// Runs the system `git`. (The plan calls for libgit2 so other people need no
/// git; while Tackroom is personal, the command-line tool does the same job.)
public struct Git: Sendable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    @discardableResult
    public func run(_ args: [String], allowFailure: Bool = false, env extra: [String: String] = [:],
                    input: String? = nil) throws -> String {
        try runStatus(args, allowFailure: allowFailure, env: extra, input: input).output
    }

    /// Like `run`, but also returns the exit status (for commands such as
    /// `merge-file` whose status carries meaning).
    public func runStatus(_ args: [String], allowFailure: Bool = false, env extra: [String: String] = [:],
                          input: String? = nil) throws -> (output: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Never run hooks or helpers a downloaded repo might bring, and never
        // download large-file payloads.
        process.arguments = ["-C", directory.path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                             "-c", "protocol.ext.allow=never"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_LFS_SKIP_SMUDGE"] = "1"
        for (k, v) in extra { env[k] = v }
        env["GIT_AUTHOR_NAME"] = "Tackroom"
        env["GIT_AUTHOR_EMAIL"] = "tackroom@localhost"
        env["GIT_COMMITTER_NAME"] = "Tackroom"
        env["GIT_COMMITTER_EMAIL"] = "tackroom@localhost"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe = input.map { _ in Pipe() }
        if let inPipe { process.standardInput = inPipe } else { process.standardInput = FileHandle.nullDevice }
        try process.run()
        let outFD = out.fileHandleForReading.fileDescriptor
        let errFD = err.fileHandleForReading.fileDescriptor
        func setNonBlocking(_ fd: Int32) {
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        }
        setNonBlocking(outFD)
        setNonBlocking(errFD)

        let inData = input.map { Data($0.utf8) } ?? Data()
        var inOffset = 0
        var inOpen = false
        var inFD: Int32 = -1
        if let inPipe {
            inFD = inPipe.fileHandleForWriting.fileDescriptor
            _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
            if inData.isEmpty {
                try? inPipe.fileHandleForWriting.close()
            } else {
                setNonBlocking(inFD)
                inOpen = true
            }
        }

        var outData = Data()
        var errData = Data()
        var outOpen = true
        var errOpen = true
        var buffer = [UInt8](repeating: 0, count: 8192)

        func drain(_ fd: Int32, into target: inout Data) -> Bool {
            while true {
                let n = buffer.withUnsafeMutableBytes { ptr in
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    target.append(contentsOf: buffer[..<n])
                } else if n == 0 {
                    return false
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return true
                } else {
                    return false
                }
            }
        }

        while outOpen || errOpen || inOpen {
            var fds: [pollfd] = []
            if outOpen { fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
            if errOpen { fds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)) }
            if inOpen { fds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0)) }
            let ready = fds.withUnsafeMutableBufferPointer { buf in
                Darwin.poll(buf.baseAddress, nfds_t(buf.count), -1)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for pfd in fds where pfd.revents != 0 {
                let revents = Int32(pfd.revents)
                if pfd.fd == inFD && inOpen {
                    if revents & (POLLOUT | POLLERR | POLLHUP | POLLNVAL) != 0 {
                        while inOffset < inData.count {
                            let written = inData.withUnsafeBytes { raw -> Int in
                                guard let base = raw.baseAddress else { return 0 }
                                return Darwin.write(inFD, base.advanced(by: inOffset), inData.count - inOffset)
                            }
                            if written > 0 {
                                inOffset += written
                            } else if written < 0 && errno == EINTR {
                                continue
                            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                                break
                            } else {
                                inOffset = inData.count
                                break
                            }
                        }
                        if inOffset >= inData.count {
                            try? inPipe?.fileHandleForWriting.close()
                            inOpen = false
                        }
                    }
                } else if pfd.fd == outFD && outOpen {
                    if revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                        outOpen = drain(outFD, into: &outData)
                    }
                } else if pfd.fd == errFD && errOpen {
                    if revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 {
                        errOpen = drain(errFD, into: &errData)
                    }
                }
            }
        }

        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()
        if inOpen { try? inPipe?.fileHandleForWriting.close() }
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            throw TackroomError.git(args.first ?? "", String(decoding: errData, as: UTF8.self))
        }
        return (String(decoding: outData, as: UTF8.self), process.terminationStatus)
    }

    /// Copies one tree (`<commit>:<path>`) into an empty folder without
    /// touching the repo's own index or working files.
    public func export(tree: String, to folder: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = fm.temporaryDirectory.appendingPathComponent("tackroom-index-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        try run(["read-tree", tree], env: env)
        try run(["--work-tree=" + folder.path, "checkout-index", "-a", "-f"], env: env)
    }

    /// The git tree id a folder would have if committed (ignoring the same
    /// leftovers Tackroom ignores), to match it against upstream history.
    /// Writes only blob objects into this repo.
    public func treeID(of folder: String) throws -> String {
        let fm = FileManager.default
        let index = fm.temporaryDirectory.appendingPathComponent("tackroom-index-\(UUID().uuidString)")
        let excludes = fm.temporaryDirectory.appendingPathComponent("tackroom-excludes-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: index); try? fm.removeItem(at: excludes) }
        try Scanner.gitExcludePatterns.joined(separator: "\n").write(to: excludes, atomically: true, encoding: .utf8)
        let env = ["GIT_INDEX_FILE": index.path]
        let work = Paths.realpath(folder) ?? folder
        try run(["-c", "core.excludesFile=" + excludes.path, "--work-tree=" + work, "add", "-A", "."], env: env)
        return try run(["write-tree"], env: env).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TackroomError: Error, LocalizedError, Sendable {
    case git(String, String)
    case conflict(String)
    case notFound(String)
    case readOnly(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .git(let cmd, let msg): return L("git \(cmd) 失敗：\(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .conflict(let s), .notFound(let s), .readOnly(let s), .invalid(let s): return s
        }
    }
}

// MARK: - Store

/// `~/.tackroom/store`: a git repo holding managed skills and the lockfile.
public struct Store: Sendable {
    public var root: URL

    public init(root: URL = Store.defaultURL) { self.root = root }

    public static var defaultURL: URL { Paths.home.appendingPathComponent(".tackroom/store", isDirectory: true) }

    public var lockURL: URL { root.appendingPathComponent("tackroom.lock") }
    public var skillsDir: URL { root.appendingPathComponent("skills", isDirectory: true) }
    /// Tackroom's own working files (not committed).
    public var stateDir: URL { root.appendingPathComponent(".tackroom", isDirectory: true) }
    public var git: Git { Git(directory: root) }

    public func skillDir(_ name: String) -> URL { skillsDir.appendingPathComponent(SkillName.folder(name), isDirectory: true) }

    public var exists: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) }

    /// Creates the store on first write.
    public func ensureExists() throws {
        let fm = FileManager.default
        guard !exists else { return }
        try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try "/.tackroom/\n.DS_Store\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try """
        # Tackroom store

        Skills managed by Tackroom. Each folder under `skills/` is one skill;
        `tackroom.lock` lists them and which agents use them. Every change is
        one git commit, so `git log` is the full history.

        """.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Lockfile().serialized().write(to: lockURL, atomically: true, encoding: .utf8)
        try git.run(["init", "-q", "-b", "main"])
        try git.run(["add", "-A"])
        try git.run(["commit", "-q", "-m", "[gui] 建立 Tackroom 保管區"])
    }

    public func readLock() -> Lockfile {
        guard let text = try? String(contentsOf: lockURL, encoding: .utf8) else { return Lockfile() }
        return Lockfile.parse(text)
    }

    public func writeLock(_ lock: Lockfile) throws {
        try lock.serialized().write(to: lockURL, atomically: true, encoding: .utf8)
    }

    /// Bookkeeping for one registered project: `projects/<name>-<id>/`.
    public func projectDir(_ project: Project) -> URL {
        let safe = project.name.replacingOccurrences(of: "/", with: "-")
        return root.appendingPathComponent("projects/\(safe)-\(project.id.uuidString.prefix(8).lowercased())", isDirectory: true)
    }

    public func projectLockURL(_ project: Project) -> URL { projectDir(project).appendingPathComponent("tackroom.lock") }

    /// The approved version of a skill installed into a project.
    public func projectSnapshot(_ project: Project, _ name: String) -> URL {
        projectDir(project).appendingPathComponent("skills/\(SkillName.folder(name))", isDirectory: true)
    }

    public func readProjectLock(_ project: Project) -> Lockfile {
        guard let text = try? String(contentsOf: projectLockURL(project), encoding: .utf8) else { return Lockfile() }
        return Lockfile.parse(text)
    }

    /// Where a managed skill's files are.
    public func location(of name: String, entry: LockEntry) -> String {
        entry.linkedPath ?? skillDir(name).path
    }
}

public extension Store {
    /// Managed skills whose files no longer match the lockfile. Skills kept
    /// in your own folder are left out: their files are yours to edit, and
    /// Tackroom holds no copy to put back.
    func driftedNames(_ lock: Lockfile) -> Set<String> {
        var result: Set<String> = []
        for (name, entry) in lock.skills where entry.linkedPath == nil {
            let location = self.location(of: name, entry: entry)
            guard FileManager.default.fileExists(atPath: location) else { result.insert(name); continue }
            if Scanner.hashFolder(location).0 != entry.contentHash { result.insert(name) }
        }
        return result
    }
}

public extension Store {
    /// The version last recorded for a skill in the store (its last commit),
    /// copied into a scratch folder so it can be compared with the files now.
    func recordedCopy(of name: String) -> URL? {
        guard exists else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tackroom-recorded-\(name)-\(UUID().uuidString.prefix(6))")
        do { try git.export(tree: "HEAD:skills/\(name)", to: out); return out } catch { return nil }
    }
}

/// Changes Tackroom noticed but did not make (source unknown). Kept beside the
/// store, outside its history.
public struct ExternalLog: Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var name: String
        public var date: Date
    }

    public var url: URL

    public init(store: Store = Store()) { url = store.stateDir.appendingPathComponent("external.json") }

    public func load() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    /// Records names that just started to differ; returns the full log.
    @discardableResult
    public func record(newlyDrifted names: [String]) -> [Entry] {
        var entries = load()
        guard !names.isEmpty else { return entries }
        entries += names.map { Entry(name: $0, date: Date()) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(entries.suffix(500)).write(to: url, options: .atomic)
        return entries
    }
}
