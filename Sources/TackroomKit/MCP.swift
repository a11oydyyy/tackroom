import Foundation

// MCP overview (M6, read only). Tackroom never writes these files, and no
// secret value ever leaves this file: readers look at values only to decide
// whether they are plain-text secrets, then keep the *place* (e.g. "env
// GITHUB_TOKEN"), never the value.

public enum MCPTransport: String, Sendable, Hashable {
    case stdio, http, sse
}

public struct MCPServer: Sendable, Hashable, Identifiable {
    public var id: String { harnessID + "|" + file + "|" + name }
    public var name: String
    public var harnessID: String
    public var scope: RootScope
    public var projectID: UUID?
    /// The plugin it comes with; such servers are shown, not managed.
    public var plugin: String?
    /// The settings file it was read from.
    public var file: String
    public var transport: MCPTransport
    /// The program that starts it (`npx`, a path…), stdio only.
    public var program: String?
    /// Arguments with anything secret-looking replaced by •••.
    public var args: [String]
    /// Address without credentials or query (`mcp.example.com/mcp`).
    public var address: String?
    public var enabled: Bool
    /// Where a secret is written in plain text, e.g. "env GITHUB_TOKEN". Never the value.
    public var plaintextSecrets: [String]
    /// Variable names it reads its settings from (safe to show).
    public var variables: [String]
    /// The package it downloads anew on every start (no version pinned).
    public var floatingPackage: String?

    /// Same server under different names or agents: the address or the launch line.
    public var identity: String {
        if let address { return address.lowercased() }
        return ([program ?? ""] + args).joined(separator: " ")
    }
}

// MARK: - Secret rules

enum Secrets {
    static let secretKey = try! NSRegularExpression(
        pattern: #"(key|token|secret|passw|pwd|auth|bearer|credential|cookie|session|private|signature)"#, options: [.caseInsensitive])
    static let knownToken = try! NSRegularExpression(
        pattern: #"(sk-[A-Za-z0-9_\-]{16,}|sk_(live|test)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AIza[0-9A-Za-z_\-]{30,}|ya29\.[0-9A-Za-z_\-]{20,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.|AKIA[0-9A-Z]{16}|ntn_[A-Za-z0-9]{20,}|secret_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_\-]{16,}|Bearer\s+[A-Za-z0-9._\-]{16,})"#)
    static let secretFlags: Set<String> = ["--token", "--api-key", "--apikey", "--key", "--secret", "--password", "--access-token",
                                           "--auth", "--auth-token", "--bearer", "--client-secret", "-t", "-k"]

    static func isSecretKey(_ name: String) -> Bool {
        secretKey.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func looksLikeToken(_ value: String) -> Bool {
        knownToken.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// A value that only points somewhere else (`${VAR}`, `!!js process.env.X`, `${credential:REF}`).
    static func isReference(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return true }
        if v.contains("${") || v.contains("$(") || v.contains("process.env") || v.hasPrefix("!!js") || v.hasPrefix("env:") || v.hasPrefix("op://") {
            return true
        }
        if v.hasPrefix("$"), v.dropFirst().allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) { return true }
        return false
    }

    /// Plain-text secret in a name/value pair (env or header).
    static func isPlaintextSecret(name: String, value: String) -> Bool {
        if isReference(value) { return false }
        if looksLikeToken(value) { return true }
        // A secret-sounding name with a real-looking value (not a flag, path or small word).
        guard isSecretKey(name) else { return false }
        let v = value.trimmingCharacters(in: .whitespaces)
        if ["true", "false", "0", "1", "yes", "no", "none", "null"].contains(v.lowercased()) { return false }
        if v.hasPrefix("/") || v.hasPrefix("~") || v.hasPrefix("http") { return false }
        return v.count >= 8
    }

    /// Masks secret-looking arguments; returns the cleaned list and where secrets were.
    /// Splits a command line into words, honoring "…" and '…' quotes.
    static func splitCommand(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; started = true
            } else if ch.isWhitespace {
                if started || !current.isEmpty { words.append(current); current = ""; started = false }
            } else {
                current.append(ch)
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }

    static func cleanArgs(_ args: [String]) -> ([String], [String]) {
        var out: [String] = []
        var spots: [String] = []
        var maskNext: String?
        for arg in args {
            if let flag = maskNext {
                maskNext = nil
                if !isReference(arg) { out.append("•••"); spots.append(L("參數 \(flag)")); continue }
            }
            if let eq = arg.firstIndex(of: "="), arg.hasPrefix("-") {
                let flag = String(arg[..<eq]), value = String(arg[arg.index(after: eq)...])
                if (secretFlags.contains(flag.lowercased()) || isSecretKey(flag)) && !isReference(value) {
                    out.append(flag + "=•••"); spots.append(L("參數 \(flag)")); continue
                }
            }
            if secretFlags.contains(arg.lowercased()) || (arg.hasPrefix("--") && isSecretKey(arg)) {
                out.append(arg); maskNext = arg; continue
            }
            if looksLikeToken(arg) { out.append("•••"); spots.append(L("參數")); continue }
            out.append(arg)
        }
        return (out, spots)
    }

    /// Host and path only; reports secret-looking query parameters or user info.
    static func cleanURL(_ raw: String) -> (String, [String]) {
        guard !isReference(raw) || raw.hasPrefix("http"), let comps = URLComponents(string: raw), let host = comps.host else {
            return (raw.hasPrefix("$") ? raw : L("（網址）"), [])
        }
        var spots: [String] = []
        if comps.password != nil || comps.user != nil { spots.append(L("網址裡的帳號密碼")) }
        for item in comps.queryItems ?? [] where isPlaintextSecret(name: item.name, value: item.value ?? "") {
            spots.append(L("網址參數 \(item.name)"))
        }
        let port = comps.port.map { ":\($0)" } ?? ""
        let path = comps.path == "/" ? "" : comps.path
        return (host + port + path, spots)
    }

    /// `npx -y pkg` (no version) or `pkg@latest`: downloads anew on each start.
    static func floatingPackage(program: String?, args: [String]) -> String? {
        guard let program else { return nil }
        let base = (program as NSString).lastPathComponent
        let runners = ["npx", "bunx", "uvx", "pnpx"]
        var rest = args[...]
        if base == "pnpm" || base == "yarn" || base == "bun" {
            guard let first = rest.first, ["dlx", "x"].contains(first) else { return nil }
            rest = rest.dropFirst()
        } else if base == "pipx" {
            guard rest.first == "run" else { return nil }
            rest = rest.dropFirst()
        } else if !runners.contains(base) {
            return nil
        }
        var skipNext = false
        for arg in rest {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-") {
                if ["--package", "-p", "--from"].contains(arg) { skipNext = true }
                continue
            }
            let pkg = arg
            if base == "uvx" || base == "pipx" {
                return pkg.contains("==") ? nil : pkg
            }
            // npm style: @scope/name@1.2.3 or name@1.2.3
            let body = pkg.hasPrefix("@") ? String(pkg.dropFirst()) : pkg
            guard let at = body.firstIndex(of: "@") else { return pkg }
            let version = body[body.index(after: at)...]
            return (version == "latest" || version == "next" || version.isEmpty) ? pkg : nil
        }
        return nil
    }
}

// MARK: - Reading

/// One server entry in a generic shape, before cleaning.
struct RawServer {
    var name: String
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var envNames: [String] = []
    var url: String?
    var headers: [String: String] = [:]
    var headerVariables: [String] = []
    var type: String?
    var enabled = true
}

public enum MCPInventory {
    /// Every MCP server each agent is set up with, global plus one project.
    public static func scan(adapters: [HarnessAdapter] = AdapterConfig.load(), project: Project? = nil) -> [MCPServer] {
        var out: [MCPServer] = []
        for adapter in adapters {
            for file in adapter.mcpFiles.map(Paths.expand) {
                out += read(file, adapter: adapter, scope: .global, project: project, plugin: nil)
            }
            if let project {
                // Claude Code keeps per-project ("local") servers inside ~/.claude.json too.
                for file in adapter.mcpFiles.map(Paths.expand) where (file as NSString).lastPathComponent == ".claude.json" {
                    out += read(file, adapter: adapter, scope: .project, project: project, plugin: nil).map {
                        var s = $0; s.projectID = project.id; return s
                    }
                }
                for rel in adapter.mcpProjectFiles {
                    let file = (project.path as NSString).appendingPathComponent(rel)
                    out += read(file, adapter: adapter, scope: .project, project: project, plugin: nil).map {
                        var s = $0; s.projectID = project.id; return s
                    }
                }
            }
            out += plugins(adapter)
        }
        return out
    }

    static func read(_ file: String, adapter: HarnessAdapter, scope: RootScope, project: Project?, plugin: String?) -> [MCPServer] {
        guard let data = FileManager.default.contents(atPath: file), !data.isEmpty else { return [] }
        var raws: [RawServer] = []
        let ext = (file as NSString).pathExtension.lowercased()
        if ext == "toml" {
            raws = codexTOML(String(decoding: data, as: UTF8.self))
        } else if ext == "yml" || ext == "yaml" {
            raws = dshYAML(String(decoding: data, as: UTF8.self))
        } else if (file as NSString).lastPathComponent == ".claude.json" {
            raws = claudeHome(data, project: scope == .project ? project : nil)
        } else {
            raws = jsonServers(data)
        }
        return raws.map { clean($0, adapter: adapter, scope: scope, file: file, plugin: plugin) }
    }

    static func clean(_ r: RawServer, adapter: HarnessAdapter, scope: RootScope, file: String, plugin: String?) -> MCPServer {
        var secrets: [String] = []
        var variables = r.envNames + r.headerVariables
        for (k, v) in r.env {
            if Secrets.isPlaintextSecret(name: k, value: v) { secrets.append("env \(k)") }
            else if Secrets.isReference(v) && !v.isEmpty { variables.append(k) }
        }
        for (k, v) in r.headers where Secrets.isPlaintextSecret(name: k, value: v) || (k.lowercased() == "authorization" && !Secrets.isReference(v)) {
            secrets.append("header \(k)")
        }
        let (args, argSpots) = Secrets.cleanArgs(r.args)
        secrets += argSpots
        var address: String?
        if let url = r.url {
            let (a, spots) = Secrets.cleanURL(url)
            address = a
            secrets += spots
        }
        let transport: MCPTransport = r.url != nil ? ((r.type?.lowercased().contains("sse") ?? false) ? .sse : .http) : .stdio
        let program = r.command.map { cmd -> String in
            // A command line with spaces: keep the program, clean the rest as arguments.
            let words = Secrets.splitCommand(cmd)
            guard words.count > 1 else { return cmd }
            let (rest, spots) = Secrets.cleanArgs(Array(words.dropFirst()))
            secrets += spots
            return ([words[0]] + rest).joined(separator: " ")
        }
        return MCPServer(name: r.name, harnessID: adapter.id, scope: scope, projectID: nil, plugin: plugin, file: file,
                         transport: transport, program: program, args: args, address: address, enabled: r.enabled,
                         plaintextSecrets: Array(Set(secrets)).sorted(), variables: Array(Set(variables)).sorted(),
                         floatingPackage: Secrets.floatingPackage(program: r.command, args: r.args))
    }

    // MARK: JSON (Claude Code .mcp.json, Antigravity, plugin files)

    static func jsonServers(_ data: Data) -> [RawServer] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let servers = (json["mcpServers"] as? [String: Any]) ?? (json["servers"] as? [String: Any]) ?? [:]
        return servers.compactMap { name, value in
            guard let v = value as? [String: Any] else { return nil }
            return rawFromJSON(name, v)
        }.sorted { $0.name < $1.name }
    }

    static func rawFromJSON(_ name: String, _ v: [String: Any]) -> RawServer {
        var r = RawServer(name: name)
        r.command = v["command"] as? String
        r.args = (v["args"] as? [Any])?.map { "\($0)" } ?? []
        r.env = (v["env"] as? [String: Any])?.mapValues { "\($0)" } ?? [:]
        r.envNames = (v["env_vars"] as? [String]) ?? []
        r.url = (v["url"] as? String) ?? (v["serverUrl"] as? String) ?? (v["httpUrl"] as? String)
        r.headers = (v["headers"] as? [String: Any])?.mapValues { "\($0)" } ?? [:]
        if let bearer = v["bearer_token_env_var"] as? String { r.headerVariables.append(bearer) }
        r.type = (v["type"] as? String) ?? (v["transport"] as? String)
        if let disabled = v["disabled"] as? Bool { r.enabled = !disabled }
        if let enabled = v["enabled"] as? Bool { r.enabled = enabled }
        return r
    }

    /// `~/.claude.json`: user servers, or one project's local servers and switches.
    static func claudeHome(_ data: Data, project: Project?) -> [RawServer] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let project {
            let projects = json["projects"] as? [String: Any] ?? [:]
            guard let p = (projects[project.path] ?? Paths.realpath(project.path).flatMap { projects[$0] }) as? [String: Any] else { return [] }
            let disabled = Set((p["disabledMcpServers"] as? [String]) ?? [])
            return ((p["mcpServers"] as? [String: Any]) ?? [:]).compactMap { name, v in
                guard let v = v as? [String: Any] else { return nil }
                var r = rawFromJSON(name, v)
                if disabled.contains(name) { r.enabled = false }
                return r
            }.sorted { $0.name < $1.name }
        }
        return ((json["mcpServers"] as? [String: Any]) ?? [:]).compactMap { name, v in
            guard let v = v as? [String: Any] else { return nil }
            return rawFromJSON(name, v)
        }.sorted { $0.name < $1.name }
    }

    // MARK: Codex TOML

    static func codexTOML(_ text: String) -> [RawServer] {
        var byName: [String: RawServer] = [:]
        var order: [String] = []
        for table in MiniTOML.parse(text) where table.name.hasPrefix("mcp_servers.") && !table.isArrayItem {
            let rest = String(table.name.dropFirst("mcp_servers.".count))
            let parts = splitDotted(rest)
            guard let name = parts.first else { continue }
            if byName[name] == nil { byName[name] = RawServer(name: name); order.append(name) }
            var r = byName[name]!
            let v = table.values
            switch parts.dropFirst().first {
            case nil:
                r.command = v["command"]?.string ?? r.command
                r.args = v["args"]?.strings ?? r.args
                r.url = v["url"]?.string ?? r.url
                if let e = v["enabled"]?.bool { r.enabled = e }
                r.envNames += v["env_vars"]?.strings ?? []
                if let b = v["bearer_token_env_var"]?.string { r.headerVariables.append(b) }
                for (k, x) in v["env"]?.table ?? [:] { r.env[k] = x.string ?? "" }
                for (k, x) in v["http_headers"]?.table ?? [:] { r.headers[k] = x.string ?? "" }
                for (k, _) in v["env_http_headers"]?.table ?? [:] { r.headerVariables.append(k) }
            case "env":
                for (k, x) in v { r.env[k] = x.string ?? "" }
            case "http_headers":
                for (k, x) in v { r.headers[k] = x.string ?? "" }
            case "env_http_headers":
                r.headerVariables += Array(v.keys)
            default:
                break
            }
            byName[name] = r
        }
        return order.compactMap { byName[$0] }
    }

    static func splitDotted(_ s: String) -> [String] {
        var parts: [String] = [], cur = ""
        var quote: Character? = nil
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "." { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur)
        return parts
    }

    // MARK: DSH YAML

    static func dshYAML(_ text: String) -> [RawServer] {
        guard let root = MiniYAML.parse(text)?.seq else { return [] }
        var out: [RawServer] = []
        func visit(_ entry: YAMLValue) {
            guard let m = entry.map else { return }
            for inserted in m["insert"]?.seq ?? [] { visit(inserted) }
            let name = m["name"]?.string ?? ""
            let disabled = ["true", "yes"].contains(m["disabled"]?.string?.lowercased() ?? "")
            if name.hasSuffix("dsh-mcp-client"), let c = m["config"]?.map {
                var r = dshRaw(c["serverName"]?.string ?? m["id"]?.string ?? "mcp", c)
                if disabled { r.enabled = false }
                out.append(r)
            }
            if name.hasSuffix("dsh-mcp-manager") || m["id"]?.string == "mcp" {
                for (server, value) in m["config"]?["servers"]?.map ?? [:] {
                    guard let c = value.map else { continue }
                    var r = dshRaw(server, c)
                    if disabled { r.enabled = false }
                    out.append(r)
                }
            }
        }
        root.forEach(visit)
        return out
    }

    static func dshRaw(_ name: String, _ c: [String: YAMLValue]) -> RawServer {
        var r = RawServer(name: name)
        r.command = c["command"]?.string
        r.args = c["args"]?.seq?.compactMap(\.string) ?? []
        for (k, v) in c["env"]?.map ?? [:] { r.env[k] = v.string ?? "" }
        r.url = c["url"]?.string
        for (k, v) in c["headers"]?.map ?? [:] { r.headers[k] = v.string ?? "" }
        r.type = c["transport"]?.string
        if let e = c["enabled"]?.string?.lowercased() { r.enabled = !["false", "no"].contains(e) }
        if let d = c["disabled"]?.string?.lowercased() { r.enabled = !["true", "yes"].contains(d) }
        return r
    }

    // MARK: Plugins

    static func plugins(_ adapter: HarnessAdapter) -> [MCPServer] {
        var out: [MCPServer] = []
        if adapter.id == "codex" {
            // Enabled plugins in config.toml → newest cached version's .mcp.json.
            guard let cache = adapter.mcpPluginFiles.first.map(Paths.expand),
                  let config = adapter.mcpFiles.first.map(Paths.expand),
                  let text = try? String(contentsOfFile: config, encoding: .utf8) else { return [] }
            for table in MiniTOML.parse(text) where table.name.hasPrefix("plugins.") && table.values["enabled"]?.bool == true {
                let id = String(table.name.dropFirst("plugins.".count))
                let parts = id.split(separator: "@").map(String.init)
                guard parts.count == 2 else { continue }
                let dir = (cache as NSString).appendingPathComponent("\(parts[1])/\(parts[0])")
                let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                    .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                guard let latest = versions.last else { continue }
                let file = (dir as NSString).appendingPathComponent("\(latest)/.mcp.json")
                out += read(file, adapter: adapter, scope: .global, project: nil, plugin: parts[0])
            }
            return out
        }
        for pattern in adapter.mcpPluginFiles {
            for file in Paths.glob(Paths.expand(pattern)) {
                let plugin = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
                out += read(file, adapter: adapter, scope: .global, project: nil, plugin: plugin)
            }
        }
        return out
    }
}

// MARK: - Overview rows

/// One MCP name across agents (the MCP page lists these).
public struct MCPGroup: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var servers: [MCPServer]

    public var harnessIDs: [String] {
        var seen: [String] = []
        for s in servers where !seen.contains(s.harnessID) { seen.append(s.harnessID) }
        return seen
    }
    public var enabledHarnessIDs: [String] {
        var seen: [String] = []
        for s in servers where s.enabled && !seen.contains(s.harnessID) { seen.append(s.harnessID) }
        return seen
    }
    public var isPluginOnly: Bool { servers.allSatisfy { $0.plugin != nil } }
    public var hasPlaintextSecret: Bool { servers.contains { !$0.plaintextSecrets.isEmpty } }
    public var floating: String? { servers.compactMap(\.floatingPackage).first }
    public var allOff: Bool { servers.allSatisfy { !$0.enabled } }
    /// The same agent has it set up more than once (e.g. global and project).
    public var duplicateHarnessIDs: [String] {
        Dictionary(grouping: servers, by: \.harnessID).filter { $0.value.count > 1 }.keys.sorted()
    }
    /// Agents run different setups under this one name.
    public var setupsDiffer: Bool { Set(servers.map(\.identity)).count > 1 }
}

public extension MCPInventory {
    static func groups(_ servers: [MCPServer]) -> [MCPGroup] {
        Dictionary(grouping: servers, by: { $0.name })
            .map { MCPGroup(name: $0.key, servers: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
