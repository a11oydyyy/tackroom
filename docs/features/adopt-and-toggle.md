# Adopt and toggle

Adopt and toggle moves a skill into Tackroom's git-backed store (`~/.tackroom/store`), replaces agent copies with symlinks, and lets the user toggle agents or undo changes via History.

## Sub-features

- `adopt-preview` displays the plan preview before moving any files.
- `adopt-confirm` moves the skill into `.tackroom/store`, writes `tackroom.lock`, creates symlinks, and commits to git.
- `adopt-trash` moves replaced non-managed copies to `.Trash` (`$TACKROOM_HOME/.Trash` when isolated).
- `toggle-switch` turns a managed skill on or off per agent via symlinks.

## How to get to it (user POV)

- Open a non-managed skill in `TackroomApp` and click `交由 Tackroom 管理`, then confirm in the bottom-right preview sheet.
- Flip an agent toggle switch in the skill's detail pane.
- Launch `TackroomApp` in isolated mode with `-proposeAdopt <skill> -autoConfirm <seconds>`.

## Driving it with scripts/verify-tackroom.sh

Preconditions:

- `./scripts/verify-tackroom.sh doctor` passes and `seed` has run.
- `alpha-skill` is an unmanaged folder in `$TACKROOM_VERIFY_DIR/home/.claude/skills/alpha-skill`.

- **Preview adoption.** Open the adoption preview without confirming. Run `./scripts/verify-tackroom.sh snapshot "$TACKROOM_VERIFY_DIR/artifacts/adopt-and-toggle/adopt-preview.png" -- -proposeAdopt alpha-skill -appearance light`. PNG captures the preview sheet and `inspect` shows `.tackroom/store` does not exist yet.
- **Confirm adoption.** Adopt `alpha-skill` in isolated mode. Run `./scripts/verify-tackroom.sh snapshot "$TACKROOM_VERIFY_DIR/artifacts/adopt-and-toggle/adopt-confirmed.png" -- -proposeAdopt alpha-skill -autoConfirm 2 -appearance light`. PNG captures the updated window.
- **Verify store and symlinks.** Inspect isolated state and CLI status. Run `./scripts/verify-tackroom.sh inspect` and `./scripts/verify-tackroom.sh cli -- status alpha-skill --json`. `tackroom.lock` contains `alpha-skill`, `.claude/skills/alpha-skill` is a symlink into `.tackroom/store/skills/alpha-skill`, `.Trash` holds the replaced original folder, and `git log` shows the `[gui]` commit.

## Gotchas

- `alpha-skill` is already adopted after the confirm step; run `./scripts/verify-tackroom.sh seed` before re-running the preview step.
- Do not test adoption outside `TACKROOM_HOME` or real skills will be moved into `~/.tackroom/store` and `~/.Trash`.
