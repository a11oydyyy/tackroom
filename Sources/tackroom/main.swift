// tackroom — the command line for agents. Agents can look things up and make
// proposals; nothing here changes skills. The user approves in the app.
import Foundation
import TackroomKit

nonisolated(unsafe) var args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    tackroom：查詢 skill，並向使用者提出改動（由使用者在 Tackroom app 核准）。

    查詢
      tackroom list [--project <資料夾>] [--json]      每個 agent 載入了哪些 skill
      tackroom status <skill> [--json]               某個 skill 在哪裡、誰在用、是否由 Tackroom 管理
      tackroom roots [--project <資料夾>]              每個 agent 讀哪些資料夾
      tackroom hash <資料夾>                          skill 資料夾的內容指紋
      tackroom mcp list [--project <資料夾>] [--json]  各 agent 接了哪些 MCP（不會顯示任何金鑰的值）
      tackroom updates [--json]                      檢查上游更新（只讀，不會改動任何 skill）
      tackroom usage [--json]                        最近 30 天每個 skill 被用了幾次（只數名字）

    提案（不會直接改動，只送到 Tackroom 等使用者核准）
      tackroom propose install <owner/repo|網址|資料夾> [--skill <名稱>]... [--for <agent>]... [--project <資料夾>] --reason "<原因>"
      tackroom propose enable <skill> --for <agent> --reason "<原因>"
      tackroom propose disable <skill> --for <agent> --reason "<原因>"
      tackroom propose remove <skill> [--project <資料夾>] --reason "<原因>"
      tackroom propose adopt <skill> --reason "<原因>"
      tackroom proposals [--json]                    提案與結果（pending / approved / rejected / failed）

    共用
      --as <agent>    提案者名稱（也可用環境變數 TACKROOM_AGENT），例如 codex、claude-code
    Agent 代號：\(DefaultAdapters.all.map(\.id).joined(separator: "、"))
    """)
    exit(2)
}

func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func takeAll(_ flag: String) -> [String] {
    var values: [String] = []
    while let v = take(flag) { values.append(v) }
    return values
}

func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

func printJSON(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("tackroom: " + message + "\n").utf8))
    exit(1)
}

func stateWord(_ s: LoadState) -> String {
    switch s {
    case .loaded: return "loaded"
    case .loadedDuplicate: return "loaded-duplicate"
    case .shadowed: return "shadowed"
    case .hiddenByStub: return "hidden-by-stub"
    case .disabledStub: return "disabled-stub"
    case .disabledInConfig: return "disabled-in-config"
    case .notLoadable: return "not-loadable"
    }
}

guard !args.isEmpty else { usage() }
let command = args.removeFirst()
let json = takeFlag("--json")
let projectPath = take("--project").map { path in
    guard !path.isEmpty, !path.hasPrefix("--") else { fail("--project 需要一個專案資料夾路徑") }
    return URL(fileURLWithPath: path).standardizedFileURL.path
}
let agentName = take("--as") ?? ProcessInfo.processInfo.environment["TACKROOM_AGENT"] ?? "agent"

func scan() -> [HarnessResult] {
    if let projectPath {
        return Inventory.scan(adapters: AdapterConfig.load(),
                              project: Project(name: (projectPath as NSString).lastPathComponent, path: projectPath))
    }
    return Inventory.scan()
}

switch command {
case "hash":
    print(Scanner.hashFolder(args.first ?? ".").0)

case "list":
    let results = scan()
    if json {
        var out: [String: [[String: String]]] = [:]
        for r in results {
            out[r.adapter.id] = r.placements.map {
                ["name": $0.copy.name, "entry": $0.copy.entryPath, "state": stateWord($0.state),
                 "owner": $0.isHarnessOwned ? "agent" : "user", "scope": $0.scope.rawValue,
                 "model": $0.modelCanUse ? "yes" : "no"]
            }
        }
        printJSON(out)
    } else {
        for r in results {
            print("\(r.adapter.name)：載入 \(r.placements.filter { $0.state.isActive }.count) 個")
            for p in r.placements {
                print("  \(p.state.isActive ? "✓" : "–") \(p.copy.name)  [\(stateWord(p.state))] \(Paths.abbreviate(p.copy.entryPath))")
            }
        }
    }

case "status":
    guard let name = args.first else { usage() }
    let results = scan()
    guard let group = Overview.groups(from: results).first(where: { $0.name == name }) else { fail("找不到 skill「\(name)」") }
    let entry = Store().readLock().skills[name]
    if json {
        printJSON([
            "name": name, "description": group.description, "managed": entry != nil,
            "source": entry?.source ?? "", "agents": group.activeHarnessIDs,
            "copies": group.placements.map { ["agent": $0.harnessID, "path": $0.copy.entryPath, "state": stateWord($0.state)] },
        ] as [String: Any])
    } else {
        print("\(name)：\(group.description)")
        print(entry.map { "由 Tackroom 管理，來源 \($0.source)" } ?? "尚未納入 Tackroom 管理")
        for p in group.placements { print("  \(p.harnessID)  [\(stateWord(p.state))] \(Paths.abbreviate(p.copy.entryPath))") }
    }

case "updates":
    let result = UpdateChecker().run()
    func localWord(_ l: LocalChange) -> String {
        switch l {
        case .none: return "未修改"
        case .edited(let ws): return ws ? "本機只改了空白" : "本機有修改"
        case .unknown: return "無法對應上游版本"
        }
    }
    if json {
        printJSON(result.status.keys.sorted().map { name -> [String: Any] in
            var row: [String: Any] = ["name": name]
            switch result.status[name]! {
            case .current: row["status"] = "current"
            case .skipped: row["status"] = "skipped"
            case .failed(let why): row["status"] = "failed"; row["reason"] = why
            case .update:
                row["status"] = "update"
                if let u = result.updates.first(where: { $0.name == name }) {
                    row["from"] = u.fromCommit ?? ""; row["to"] = u.toCommit; row["local"] = localWord(u.local)
                }
            }
            return row
        })
    } else {
        if result.status.isEmpty { print("沒有可以檢查更新的 skill（需要由 Tackroom 管理且有上游來源）") }
        for name in result.status.keys.sorted() {
            switch result.status[name]! {
            case .current: print("\(name)：已是最新")
            case .skipped: print("\(name)：上游新版已略過")
            case .failed(let why): print("\(name)：無法檢查（\(why)）")
            case .update:
                let u = result.updates.first { $0.name == name }!
                print("\(name)：有新版本 \(u.fromCommit ?? "?") → \(u.toCommit)，\(localWord(u.local))")
            }
        }
    }

case "mcp":
    // Read-only MCP overview. Never prints a secret value: only where one is.
    guard args.first == "list" || args.isEmpty else { usage() }
    let project = projectPath.map { Project(name: ($0 as NSString).lastPathComponent, path: $0) }
    let servers = MCPInventory.scan(project: project)
    if json {
        printJSON(servers.map { s -> [String: Any] in
            ["name": s.name, "agent": s.harnessID, "enabled": s.enabled, "scope": s.scope.rawValue,
             "plugin": s.plugin ?? "", "transport": s.transport.rawValue, "program": s.program ?? "",
             "address": s.address ?? "", "plaintext_secrets": s.plaintextSecrets, "variables": s.variables,
             "floating_package": s.floatingPackage ?? "", "file": Paths.abbreviate(s.file)]
        })
    } else {
        for adapter in AdapterConfig.load() {
            let mine = servers.filter { $0.harnessID == adapter.id }
            print("\(adapter.name)：\(mine.count) 個")
            for s in mine {
                var notes: [String] = []
                if !s.enabled { notes.append("關著") }
                if let p = s.plugin { notes.append("plugin \(p)") }
                if !s.plaintextSecrets.isEmpty { notes.append("明文金鑰：" + s.plaintextSecrets.joined(separator: "、")) }
                if let f = s.floatingPackage { notes.append("每次抓最新版 \(f)") }
                let icon = s.enabled ? "✓" : "–"
                let programName = s.program.map { ($0 as NSString).lastPathComponent } ?? ""
                let target = s.address ?? programName
                let noteText = notes.isEmpty ? "" : "  （" + notes.joined(separator: "；") + "）"
                print("  \(icon) \(s.name)  [\(s.transport.rawValue)] \(target)\(noteText)")
            }
        }
    }

case "usage":
    // Times each skill was used in the last 30 days (names and counts only).
    let names = Set(scan().flatMap(\.placements).map(\.copy.name))
    let counts = UsageCounter.count(names: names)
    if json { printJSON(counts) } else {
        for (name, n) in counts.sorted(by: { $0.value > $1.value }) { print("\(n)  \(name)") }
        if counts.isEmpty { print("最近 30 天沒有找到使用紀錄") }
    }

case "roots":
    for r in scan() {
        print(r.adapter.name)
        for root in r.roots {
            var note = root.exists ? "\(root.skillCount) 個" : "不存在"
            if let same = root.sameFolderAs { note = "與 \(Paths.abbreviate(same)) 是同一個資料夾" }
            if let e = root.error { note = e }
            print("  \(Paths.abbreviate(root.path))  (\(root.root.scope.rawValue), \(root.root.role.rawValue))  \(note)")
        }
    }

case "propose":
    guard !args.isEmpty else { usage() }
    let action = args.removeFirst()
    guard let reason = take("--reason"), !reason.isEmpty else { fail("請用 --reason 說明為什麼要這樣做") }
    let targets = takeAll("--for")
    let skills = takeAll("--skill")
    let known = Set(DefaultAdapters.all.map(\.id))
    for t in targets where !known.contains(t) { fail("不認得 agent「\(t)」；可用：\(known.sorted().joined(separator: "、"))") }
    guard let subject = args.first else { usage() }
    let kind: Proposal.Kind
    switch action {
    case "install":
        var source = subject
        if FileManager.default.fileExists(atPath: subject) { source = Paths.realpath(subject) ?? subject }
        kind = .install(source: source, skills: skills, agents: targets.isEmpty ? ["claude-code", "codex"] : targets,
                        projectPath: projectPath)
    case "enable", "disable":
        guard let target = targets.first else { fail("請用 --for 指定 agent") }
        kind = .toggle(name: subject, agent: target, on: action == "enable")
    case "remove":
        guard args.count == 1, !subject.hasPrefix("--"), targets.isEmpty, skills.isEmpty else { usage() }
        kind = projectPath.map { .projectRemove(name: subject, path: $0) } ?? .remove(name: subject)
    case "adopt": kind = .adopt(name: subject)
    default: usage()
    }
    let proposal = try ProposalQueue().submit(Proposal(agent: agentName, kind: kind, reason: reason))
    if json {
        printJSON(["id": proposal.id, "status": proposal.status.rawValue])
    } else {
        print("已送出提案 \(proposal.id)：\(proposal.summary)")
        print("請使用者在 Tackroom 核准。之後可用 `tackroom proposals` 查看結果。")
    }

case "proposals":
    let all = ProposalQueue().all()
    if json {
        printJSON(all.map { p -> [String: Any] in
            ["id": p.id, "agent": p.agent, "summary": p.summary, "reason": p.reason, "status": p.status.rawValue,
             "note": p.note ?? ""]
        })
    } else if all.isEmpty {
        print("沒有提案")
    } else {
        for p in all { print("\(p.id)  [\(p.status.rawValue)]  \(p.agent)：\(p.summary)" + (p.note.map { "（\($0)）" } ?? "")) }
    }

default:
    usage()
}
