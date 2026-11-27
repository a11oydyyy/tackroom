import Foundation
import Testing
@testable import TackroomKit

/// Fake secrets planted in every format; none may come out of the reader.
let fakeSecrets = [
    "ghp_FAKEfakeFAKEfakeFAKEfake1234567890",
    "sk-FAKEFAKEFAKEFAKEFAKE1234",
    "supersecretpassword-123",
    "xoxb-FAKE-1234567890-abcdef",
    "Bearer FAKEtokenFAKEtokenFAKE1234",
    "AIzaFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE12",
]

struct MCPBox {
    let box: Sandbox
    let adapters: [HarnessAdapter]

    init() throws {
        let b = try Sandbox()
        box = b
        adapters = DefaultAdapters.all.map { a in
            var a = b.adapt(a)
            let fix: (String) -> String = { $0.hasPrefix("~/") ? b.path(String($0.dropFirst(2))) : $0 }
            a.mcpFiles = a.mcpFiles.map(fix)
            a.mcpPluginFiles = a.mcpPluginFiles.map(fix)
            return a
        }
        try write(".claude.json", """
        {"mcpServers": {
          "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_TOKEN": "\(fakeSecrets[0])"}},
          "docs": {"type": "http", "url": "https://docs.example.com/mcp?api_key=\(fakeSecrets[2])"}
        },
         "projects": {"\(box.path("repo"))": {"mcpServers": {"local-db": {"command": "db-mcp", "args": ["--password", "\(fakeSecrets[2])"]}},
                                              "disabledMcpServers": ["local-db"]}}}
        """)
        try write(".codex/config.toml", """
        model = "x"
        [mcp_servers.github]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-github@1.2.0"]
        env = { GITHUB_TOKEN = "\(fakeSecrets[0])" }

        [mcp_servers.openai]
        url = "https://api.example.com/mcp"
        bearer_token_env_var = "OPENAI_KEY"

        [mcp_servers.slack]
        command = "slack-mcp"
        enabled = false
        [mcp_servers.slack.env]
        SLACK_BOT_TOKEN = "\(fakeSecrets[3])"
        SLACK_TEAM = "T123"

        [plugins."tools@market"]
        enabled = true
        """)
        try write(".codex/plugins/cache/market/tools/1.0.0/.mcp.json", #"{"mcpServers": {"old": {"command": "x"}}}"#)
        try write(".codex/plugins/cache/market/tools/1.10.0/.mcp.json", #"{"mcpServers": {"tools-server": {"command": "y", "enabled": false}}}"#)
        try write(".gemini/config/mcp_config.json", """
        {"mcpServers": {"search": {"serverUrl": "https://search.example.com/mcp", "headers": {"Authorization": "\(fakeSecrets[4])"}},
                        "maps": {"command": "uvx", "args": ["maps-mcp"], "env": {"MAPS_API_KEY": "\(fakeSecrets[5])"}, "disabled": true}}}
        """)
        try write(".gemini/config/plugins/notion/mcp_config.json", #"{"mcpServers": {"notion": {"serverUrl": "https://mcp.notion.com/mcp"}}}"#)
        try write(".dsh/profiles/desktop/cordis.patch.yml", """
        # user patch
        - id: agent-default-model
          config:
            model: x
        - insert:
            - id: memory-my-server
              name: '@deepseek-ai/dsh-mcp-client'
              config:
                serverName: memory
                transport: stdio
                command: npx
                args: ['-y', 'memory-mcp@latest']
                env:
                  MEMORY_TOKEN: '\(fakeSecrets[1])'
                  SAFE_TOKEN: '${credential:MEMORY}'
                cwd: !!js process.cwd()
        - id: mcp
          name: '@deepseek-ai/dsh-mcp-manager'
          config:
            servers:
              github:
                transport: stdio
                command: npx
                args: ['-y', '@modelcontextprotocol/server-github']
                env:
                  GITHUB_TOKEN: '${credential:GITHUB_TOKEN}'
        """)
    }

    func write(_ rel: String, _ text: String) throws {
        let url = box.root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

@Suite struct MCPTests {
    @Test func readsEveryAgentAndNeverKeepsSecretValues() throws {
        let t = try MCPBox()
        let project = Project(name: "repo", path: t.box.path("repo"))
        let servers = MCPInventory.scan(adapters: t.adapters, project: project)
        let dump = String(describing: servers) + String(describing: MCPInventory.groups(servers))
        for secret in fakeSecrets {
            #expect(!dump.contains(secret), "secret leaked")
            #expect(!dump.contains(String(secret.suffix(12))), "part of a secret leaked")
        }

        func find(_ agent: String, _ name: String) -> MCPServer? { servers.first { $0.harnessID == agent && $0.name == name } }

        // Claude Code
        #expect(find("claude-code", "github")?.plaintextSecrets == ["env GITHUB_TOKEN"])
        #expect(find("claude-code", "github")?.floatingPackage == "@modelcontextprotocol/server-github")
        #expect(find("claude-code", "docs")?.address == "docs.example.com/mcp")
        #expect(find("claude-code", "docs")?.plaintextSecrets == ["網址參數 api_key"])
        let local = try #require(find("claude-code", "local-db"))
        #expect(local.enabled == false && local.scope == .project)
        #expect(local.args == ["--password", "•••"])

        // Codex: pinned version, variable token, subtable env, newest plugin version
        #expect(find("codex", "github")?.floatingPackage == nil)
        #expect(find("codex", "openai")?.plaintextSecrets.isEmpty == true)
        #expect(find("codex", "openai")?.variables == ["OPENAI_KEY"])
        #expect(find("codex", "slack")?.enabled == false)
        #expect(find("codex", "slack")?.plaintextSecrets == ["env SLACK_BOT_TOKEN"])
        #expect(find("codex", "tools-server")?.plugin == "tools")
        #expect(find("codex", "old") == nil)

        // Antigravity: header secret, disabled, plugin
        #expect(find("antigravity", "search")?.plaintextSecrets == ["header Authorization"])
        #expect(find("antigravity", "maps")?.enabled == false)
        #expect(find("antigravity", "maps")?.floatingPackage == "maps-mcp")
        #expect(find("antigravity", "notion")?.plugin == "notion")

        // DSH: inserted client and manager servers; credential refs are not secrets
        let memory = try #require(find("deepseek", "memory"))
        #expect(memory.plaintextSecrets == ["env MEMORY_TOKEN"])
        #expect(memory.variables.contains("SAFE_TOKEN"))
        #expect(memory.floatingPackage == "memory-mcp@latest")
        #expect(find("deepseek", "github")?.plaintextSecrets.isEmpty == true)

        // github appears in three agents.
        let github = try #require(MCPInventory.groups(servers).first { $0.name == "github" })
        #expect(Set(github.harnessIDs) == ["claude-code", "codex", "deepseek"])
        #expect(github.hasPlaintextSecret)
    }

    @Test func secretRules() {
        #expect(Secrets.isPlaintextSecret(name: "API_KEY", value: "abcd1234efgh5678"))
        #expect(!Secrets.isPlaintextSecret(name: "API_KEY", value: "${API_KEY}"))
        #expect(!Secrets.isPlaintextSecret(name: "TOKEN_FILE", value: "/Users/x/token.txt"))
        #expect(!Secrets.isPlaintextSecret(name: "DEBUG", value: "true"))
        #expect(Secrets.isPlaintextSecret(name: "X", value: "ghp_abcdefghijklmnopqrstuvwxyz123456"))
        #expect(Secrets.floatingPackage(program: "npx", args: ["-y", "pkg@1.0.0"]) == nil)
        #expect(Secrets.floatingPackage(program: "/usr/local/bin/node", args: ["server.js"]) == nil)
        #expect(Secrets.cleanArgs(["--api-key=abc123456789", "run"]).0 == ["--api-key=•••", "run"])
    }

    @Test func yamlShapes() {
        let y = MiniYAML.parse("""
        - id: a
          config:
            list: [1, 'two']
            map: { k: v }
            nested:
              - x: 1
                y: 2
        """)
        let first = y?.seq?.first
        #expect(first?["id"]?.string == "a")
        #expect(first?["config"]?["list"]?.seq?.count == 2)
        #expect(first?["config"]?["map"]?["k"]?.string == "v")
        #expect(first?["config"]?["nested"]?.seq?.first?["y"]?.string == "2")
    }
}
