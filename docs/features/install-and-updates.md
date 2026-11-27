# Install and updates

Install and updates let a user preview a local folder, `.zip`, or GitHub skill with risk analysis before installing, and inspect upstream updates separately from local edits.

## Sub-features

- `install-sheet` opens the install modal prefilled with a local folder or GitHub target and computes risk notes.
- `updates-cli` checks upstream status for managed skills (`tackroom updates --json`).
- `updates-ui` opens the `更新` view showing pending upstream updates or the empty state.

## How to get to it (user POV)

- Press `⌘N` or drag a folder/`.zip` onto `TackroomApp` to open the install sheet.
- Select `更新` in the sidebar or press `⌘⇧U` to check upstream updates.
- Run `tackroom updates --json` in a terminal.

## Driving it with scripts/verify-tackroom.sh

Preconditions:

- `./scripts/verify-tackroom.sh doctor` passes and `seed` has run.
- `$TACKROOM_VERIFY_DIR/fixtures/installable-skill/SKILL.md` exists.

- **Open install sheet for local fixture.** Launch `TackroomApp` with `-showInstall`. Run `./scripts/verify-tackroom.sh snapshot "$TACKROOM_VERIFY_DIR/artifacts/install-and-updates/install-sheet.png" -- -showInstall "$TACKROOM_VERIFY_DIR/fixtures/installable-skill" -appearance light`. PNG captures the window with `installable-skill` loaded in the install sheet.
- **Check CLI updates.** Run `updates` in isolated mode. Run `./scripts/verify-tackroom.sh cli -- updates --json`. Exit code `0` and stdout outputs `[]` when no managed GitHub skills exist.
- **Render Updates view.** Open the updates tab in `TackroomApp`. Run `./scripts/verify-tackroom.sh snapshot "$TACKROOM_VERIFY_DIR/artifacts/install-and-updates/updates.png" -- -selectUpdates 1 -appearance light`. `sips` reports valid PNG dimensions.

## Gotchas

- `InstallSheet` is presented as a SwiftUI `.sheet`; `-snapshot` captures the main window view hierarchy, so confirm sheet presentation cleanly when testing modals.
- GitHub remote install and upstream update checks require network access; use `$TACKROOM_VERIFY_DIR/fixtures/installable-skill` for deterministic offline verification.
