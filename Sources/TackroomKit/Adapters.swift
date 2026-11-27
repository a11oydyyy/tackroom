import Foundation

/// Where a skill folder lives: shared by every project, or inside one project.
public enum RootScope: String, Codable, Sendable {
    case global
    case project
}

/// What Tackroom may do with a root. `builtin` folders belong to the agent itself.
public enum RootRole: String, Codable, Sendable {
    case user      // normal skill folder
    case legacy    // old location the agent still reads
    case builtin   // shipped by the agent; display only
}

/// One folder an agent scans for skills.
public struct SkillRoot: Codable, Sendable, Hashable {
    /// `~/…` for global roots, relative to the project root for project roots.
    public var path: String
    public var scope: RootScope
    /// Lower rank wins when the agent keeps only one copy of a name.
    public var rank: Int
    public var role: RootRole
    /// Codex looks for project skills in every folder from the project up to the git root.
    public var walkUpToGitRoot: Bool

    public init(_ path: String, _ scope: RootScope, rank: Int, role: RootRole = .user, walkUpToGitRoot: Bool = false) {
        self.path = path
        self.scope = scope
        self.rank = rank
        self.role = role
        self.walkUpToGitRoot = walkUpToGitRoot
    }
}

/// How an agent handles two skills with the same name.
public enum SameNameRule: String, Codable, Sendable {
    /// Keeps only the copy from the lowest-rank root (Claude Code, Antigravity, DSH).
    case lowestRankWins
    /// Shows every copy to the model (Codex).
    case listsAll
}

/// How an agent finds its project root.
public enum ProjectRootRule: String, Codable, Sendable {
    /// The registered folder itself.
    case folder
    /// The nearest folder above that holds `.git`, else the registered folder (DSH).
    case nearestGitRoot
}

/// Everything Tackroom knows about one agent. Defaults below come from the
/// M0 tests (2026-11-23); `adapters.toml` can override them.
public struct HarnessAdapter: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Short label for badges ("DSH").
    public var shortName: String
    public var roots: [SkillRoot]
    public var sameName: SameNameRule
    public var projectRoot: ProjectRootRule
    /// DSH also accepts `<name>.md` files directly in a root.
    public var acceptsFlatMarkdown: Bool
    /// DSH hides a skill whose frontmatter turns off both model and user use.
    public var hidesFullyDisabledSkills: Bool
    /// Installed app used for the icon; nil for command-line only agents.
    public var appPath: String?
    public var accentHex: String
    /// Where Tackroom puts links to turn a skill on. nil = read-only for now.
    public var writeDir: String?
    /// Folder inside a project where Tackroom puts copies. nil = not supported.
    public var projectWriteDir: String?
    /// MCP settings this agent reads (read only; Tackroom never writes them).
    public var mcpFiles: [String] = []
    /// MCP settings inside a project, relative to the project folder.
    public var mcpProjectFiles: [String] = []
    /// MCP settings that come with plugins (shown, not managed). `*` = one folder level.
    public var mcpPluginFiles: [String] = []
    /// Signs that the agent is on this Mac: paths, or `cmd:<name>` for a
    /// command-line tool in the usual install folders. Agents that only read
    /// folders other agents share need these; empty = always shown.
    public var markers: [String] = []

    /// Whether Tackroom should list this agent at all.
    public var isPresent: Bool {
        markers.isEmpty || markers.contains { marker in
            if marker.hasPrefix("cmd:") {
                let name = String(marker.dropFirst(4))
                return ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.bun/bin", "~/.npm-global/bin", "~/.volta/bin"]
                    .contains { FileManager.default.isExecutableFile(atPath: Paths.expand($0 + "/" + name)) }
            }
            return FileManager.default.fileExists(atPath: Paths.expand(marker))
        }
    }

    public init(id: String, name: String, shortName: String? = nil, roots: [SkillRoot], sameName: SameNameRule,
                projectRoot: ProjectRootRule = .folder, acceptsFlatMarkdown: Bool = false,
                hidesFullyDisabledSkills: Bool = false, appPath: String? = nil, accentHex: String,
                writeDir: String? = nil, projectWriteDir: String? = nil) {
        self.writeDir = writeDir
        self.projectWriteDir = projectWriteDir
        self.id = id
        self.name = name
        self.shortName = shortName ?? name
        self.roots = roots
        self.sameName = sameName
        self.projectRoot = projectRoot
        self.acceptsFlatMarkdown = acceptsFlatMarkdown
        self.hidesFullyDisabledSkills = hidesFullyDisabledSkills
        self.appPath = appPath
        self.accentHex = accentHex
    }

    func present(if markers: String...) -> HarnessAdapter {
        var a = self
        a.markers = markers
        return a
    }

    func mcp(files: [String], project: [String], plugins: [String]) -> HarnessAdapter {
        var a = self
        a.mcpFiles = files
        a.mcpProjectFiles = project
        a.mcpPluginFiles = plugins
        return a
    }

    public var globalRoots: [SkillRoot] { roots.filter { $0.scope == .global } }
    public var projectRoots: [SkillRoot] { roots.filter { $0.scope == .project } }
}

public enum DefaultAdapters {
    public static let claudeCode = HarnessAdapter(
        id: "claude-code", name: "Claude Code", shortName: "Claude",
        roots: [
            // Personal skills beat project skills (M0).
            SkillRoot("~/.claude/skills", .global, rank: 10),
            SkillRoot(".claude/skills", .project, rank: 20),
        ],
        sameName: .lowestRankWins,
        appPath: "/Applications/Claude.app", accentHex: "#D97757",
        writeDir: "~/.claude/skills", projectWriteDir: ".claude/skills")
        .mcp(files: ["~/.claude.json"], project: [".mcp.json"], plugins: [])

    public static let codex = HarnessAdapter(
        id: "codex", name: "Codex",
        roots: [
            SkillRoot(".agents/skills", .project, rank: 10, walkUpToGitRoot: true),
            SkillRoot("~/.agents/skills", .global, rank: 20),
            SkillRoot("~/.codex/skills", .global, rank: 30, role: .legacy),
            SkillRoot("~/.codex/skills/.system", .global, rank: 40, role: .builtin),
        ],
        sameName: .listsAll,
        appPath: nil, accentHex: "#6E6E73",
        // Codex-only folder: DSH does not read it, so turning a skill on for
        // Codex never turns it on for DSH as well.
        writeDir: "~/.codex/skills",
        // In projects Codex only reads .agents/skills, which Antigravity also reads.
        projectWriteDir: ".agents/skills")
        .mcp(files: ["~/.codex/config.toml"], project: [".codex/config.toml"], plugins: ["~/.codex/plugins/cache"])

    public static let antigravity = HarnessAdapter(
        id: "antigravity", name: "Antigravity",
        roots: [
            SkillRoot(".agents/skills", .project, rank: 10),
            SkillRoot(".agent/skills", .project, rank: 11),
            SkillRoot("~/.gemini/config/skills", .global, rank: 20),
            SkillRoot("~/.gemini/antigravity/skills", .global, rank: 21, role: .legacy),
            // Skills that come with Antigravity plugins: shown, not managed.
            SkillRoot("~/.gemini/config/plugins/*/skills", .global, rank: 30, role: .builtin),
        ],
        sameName: .lowestRankWins,
        appPath: "/Applications/Antigravity.app", accentHex: "#3B82F6",
        // Tested 2026-11-27 (agy 1.5.18, app 2.35.2): a link in its global
        // folder to a skill elsewhere loads, edits show up, the link stays.
        // In projects it shares .agents/skills with Codex.
        writeDir: "~/.gemini/config/skills", projectWriteDir: ".agents/skills")
        .mcp(files: ["~/.gemini/config/mcp_config.json"], project: [".agents/mcp_config.json"],
             plugins: ["~/.gemini/config/plugins/*/mcp_config.json"])

    public static let deepseek = HarnessAdapter(
        id: "deepseek", name: "DeepSeek Harness", shortName: "DSH",
        roots: [
            SkillRoot(".dsh/skills", .project, rank: 100),
            SkillRoot(".agents/skills", .project, rank: 200),
            SkillRoot("~/.dsh/skills", .global, rank: 400),
            SkillRoot("~/.agents/skills", .global, rank: 500),
        ],
        sameName: .lowestRankWins, projectRoot: .nearestGitRoot,
        acceptsFlatMarkdown: true, hidesFullyDisabledSkills: true,
        appPath: "/Applications/DeepSeek Harness.app", accentHex: "#4D6BFE",
        // DSH follows links and never rewrites them (verified 2026-11-26).
        // Its own folder beats ~/.agents/skills, which Codex also reads.
        writeDir: "~/.dsh/skills", projectWriteDir: ".dsh/skills")
        .mcp(files: ["~/.dsh/cordis.patch.yml", "~/.dsh/profiles/desktop/cordis.patch.yml", "~/.dsh/profiles/web/cordis.patch.yml"],
             project: [], plugins: [])

    // Agents below are listed only when they are on this Mac (see `markers`).

    /// Folders, order and link handling read from Cursor 3.27's own skill
    /// loader (cursor-agent-exec): it follows links anywhere, walks folders
    /// recursively, and keeps the first of one name in the order
    /// .cursor, .claude, .codex, .agents. It has no command line to list them.
    public static let cursor = HarnessAdapter(
        id: "cursor", name: "Cursor",
        roots: [
            SkillRoot(".cursor/skills", .project, rank: 10),
            SkillRoot(".claude/skills", .project, rank: 11),
            SkillRoot(".codex/skills", .project, rank: 12),
            SkillRoot(".agents/skills", .project, rank: 13),
            SkillRoot("~/.cursor/skills", .global, rank: 20),
            SkillRoot("~/.claude/skills", .global, rank: 21),
            SkillRoot("~/.codex/skills", .global, rank: 22),
            SkillRoot("~/.agents/skills", .global, rank: 23),
            // Cursor rewrites this folder itself: shown, never written.
            SkillRoot("~/.cursor/skills-cursor", .global, rank: 40, role: .builtin),
        ],
        sameName: .lowestRankWins,
        appPath: "/Applications/Cursor.app", accentHex: "#3C3C3C",
        writeDir: "~/.cursor/skills", projectWriteDir: ".cursor/skills")
        .present(if: "/Applications/Cursor.app", "cmd:cursor-agent")

    /// Tested 2026-11-27 with `opencode debug skill` (1.19): follows links; its
    /// own folder wins over ~/.agents/skills and ~/.claude/skills.
    public static let opencode = HarnessAdapter(
        id: "opencode", name: "OpenCode", shortName: "OpenCode",
        roots: [
            SkillRoot(".opencode/skills", .project, rank: 10, walkUpToGitRoot: true),
            SkillRoot(".agents/skills", .project, rank: 11, walkUpToGitRoot: true),
            SkillRoot(".claude/skills", .project, rank: 12, walkUpToGitRoot: true),
            SkillRoot("~/.config/opencode/skills", .global, rank: 20),
            SkillRoot("~/.agents/skills", .global, rank: 21),
            SkillRoot("~/.claude/skills", .global, rank: 22),
        ],
        sameName: .lowestRankWins,
        appPath: "/Applications/OpenCode.app", accentHex: "#C8781E",
        writeDir: "~/.config/opencode/skills", projectWriteDir: ".opencode/skills")
        .present(if: "/Applications/OpenCode.app", "cmd:opencode", "~/.config/opencode")

    /// Tested 2026-11-27 with `gemini skills list` (0.44): follows links;
    /// ~/.agents/skills wins over ~/.gemini/skills, a project over both.
    public static let geminiCLI = HarnessAdapter(
        id: "gemini-cli", name: "Gemini CLI", shortName: "Gemini",
        roots: [
            SkillRoot(".agents/skills", .project, rank: 10),
            SkillRoot(".gemini/skills", .project, rank: 11),
            SkillRoot("~/.agents/skills", .global, rank: 20),
            SkillRoot("~/.gemini/skills", .global, rank: 21),
        ],
        sameName: .lowestRankWins,
        accentHex: "#7B5CE0",
        writeDir: "~/.gemini/skills", projectWriteDir: ".gemini/skills")
        .present(if: "cmd:gemini")

    /// Read-only, from GitHub's documentation (not installed here).
    public static let copilot = HarnessAdapter(
        id: "copilot", name: "GitHub Copilot", shortName: "Copilot",
        roots: [
            SkillRoot(".github/skills", .project, rank: 10),
            SkillRoot(".agents/skills", .project, rank: 11),
            SkillRoot(".claude/skills", .project, rank: 12),
            SkillRoot("~/.copilot/skills", .global, rank: 20),
            SkillRoot("~/.agents/skills", .global, rank: 21),
        ],
        sameName: .lowestRankWins,
        accentHex: "#8250DF")
        .present(if: "~/.copilot", "cmd:copilot")

    /// Read-only, from Devin's documentation for Devin CLI (not installed here).
    public static let devin = HarnessAdapter(
        id: "devin", name: "Devin", shortName: "Devin",
        roots: [
            SkillRoot(".agents/skills", .project, rank: 10),
            SkillRoot(".devin/skills", .project, rank: 11),
            SkillRoot(".windsurf/skills", .project, rank: 12),
            SkillRoot("~/.agents/skills", .global, rank: 20),
            SkillRoot("~/.config/devin/skills", .global, rank: 21),
        ],
        sameName: .lowestRankWins,
        accentHex: "#0F766E")
        .present(if: "~/.config/devin", "cmd:devin")

    public static let all: [HarnessAdapter] = [claudeCode, codex, antigravity, deepseek, cursor, opencode, geminiCLI, copilot, devin]
}
