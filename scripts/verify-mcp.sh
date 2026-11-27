#!/bin/zsh
# M6 check: does Tackroom's MCP overview match what each agent lists itself?
# Only names and on/off are compared; no setting values are printed.
set -e
cd "$(dirname "$0")/.."
swift build --product tackroom >/dev/null
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
.build/debug/tackroom mcp list --json > "$WORK/tackroom.json"
(cd "$WORK" && codex mcp list --json 2>/dev/null) > "$WORK/codex.json" || true
CLAUDE=$(command -v claude || ls -d "$HOME/Library/Application Support/Claude/claude-code"/*/*/claude.app/Contents/MacOS/claude 2>/dev/null | tail -1)
[ -n "$CLAUDE" ] && (cd "$WORK" && timeout 90 "$CLAUDE" mcp list 2>/dev/null) > "$WORK/claude.txt" || true
command -v agy >/dev/null && (cd "$WORK" && timeout 60 agy mcp list 2>/dev/null) > "$WORK/agy.txt" || true

python3 -I - "$WORK" <<'PY'
import json, os, re, sys
work = sys.argv[1]
tk = json.load(open(f"{work}/tackroom.json"))
def ours(agent, plugins=True):
    return {(s["name"], s["enabled"]) for s in tk if s["agent"] == agent and s["scope"] == "global" and (plugins or not s["plugin"])}
def report(label, theirs, mine):
    if theirs is None:
        print(f"{label}: 略過（沒有取得 agent 的資料）"); return True
    ok = theirs == mine
    print(f"{label}: {'一致' if ok else '不一致'}（agent {len(theirs)} 個，Tackroom {len(mine)} 個）")
    if not ok:
        print("   只有 agent 有：", sorted(theirs - mine)); print("   只有 Tackroom 有：", sorted(mine - theirs))
    return ok
def text(name):
    p = f"{work}/{name}"
    return open(p).read() if os.path.exists(p) and os.path.getsize(p) else None

results = []
c = text("codex.json")
results.append(report("Codex（名稱與開關）", {(x["name"], bool(x["enabled"])) for x in json.loads(c)} if c else None, ours("codex")))

t = text("claude.txt")
claude = None
if t is not None:
    claude = set() if "No MCP servers" in t else {(m, True) for m in re.findall(r"^([^\s:][^:]*):\s", t, re.M) if m != "Checking MCP server health..."}
# claude mcp list shows user-scope servers plus the project of the current folder (none here).
results.append(report("Claude Code", claude, {x for x in ours("claude-code")}))

t = text("agy.txt")
agy = None
if t is not None:
    agy = set() if "No MCP servers" in t else {(m.strip("-* ").split()[0], True) for m in t.splitlines() if m.strip() and not m.startswith(" ")}
results.append(report("Antigravity（設定檔裡的，不含 plugin 附帶）", agy, ours("antigravity", plugins=False)))
sys.exit(0 if all(results) else 1)
PY
