#!/bin/zsh
# Minimal control CLI for verifying TackroomApp and tackroom CLI inside an
# isolated TACKROOM_VERIFY_DIR without touching real ~/.tackroom or agent folders.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]] \
        && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

VERIFY_DIR="${TACKROOM_VERIFY_DIR:-/tmp/tackroom-verify-default}"
if [[ -z "$VERIFY_DIR" || "$VERIFY_DIR" == "/" ]]; then
    echo "verify-tackroom: unsafe TACKROOM_VERIFY_DIR='$VERIFY_DIR'" >&2
    exit 1
fi

RESOLVED_VERIFY="$(python3 -I -c 'import os,sys; print(os.path.realpath(os.path.abspath(sys.argv[1])))' "$VERIFY_DIR")"
RESOLVED_HOME="$(python3 -I -c 'import os; print(os.path.realpath(os.path.expanduser("~")))')"
if [[ "$RESOLVED_VERIFY" == "/" || "$RESOLVED_VERIFY" == "$RESOLVED_HOME" || "$RESOLVED_HOME" == "$RESOLVED_VERIFY"/* ]]; then
    echo "verify-tackroom: unsafe TACKROOM_VERIFY_DIR ($RESOLVED_VERIFY) overlaps real HOME ($RESOLVED_HOME)" >&2
    exit 1
fi

HOME_DIR="$RESOLVED_VERIFY/home"
FIXTURES_DIR="$RESOLVED_VERIFY/fixtures"
PROJECT_DIR="$RESOLVED_VERIFY/sample-project"
ARTIFACTS_DIR="$RESOLVED_VERIFY/artifacts"
PID_FILE="$RESOLVED_VERIFY/.verify-pid"

BIN_DIR="$(swift build --show-bin-path 2>/dev/null || echo "$REPO_ROOT/.build/debug")"
CLI_BIN="$BIN_DIR/tackroom"
APP_BIN="$BIN_DIR/TackroomApp"

usage() {
    cat >&2 <<'EOF'
Usage: scripts/verify-tackroom.sh <command> [args...]

Commands:
  doctor                          Read-only check of build binaries, isolation, and seeded state
  seed                            Reset and populate isolated TACKROOM_HOME, fixtures, and project
  cli [--] <args...>              Run tackroom CLI inside isolated TACKROOM_HOME
  snapshot <out.png> [-- args...] Launch TackroomApp in isolated home, capture PNG, stop PID
  inspect                         Read-only dump of isolated store, lockfile, proposals, links, Trash
  cleanup                         Kill tracked PID and delete home/fixtures/project (keeps artifacts)

Environment:
  TACKROOM_VERIFY_DIR             Isolated scratch root (default: /tmp/tackroom-verify-default)
EOF
    exit 2
}

require_seeded() {
    if [[ ! -d "$HOME_DIR" ]]; then
        echo "verify-tackroom: $HOME_DIR is not seeded. Run: scripts/verify-tackroom.sh seed" >&2
        exit 1
    fi
}

kill_tracked_pid() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" && "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            local i=0
            while kill -0 "$pid" 2>/dev/null && (( i < 15 )); do
                sleep 0.2
                (( i += 1 ))
            done
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$PID_FILE"
    fi
}

cmd="${1:-}"
[[ -z "$cmd" ]] && usage
shift

case "$cmd" in
    doctor)
        git_rev="$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
        swift_ver="$(swift --version 2>/dev/null | head -n 1 || echo "missing")"
        ok=0
        echo "verify_dir: $RESOLVED_VERIFY"
        echo "tackroom_home: $HOME_DIR (isolated from $RESOLVED_HOME)"
        echo "git_rev: $git_rev"
        echo "swift: $swift_ver"
        if [[ -x "$CLI_BIN" ]]; then
            echo "cli_bin: ok ($CLI_BIN)"
        else
            echo "cli_bin: MISSING ($CLI_BIN) -> run ./scripts/check.sh"
            ok=1
        fi
        if [[ -x "$APP_BIN" ]]; then
            echo "app_bin: ok ($APP_BIN)"
        else
            echo "app_bin: MISSING ($APP_BIN) -> run ./scripts/check.sh"
            ok=1
        fi
        if [[ -d "$HOME_DIR" ]]; then
            echo "seeded_home: yes"
        else
            echo "seeded_home: no (run scripts/verify-tackroom.sh seed)"
        fi
        if [[ -f "$PID_FILE" ]]; then
            pid="$(cat "$PID_FILE" 2>/dev/null || true)"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                echo "tracked_pid: running ($pid)"
            else
                echo "tracked_pid: stale ($pid)"
            fi
        else
            echo "tracked_pid: none"
        fi
        exit "$ok"
        ;;

    seed)
        kill_tracked_pid
        rm -rf "$HOME_DIR" "$FIXTURES_DIR" "$PROJECT_DIR"
        mkdir -p \
            "$HOME_DIR/.claude/skills/alpha-skill" \
            "$HOME_DIR/.codex/skills/beta-skill" \
            "$HOME_DIR/.claude/skills/shared-diff" \
            "$HOME_DIR/.codex/skills/shared-diff" \
            "$FIXTURES_DIR/installable-skill" \
            "$PROJECT_DIR/.claude/skills/proj-skill" \
            "$ARTIFACTS_DIR"

        cat > "$HOME_DIR/.claude/skills/alpha-skill/SKILL.md" <<'EOF'
---
name: alpha-skill
description: Alpha verification skill for Claude Code
---
Follow alpha steps.
EOF

        cat > "$HOME_DIR/.codex/skills/beta-skill/SKILL.md" <<'EOF'
---
name: beta-skill
description: Beta verification skill for Codex
---
Follow beta steps.
EOF

        cat > "$HOME_DIR/.claude/skills/shared-diff/SKILL.md" <<'EOF'
---
name: shared-diff
description: Shared skill Claude copy
---
Claude version body.
EOF

        cat > "$HOME_DIR/.codex/skills/shared-diff/SKILL.md" <<'EOF'
---
name: shared-diff
description: Shared skill Codex copy
---
Codex version body (differs).
EOF

        ln -s "$HOME_DIR/nowhere/missing-skill" "$HOME_DIR/.claude/skills/broken-link"

        cat > "$HOME_DIR/.claude.json" <<'EOF'
{
  "mcpServers": {
    "demo-mcp": {
      "command": "/usr/bin/echo",
      "args": ["ok"],
      "env": {
        "DEMO_TOKEN": "${DEMO_TOKEN}"
      }
    }
  }
}
EOF

        cat > "$HOME_DIR/.claude/CLAUDE.md" <<'EOF'
# Seeded Instructions
Use verify-tackroom for isolated checks.
EOF

        cat > "$FIXTURES_DIR/installable-skill/SKILL.md" <<'EOF'
---
name: installable-skill
description: Local fixture skill for install preview verification
---
Installable fixture body.
EOF

        cat > "$PROJECT_DIR/.claude/skills/proj-skill/SKILL.md" <<'EOF'
---
name: proj-skill
description: Project-local verification skill
---
Project skill body.
EOF

        echo "seeded:"
        echo "  TACKROOM_HOME=$HOME_DIR"
        echo "  FIXTURES_DIR=$FIXTURES_DIR"
        echo "  PROJECT_DIR=$PROJECT_DIR"
        echo "  ARTIFACTS_DIR=$ARTIFACTS_DIR"
        ;;

    cli)
        require_seeded
        [[ -x "$CLI_BIN" ]] || { echo "verify-tackroom: missing $CLI_BIN; run ./scripts/check.sh" >&2; exit 1; }
        if [[ "${1:-}" == "--" ]]; then
            shift
        fi
        env TACKROOM_HOME="$HOME_DIR" HOME="$HOME_DIR" "$CLI_BIN" "$@"
        ;;

    snapshot)
        require_seeded
        [[ -x "$APP_BIN" ]] || { echo "verify-tackroom: missing $APP_BIN; run ./scripts/check.sh" >&2; exit 1; }
        [[ $# -ge 1 ]] || usage
        out_png="$1"
        shift
        if [[ "${1:-}" == "--" ]]; then
            shift
        fi
        mkdir -p "$(dirname "$out_png")"
        rm -f "$out_png"
        kill_tracked_pid

        trap 'kill_tracked_pid' EXIT INT TERM
        env TACKROOM_HOME="$HOME_DIR" HOME="$HOME_DIR" "$APP_BIN" -snapshot "$out_png" "$@" >/dev/null 2>&1 &
        app_pid=$!
        echo "$app_pid" > "$PID_FILE"

        prev_size=-1
        stable=0
        deadline=$(( SECONDS + 30 ))
        while (( SECONDS < deadline )); do
            if [[ -f "$out_png" ]]; then
                size="$(stat -f %z "$out_png" 2>/dev/null || echo 0)"
                if (( size > 1000 )); then
                    if (( size == prev_size )); then
                        (( stable += 1 ))
                        if (( stable >= 1 )); then
                            break
                        fi
                    else
                        stable=0
                    fi
                fi
                prev_size="$size"
            fi
            if ! kill -0 "$app_pid" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done

        kill_tracked_pid
        trap - EXIT INT TERM

        if [[ ! -s "$out_png" ]]; then
            echo "verify-tackroom: snapshot failed; no image written to $out_png" >&2
            exit 1
        fi
        echo "snapshot: $out_png ($(stat -f %z "$out_png") bytes)"
        sips -g pixelWidth -g pixelHeight "$out_png"
        ;;

    inspect)
        require_seeded
        echo "=== STORE GIT LOG ==="
        if [[ -d "$HOME_DIR/.tackroom/store/.git" ]]; then
            git -C "$HOME_DIR/.tackroom/store" log -n 10 --oneline
        else
            echo "(no store git repo)"
        fi
        echo "=== LOCKFILE ==="
        if [[ -f "$HOME_DIR/.tackroom/store/tackroom.lock" ]]; then
            cat "$HOME_DIR/.tackroom/store/tackroom.lock"
        else
            echo "(no tackroom.lock)"
        fi
        echo "=== PROPOSALS ==="
        if [[ -d "$HOME_DIR/.tackroom/proposals" ]]; then
            ls -1 "$HOME_DIR/.tackroom/proposals"
            for f in "$HOME_DIR/.tackroom/proposals"/*.json(N); do
                echo "--- $f ---"
                cat "$f"
            done
        else
            echo "(no proposals dir)"
        fi
        echo "=== AGENT SKILL ENTRIES ==="
        for dir in "$HOME_DIR/.claude/skills" "$HOME_DIR/.codex/skills"; do
            echo "[$dir]"
            if [[ -d "$dir" ]]; then
                ls -la "$dir"
            else
                echo "(missing)"
            fi
        done
        echo "=== TRASH ==="
        if [[ -d "$HOME_DIR/.Trash" ]]; then
            ls -la "$HOME_DIR/.Trash"
        else
            echo "(empty)"
        fi
        ;;

    cleanup)
        kill_tracked_pid
        rm -rf "$HOME_DIR" "$FIXTURES_DIR" "$PROJECT_DIR" "$PID_FILE"
        echo "cleaned: $HOME_DIR, $FIXTURES_DIR, $PROJECT_DIR"
        echo "preserved artifacts: $ARTIFACTS_DIR"
        ;;

    *)
        usage
        ;;
esac
