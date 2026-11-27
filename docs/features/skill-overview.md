# Skill overview

Skill overview lets a user inspect every skill loaded across agents, spot differing copies or broken links, and view project-scoped skills alongside global ones.

## Sub-features

- `overview-cli` lists every agent's loaded and broken skills as JSON or text.
- `overview-status` reports where a single skill lives, who uses it, and whether Tackroom manages it.
- `overview-project` includes project-local skills when passed a project path.
- `overview-gui` renders the main Tackroom three-column window with counts and issue badges.

## How to get to it (user POV)

- Open TackroomApp to the default `Skill 總覽` sidebar item.
- Select a skill row to inspect its copies and issues in the detail pane.
- Run `tackroom list [--project <folder>] [--json]` or `tackroom status <skill> [--json]` in a terminal.

## Driving it with scripts/verify-tackroom.sh

Preconditions:

- `./scripts/verify-tackroom.sh doctor` passes and `seed` has run.
- Real agent folders on the host may still appear if not inside `TACKROOM_HOME`, while seeded skills live inside `$TACKROOM_VERIFY_DIR/home`.

- **List skills as JSON.** Query all agents. Run `./scripts/verify-tackroom.sh cli -- list --json`. Exit code `0` and stdout list `alpha-skill` (`loaded`), `beta-skill` (`loaded`), `shared-diff`, and `broken-link` (`not-loadable`).
- **Inspect one skill.** Query `shared-diff`. Run `./scripts/verify-tackroom.sh cli -- status shared-diff --json`. Exit code `0` and JSON show `"managed": false` with both `claude-code` and `codex` copies.
- **Inspect project scope.** Include the seeded project. Run `./scripts/verify-tackroom.sh cli -- list --project "$TACKROOM_VERIFY_DIR/sample-project" --json`. Exit code `0` and `claude-code` includes `proj-skill` with `"scope": "project"`.
- **Render GUI overview.** Capture the default window with `alpha-skill` selected. Run `./scripts/verify-tackroom.sh snapshot "$TACKROOM_VERIFY_DIR/artifacts/skill-overview/overview.png" -- -selectSkill alpha-skill -appearance light`. `sips` reports valid pixel dimensions and the PNG is saved in artifacts.

## Gotchas

- `TackroomApp` snapshot delay is clamped to at least 6 seconds (`TackroomApp.swift:72`), so each `snapshot` call takes ~6-8 seconds.
- Running `tackroom` directly without `scripts/verify-tackroom.sh cli` hits the real `$HOME` unless `TACKROOM_HOME` is explicitly exported.
