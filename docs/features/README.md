# Tackroom verification map

This directory is the maintained source for verifying the user-facing behavior of Tackroom. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Run `./scripts/check.sh` so `.build/debug/tackroom` and `.build/debug/TackroomApp` are built from current source.
- Set `export TACKROOM_VERIFY_DIR=/tmp/tackroom-verify-$RUN_ID` so concurrent or repeated runs do not touch real `$HOME` or each other.
- Run `./scripts/verify-tackroom.sh seed` to populate `alpha-skill`, `beta-skill`, `shared-diff`, `broken-link`, `.claude.json`, `.claude/CLAUDE.md`, `fixtures/installable-skill`, and `sample-project`.
- Run `./scripts/verify-tackroom.sh doctor` and require `cli_bin: ok`, `app_bin: ok`, and `seeded_home: yes`.
- Never drive the real user `$HOME/.tackroom` store during verification.

## Driving conventions

- Start every recipe from the baseline seeded state unless its preconditions say otherwise.
- Run CLI commands through `./scripts/verify-tackroom.sh cli -- <command>`.
- Run GUI checks through `./scripts/verify-tackroom.sh snapshot <output.png> -- <flags>`.
- Verify file-system side effects with `./scripts/verify-tackroom.sh inspect`.
- Do not remove proof artifacts in `$TACKROOM_VERIFY_DIR/artifacts` during cleanup.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- GUI proof includes a rendered PNG with non-zero dimensions from `sips`.
- CLI proof includes the command, stdout, stderr, and exit code.
- Mutation proof includes a read-only second view (`inspect` or `cli` JSON output) showing symlinks, lockfile entries, and store git history.
- Record the feature ID and entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with scripts/verify-tackroom.sh` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Skill overview](./skill-overview.md) covers inventory scanning, differing copies, broken links, and project scopes.
- [Adopt and toggle](./adopt-and-toggle.md) covers bringing skills under management, per-agent symlinks, and git history.
- [Agent proposals](./agent-proposals.md) covers CLI proposal submission, status polling, and app review UI.
- [Install and updates](./install-and-updates.md) covers local/GitHub install previews, risk checks, and update inspection.
- [MCP and docs](./mcp-and-docs.md) covers read-only MCP overview with secret masking and agent instruction docs.
