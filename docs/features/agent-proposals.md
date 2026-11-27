# Agent proposals

Agent proposals allow external coding agents to request skill installs, toggles, adoptions, or removals via the `tackroom` CLI while reserving actual execution for user approval inside `TackroomApp`.

## Sub-features

- `proposal-submit` queues a JSON proposal with `--as` and `--reason` without mutating any skill files.
- `proposal-list` reports `pending`, `approved`, `rejected`, or `failed` proposal status via CLI.
- `proposal-review-ui` renders pending proposals in the `Agent 請求` tab with the calculated change preview.

## How to get to it (user POV)

- An agent runs `tackroom propose <install|enable|disable|remove|adopt> ... --as <agent> --reason "..."`.
- An agent polls `tackroom proposals --json`.
- The user opens `Agent 請求` in `TackroomApp` and approves or rejects a pending request.

## Driving it with scripts/verify-tackroom.sh

Preconditions:

- `./scripts/verify-tackroom.sh doctor` passes and `seed` has run.
- No pending proposals exist in `$TACKROOM_VERIFY_DIR/home/.tackroom/proposals`.

- **Submit proposal.** Propose adopting `alpha-skill` as `codex`. Run `./scripts/verify-tackroom.sh cli -- propose adopt alpha-skill --as codex --reason "Verify proposal flow" --json`. Exit code `0` and JSON return an `id` with `"status": "pending"`.
- **Confirm no premature mutation.** Query proposals and inspect folders. Run `./scripts/verify-tackroom.sh cli -- proposals --json` and `./scripts/verify-tackroom.sh inspect`. Proposal appears as `pending`, while `.claude/skills/alpha-skill` remains an ordinary directory (not symlinked).
- **Render Agent Requests UI.** Open the proposals tab in `TackroomApp`. Run `./scripts/verify-tackroom.sh snapshot "$TACKROOM_VERIFY_DIR/artifacts/agent-proposals/proposals.png" -- -selectProposals 1 -appearance light`. `sips` reports valid image dimensions and the PNG is saved in artifacts.

## Gotchas

- `tackroom propose` fails unless `--reason` is non-empty.
- `--for` must match an adapter ID from `DefaultAdapters.all` (`claude-code`, `codex`, `antigravity`, `deepseek`, `cursor`, `opencode`, `gemini-cli`, `copilot`, `devin`).
- `tackroom` CLI prints human-readable messages in Traditional Chinese when `--json` is omitted; always pass `--json` in automated assertions.
