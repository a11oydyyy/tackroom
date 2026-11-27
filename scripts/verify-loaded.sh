#!/bin/zsh
# M1 check: does Tackroom's list match what each agent really loads?
# Codex, Claude Code and DSH are checked without any AI call.
# Pass --with-antigravity to also ask Antigravity (one small AI call).
set -e
cd "$(dirname "$0")/.."
swift build --product tackroom >/dev/null
WORK=$(mktemp -d)
cleanup() {
  # Remove the test conversations the agents saved for this throwaway folder.
  rm -rf "$HOME/.claude/projects/"*"${$(basename "$WORK")//./-}"-cwd(N)
  if [ -f "$WORK/agy.jsonl" ]; then
    local id=$(python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
  d=json.loads(l)
  if d.get("event")=="init": print(d["conversation_id"]); break' "$WORK/agy.jsonl" 2>/dev/null)
    if [ -n "$id" ]; then
      local G="$HOME/.gemini/antigravity-cli"
      rm -rf "$G/annotations/$id.pbtxt" "$G/presence/$id.lock" "$G/conversations/$id.db" "$G/brain/$id"
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/cwd"
.build/debug/tackroom list --json > "$WORK/tackroom.json"

# Codex: render the prompt it would send (no AI call).
(cd "$WORK/cwd" && codex debug prompt-input "hi" 2>/dev/null) > "$WORK/codex.json" || true

# Claude Code: its first startup line lists the skills it found.
CLAUDE=$(ls -d "$HOME/Library/Application Support/Claude/claude-code"/*/*/claude.app/Contents/MacOS/claude 2>/dev/null | tail -1)
if [ -n "$CLAUDE" ]; then
  (cd "$WORK/cwd" && timeout 60 "$CLAUDE" -p "/doesnotexist" --output-format stream-json --verbose --max-turns 1 2>/dev/null | head -1) > "$WORK/claude.json" || true
fi

# DSH: run DSH's own skill scanner from inside the app.
DSH_APP="/Applications/DeepSeek Harness.app"
if [ -d "$DSH_APP" ]; then
  cat > "$WORK/dsh.mjs" <<'EOF'
const M = "/Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-skill-filesystem/lib/index.js";
const mod = await import(M);
const ctx = { logger: { warn() {}, info() {}, debug() {}, error() {} }, on() {}, effect() {}, get() { return undefined } };
const ac = new AbortController();
const p = new mod.FileSystemSkillProvider(ctx, { signal: ac.signal, invalidate() {} }, { watch: false });
const r = await p.list({ cwd: process.argv[2] });
const c = Array.isArray(r) ? r : r.candidates;
const win = new Map();
for (const x of [...c].sort((a, b) => a.rank - b.rank)) if (!win.has(x.name)) win.set(x.name, x);
console.log(JSON.stringify([...win.values()].filter(x => x.invocation.modelInvocable || x.invocation.userInvocable).map(x => x.name)));
ac.abort(); process.exit(0);
EOF
  ELECTRON_RUN_AS_NODE=1 "$DSH_APP/Contents/MacOS/DeepSeek Harness" "$WORK/dsh.mjs" "$WORK/cwd" > "$WORK/dsh.json" 2>/dev/null || true
fi

# Gemini CLI and OpenCode: their own skill lists (no AI call).
if command -v gemini >/dev/null; then
  (cd "$WORK/cwd" && timeout 60 gemini skills list --all 2>/dev/null) > "$WORK/gemini.txt" || true
fi
if command -v opencode >/dev/null; then
  (cd "$WORK/cwd" && timeout 90 opencode debug skill 2>/dev/null) > "$WORK/opencode.txt" || true
fi

if [[ "$1" == "--with-antigravity" ]]; then
  (cd "$WORK/cwd" && timeout 150 agy -p "Without using any tools, list the exact name of every skill in your available-skills list, one per line, nothing else." \
     --output-format stream-json --print-timeout 120s 2>/dev/null) > "$WORK/agy.jsonl" || true
fi

python3 -I - "$WORK" <<'EOF'
import json, re, sys, os
work = sys.argv[1]
tk = json.load(open(f"{work}/tackroom.json"))
def ours(agent, model_only=False):
    return {x["name"] for x in tk.get(agent, []) if x["state"].startswith("loaded") and x["owner"] == "user"
            and (not model_only or x["model"] == "yes")}
def report(label, theirs, mine):
    if theirs is None:
        print(f"{label}: 略過（沒有取得 agent 的資料）"); return True
    ok = theirs == mine
    print(f"{label}: {'一致' if ok else '不一致'}（agent {len(theirs)} 個，Tackroom {len(mine)} 個）")
    if not ok:
        print("   只有 agent 有：", sorted(theirs - mine)); print("   只有 Tackroom 有：", sorted(mine - theirs))
    return ok

results = []
t = open(f"{work}/codex.json").read() if os.path.exists(f"{work}/codex.json") else ""
roots = dict(re.findall(r"`(r\d+)` = `([^`]*)`", t))
home = os.path.expanduser("~")
user_roots = {k for k, v in roots.items() if v.startswith(home + "/.codex/skills") and not v.endswith("/.system") or v.startswith(home + "/.agents/skills")}
codex = {n for n, r in re.findall(r"\\n- ([a-z0-9][a-z0-9:_-]*): .*?\(file: (r\d+)/", t) if r in user_roots} if t else None
results.append(report("Codex（AI 看得到的）", codex, ours("codex", model_only=True)))

claude = None
if os.path.exists(f"{work}/claude.json"):
    try:
        init = json.loads(open(f"{work}/claude.json").read().splitlines()[0])
        listed = set(init.get("skills", []))
        mine = ours("claude-code")
        claude = mine & listed if mine else set()
        # Claude also lists plugin skills; only check that ours are all there.
        results.append(report("Claude Code（全域 skill 都有出現）", claude, mine))
    except Exception:
        results.append(report("Claude Code", None, set()))

dsh = set(json.load(open(f"{work}/dsh.json"))) if os.path.exists(f"{work}/dsh.json") and os.path.getsize(f"{work}/dsh.json") else None
dsh_mine = {x["name"] for x in tk.get("deepseek", []) if x["state"] in ("loaded",)}
results.append(report("DSH", dsh, dsh_mine))

if os.path.exists(f"{work}/gemini.txt") and "gemini-cli" in tk:
    found = set(re.findall(r"^(\S+) \[Enabled\](?! \[Built-in\])", open(f"{work}/gemini.txt").read(), re.M))
    results.append(report("Gemini CLI", found, ours("gemini-cli")))

if os.path.exists(f"{work}/opencode.txt") and "opencode" in tk:
    text = open(f"{work}/opencode.txt").read()
    try:
        found = {x["name"] for x in json.loads(text[text.index("["):]) if x["location"] != "<built-in>"}
    except ValueError:
        found = None
    results.append(report("OpenCode", found, ours("opencode")))

if os.path.exists(f"{work}/agy.jsonl"):
    resp = None
    for line in open(f"{work}/agy.jsonl"):
        d = json.loads(line)
        if d.get("event") == "result": resp = d["result"]["response"]
    names = {x.strip().strip("-*` ") for x in (resp or "").splitlines() if x.strip()}
    mine = {x["name"] for x in tk.get("antigravity", []) if x["state"].startswith("loaded") and x["model"] == "yes"}
    extra = names - mine
    print(f"Antigravity: Tackroom 的 {len(mine)} 個{'都有出現' if mine <= names else '有缺'}；"
          f"另有 {len(extra)} 個是 app 內建的（{', '.join(sorted(extra))}）")
    results.append(mine <= names)

sys.exit(0 if all(results) else 1)
EOF
