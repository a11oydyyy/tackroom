import Foundation
import CryptoKit

/// One skill folder (or flat `.md` file) found in one root.
public struct SkillCopy: Sendable, Hashable, Identifiable {
    public var id: String { entryPath }
    /// The skill's name: `name:` from the frontmatter, else the folder name.
    public var name: String
    /// The folder (or file) name, when it differs from `name`.
    public var folderName: String?
    public var description: String
    /// Where the entry sits inside the root (may be a symlink).
    public var entryPath: String
    /// Where the files really are.
    public var resolvedPath: String?
    /// The instruction file (`SKILL.md`, or the flat `.md`).
    public var skillFile: String?
    public var isSymlink: Bool
    public var linkTarget: String?
    public var isBrokenLink: Bool
    public var isFlatFile: Bool
    public var contentHash: String?
    public var fileCount: Int
    /// The skill ships files that can run (scripts or executables).
    public var hasScripts: Bool = false
    public var modelInvocable: Bool
    public var userInvocable: Bool
    /// Codex: `agents/openai.yaml` sets `allow_implicit_invocation: false`.
    public var codexImplicitOff: Bool = false
    /// Why an agent may refuse to load this copy (missing SKILL.md, no frontmatter…).
    public var problem: String?
}

/// The result of reading one root folder.
public struct RootScan: Sendable, Hashable {
    public var path: String
    public var realPath: String?
    public var exists: Bool
    /// Set when the folder exists but could not be read.
    public var error: String?
    public var copies: [SkillCopy]
}

/// Skill names become folder names, so a name read from a SKILL.md (which
/// anyone can write) must never reach outside the folder it is put in.
public enum SkillName {
    /// A single plain folder name: no `/`, no leading `.`, no control
    /// characters, at most 128 characters.
    public static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, !name.hasPrefix("."), !name.hasPrefix("-") else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0 == ":" || $0.properties.generalCategory == .control }
    }

    /// The folder name to use: the name itself when safe, else a fixed
    /// stand-in, so even a tampered record can't point outside.
    public static func folder(_ name: String) -> String {
        if isSafe(name) { return name }
        let hex = SHA256.hash(data: Data(name.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "invalid-name-" + hex
    }

    public static let problem = L("名稱含有不允許的字元（例如 / 或開頭的 .），為了安全不能安裝或納入管理。")
}

public enum Scanner {
    /// Files and folders that tools create inside skills and that are not
    /// part of the skill itself.
    public static let ignoredNames: Set<String> = [".DS_Store", ".git", "node_modules", ".venv", "venv", "__pycache__", ".cache"]

    /// Leftovers that come and go on their own: the names above, Finder's
    /// `._` copies on other disks, and editors' swap files while a file is
    /// open. Counting them would report a change nobody made.
    public static func isIgnored(_ name: String) -> Bool {
        ignoredNames.contains(name) || name.hasPrefix("._") || name.hasSuffix(".swp") || name.hasSuffix(".swo")
            || name == "Icon\r"
    }

    /// The same rules as `isIgnored`, written for git.
    static let gitExcludePatterns = [".DS_Store", ".git", "node_modules/", ".venv/", "venv/", "__pycache__/", ".cache/",
                                     "._*", "*.swp", "*.swo"]
    static let maxHashedFileSize = 20 * 1024 * 1024

    public static func scanRoot(_ path: String, acceptFlatMarkdown: Bool) -> RootScan {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return RootScan(path: path, realPath: nil, exists: false, error: nil, copies: [])
        }
        guard isDir.boolValue else {
            return RootScan(path: path, realPath: Paths.realpath(path), exists: true, error: L("不是資料夾"), copies: [])
        }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: path)
        } catch {
            return RootScan(path: path, realPath: Paths.realpath(path), exists: true,
                            error: L("無法讀取：\((error as NSError).localizedDescription)"), copies: [])
        }
        var copies: [SkillCopy] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let entry = (path as NSString).appendingPathComponent(name)
            if let copy = readEntry(entry, name: name, acceptFlatMarkdown: acceptFlatMarkdown) {
                copies.append(copy)
            }
        }
        return RootScan(path: path, realPath: Paths.realpath(path), exists: true, error: nil, copies: copies)
    }

    public static func readEntry(_ entry: String, name: String, acceptFlatMarkdown: Bool) -> SkillCopy? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: entry)
        let isSymlink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
        let linkTarget = isSymlink ? try? fm.destinationOfSymbolicLink(atPath: entry) : nil
        let resolved = Paths.realpath(entry)

        if isSymlink && resolved == nil {
            return SkillCopy(name: name, folderName: nil, description: "", entryPath: entry, resolvedPath: nil,
                             skillFile: nil, isSymlink: true, linkTarget: linkTarget, isBrokenLink: true,
                             isFlatFile: false, contentHash: nil, fileCount: 0, modelInvocable: false,
                             userInvocable: false, problem: L("連結指向的位置不存在"))
        }
        guard let resolved else { return nil }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: resolved, isDirectory: &isDir)

        if isDir.boolValue {
            let skillFile = (resolved as NSString).appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile) else {
                // Not a skill: folders without SKILL.md are ignored by every agent.
                return nil
            }
            var copy = parse(skillFile: skillFile, name: name, entry: entry, resolved: resolved,
                             isSymlink: isSymlink, linkTarget: linkTarget, flat: false)
            let (hash, count, scripts) = hashFolder(resolved)
            copy.contentHash = hash
            copy.fileCount = count
            copy.hasScripts = scripts
            copy.codexImplicitOff = readsImplicitOff((resolved as NSString).appendingPathComponent("agents/openai.yaml"))
            return copy
        }
        if acceptFlatMarkdown, name.hasSuffix(".md") {
            let base = String(name.dropLast(3))
            var copy = parse(skillFile: resolved, name: base, entry: entry, resolved: resolved,
                             isSymlink: isSymlink, linkTarget: linkTarget, flat: true)
            copy.contentHash = hashFile(resolved)
            copy.fileCount = 1
            return copy
        }
        return nil
    }

    static func parse(skillFile: String, name: String, entry: String, resolved: String,
                      isSymlink: Bool, linkTarget: String?, flat: Bool) -> SkillCopy {
        var copy = SkillCopy(name: name, folderName: nil, description: "", entryPath: entry, resolvedPath: resolved,
                             skillFile: skillFile, isSymlink: isSymlink, linkTarget: linkTarget, isBrokenLink: false,
                             isFlatFile: flat, contentHash: nil, fileCount: 0, modelInvocable: true,
                             userInvocable: true, problem: nil)
        guard let text = try? String(contentsOfFile: skillFile, encoding: .utf8) else {
            copy.problem = L("SKILL.md 讀不到或不是文字檔")
            return copy
        }
        guard let fm = Frontmatter.parse(text) else {
            copy.problem = L("SKILL.md 開頭缺少 frontmatter（name、description）")
            return copy
        }
        if let declared = fm.name, !declared.isEmpty, declared != name { copy.folderName = name; copy.name = declared }
        copy.description = fm.description ?? ""
        if fm.description == nil || fm.description?.isEmpty == true { copy.problem = L("缺少 description") }
        if fm.bool("disable-model-invocation") == true { copy.modelInvocable = false }
        if fm.bool("user-invocable") == false { copy.userInvocable = false }
        return copy
    }

    static func readsImplicitOff(_ yamlPath: String) -> Bool {
        guard let text = try? String(contentsOfFile: yamlPath, encoding: .utf8) else { return false }
        return text.components(separatedBy: "\n").contains {
            let t = $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            return t.hasPrefix("allow_implicit_invocation:false")
        }
    }

    /// Hash of every file's relative path and bytes, so any edit changes it.
    public static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "py", "js", "mjs", "cjs", "ts", "rb", "pl", "swift", "go", "applescript", "command"]

    public static func hashFolder(_ root: String) -> (String, Int, Bool) {
        let fm = FileManager.default
        // Resolve first so file paths and the root agree (e.g. /var vs /private/var).
        let rootURL = URL(fileURLWithPath: Paths.realpath(root) ?? root)
        var files: [(String, URL)] = []
        if let walker = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                      options: [], errorHandler: { _, _ in true }) {
            for case let url as URL in walker {
                if isIgnored(url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true || values?.isSymbolicLink == true {
                    let rel = String(url.path.dropFirst(rootURL.path.count + 1))
                    files.append((rel, url))
                }
            }
        }
        files.sort { $0.0 < $1.0 }
        let scripts = files.contains { rel, url in
            scriptExtensions.contains(url.pathExtension.lowercased()) || fm.isExecutableFile(atPath: url.path)
        }
        var hasher = SHA256()
        for (rel, url) in files {
            hasher.update(data: Data(rel.utf8))
            hasher.update(data: Data([0]))
            if let link = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                hasher.update(data: Data(("link:" + link).utf8))
            } else if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxHashedFileSize {
                hasher.update(data: Data("size:\(size)".utf8))
            } else if let data = try? Data(contentsOf: url) {
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }
        return ("sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined(), files.count, scripts)
    }

    /// 恢復會移走整個目錄，連平常掃描略過的檔案、空目錄與權限都必須核對。
    static func removalFingerprint(at path: String) throws -> String? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path)
        var digest = SHA256()
        func field(_ value: String) {
            digest.update(data: Data(value.utf8))
            digest.update(data: Data([0]))
        }
        func visit(_ url: URL, relative: String, attributes: [FileAttributeKey: Any]) throws {
            let type = attributes[.type] as? FileAttributeType
            field(relative)
            field(String((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0))
            field(type?.rawValue ?? "")
            switch type {
            case .typeDirectory:
                for name in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    let child = url.appendingPathComponent(name)
                    try visit(child, relative: relative + "/" + name, attributes: fm.attributesOfItem(atPath: child.path))
                }
            case .typeSymbolicLink:
                field(try fm.destinationOfSymbolicLink(atPath: url.path))
            case .typeRegular:
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                var bytes = SHA256()
                while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    bytes.update(data: chunk)
                }
                digest.update(data: Data(bytes.finalize()))
            default:
                throw TackroomError.invalid(L("無法核對檔案：\(url.path)"))
            }
        }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        try visit(root, relative: "", attributes: attributes)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hashFile(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
