---
name: verify-tackroom
description: Verify Tackroom macOS SwiftUI app and tackroom CLI behavior in an isolated TACKROOM_HOME using scripts/verify-tackroom.sh and the docs/features/ Feature Map. Use when proving UI screens, adoption, toggles, proposals, installs, MCP/docs views, or CLI output without touching real user skills.
---

# Verify Tackroom

Drive both Tackroom surfaces (`TackroomApp` SwiftUI desktop window and `tackroom` CLI) against an isolated `TACKROOM_HOME` scratch directory via `scripts/verify-tackroom.sh`. Read `docs/features/README.md` before running a recipe.

## Launch

Build the binaries first (one-time per edit):

```bash
./scripts/check.sh
```

Note: `scripts/check.sh` and `scripts/verify-tackroom.sh` automatically export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when `xcode-select -p` points to CommandLineTools, because the Swift `Testing` module and Swift 6.4 toolchain live in Xcode.

Seed a fresh isolated environment for your verification run:

```bash
export TACKROOM_VERIFY_DIR=/tmp/tackroom-verify-run1
./scripts/verify-tackroom.sh seed
```

`seed` populates `$TACKROOM_VERIFY_DIR/home` (used as `TACKROOM_HOME` and `HOME`), `$TACKROOM_VERIFY_DIR/fixtures/installable-skill`, `$TACKROOM_VERIFY_DIR/sample-project`, and preserves `$TACKROOM_VERIFY_DIR/artifacts`.

## Doctor

Before driving any feature, run the read-only health check:

```bash
./scripts/verify-tackroom.sh doctor
```

Require `cli_bin: ok`, `app_bin: ok`, `seeded_home: yes`, and an isolated `tackroom_home` distinct from your real `$HOME`.

## Drive

- **CLI surface:** `./scripts/verify-tackroom.sh cli -- <tackroom args...>`
- **GUI surface:** `./scripts/verify-tackroom.sh snapshot <artifact.png> -- <TackroomApp launch flags...>`
- **State inspection:** `./scripts/verify-tackroom.sh inspect`

Key `TackroomApp` launch flags active when `TACKROOM_HOME` is set (`Sources/TackroomApp/TackroomApp.swift`, `AppModel.swift`, `UpdatesView.swift`, `InspectorView.swift`, `MenuBar.swift`):
- `-appearance light|dark`
- `-selectSkill <name>`, `-selectAgent <id>`, `-selectProposals 1`, `-selectUpdates 1`, `-selectActivity 1`, `-selectMCP 1`, `-selectDocs 1`
- `-proposeAdopt <name>` with optional `-autoConfirm <seconds>`
- `-showInstall <local-folder-path>`
- `-multiSelect <a,b>`
- `-snapshotDelay <seconds>` (clamped in `TackroomApp.swift` to `max(delay, 6)`)

Follow the per-feature recipes in `docs/features/`.

## Evidence

Store all proof artifacts under `$TACKROOM_VERIFY_DIR/artifacts/<feature>/`.

Proof standards:
1. Exercise the real `tackroom` binary and `TackroomApp` executable, never internal unit helpers.
2. For CLI checks, record the exact command, stdout, stderr, and exit code.
3. For GUI checks, capture a PNG via `snapshot` (verified with `sips` pixel dimensions) and confirm state side effects with `inspect` or `cli -- ... --json`.
4. Never drive real `$HOME/.tackroom` or real agent skill folders during verification.

## Cleanup

After capturing proof, tear down the run's tracked PID and scratch directories:

```bash
./scripts/verify-tackroom.sh cleanup
```

`cleanup` kills only the PID recorded in `$TACKROOM_VERIFY_DIR/.verify-pid`, removes `home`, `fixtures`, and `sample-project`, and leaves `$TACKROOM_VERIFY_DIR/artifacts` intact. Also run `cleanup` after failed attempts so no stray `TackroomApp` process remains.

## Helpers

`scripts/verify-tackroom.sh` is the single executable helper for this skill:
- `./scripts/verify-tackroom.sh doctor`
- `./scripts/verify-tackroom.sh seed`
- `./scripts/verify-tackroom.sh cli -- <args...>`
- `./scripts/verify-tackroom.sh snapshot <output.png> [-- <app args...>]`
- `./scripts/verify-tackroom.sh inspect`
- `./scripts/verify-tackroom.sh cleanup`
