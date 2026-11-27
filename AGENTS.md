# Tackroom Agent Guide

Native macOS app and CLI for managing Agent Skills across AI coding agents.

## Layout

- `Sources/TackroomKit/` — pure domain library (scanning, adapters, git store, operations, updates, MCP, docs).
- `Sources/TackroomApp/` — SwiftUI app shell (`AppModel`, views, menu bar, preview/confirm flow).
- `Sources/tackroom/` — agent CLI (`tackroom`): read-only inspection and proposal submission only.
- `Tests/TackroomKitTests/` — Swift Testing suite including `ArchitectureBoundaryTests`.
- `Localization/` — `zh-Hant` source keys; `zh-Hans` and `en` `.lproj` string tables.
- `scripts/` — build, gate, live agent cross-checks, and isolated verification harness.

## Non-Negotiable Invariants

Enforced by `Tests/TackroomKitTests/ArchitectureBoundaryTests.swift`:
1. `TackroomKit` never imports UI/macOS frameworks (`SwiftUI`, `AppKit`, `QuickLook`, `Observation`, `UniformTypeIdentifiers`, `CoreServices`).
2. `tackroom` CLI stays read-only and propose-only (`ProposalQueue().submit`); never mutate skills or call `Operations.execute`.
3. Only `Sources/TackroomKit/Paths.swift` reads the real home directory; all other code uses `Paths.home` or `Paths.expand` so `TACKROOM_HOME` isolation holds.
4. All user mutations go through `Plan` preview and explicit confirmation in `TackroomApp`.

## Standard Commands

- `./scripts/check.sh` — primary gate: `swift build`, parallel `swift test`, and zero-missing localization check (auto-sets Xcode `DEVELOPER_DIR` when CommandLineTools is active).
- `./scripts/build-app.sh` — builds locally signed `build/Tackroom.app`.
- `./scripts/verify-loaded.sh` — compares Tackroom inventory with real agent loaders.
- `./scripts/verify-mcp.sh` — compares Tackroom MCP overview with real agent configs.

## Localization Rules

- Traditional Chinese (`zh-Hant`) string literals are both source text and localization keys via `L(...)`.
- `./scripts/check.sh` fails if `zh-Hans` or `en` has any missing translation.

## Verification & Workflow

- Runtime verification skill: `.agents/skills/verify-tackroom/SKILL.md`
- Control CLI: `scripts/verify-tackroom.sh` (`doctor`, `seed`, `cli`, `snapshot`, `inspect`, `cleanup`) using isolated `TACKROOM_VERIFY_DIR` / `TACKROOM_HOME`.
- Feature Map: `docs/features/README.md` (update it alongside `scripts/verify-tackroom.sh` whenever user-facing flows change).
- Concurrency/state changes: when modifying async sync, journal recovery, or multi-actor proposal races, document state transitions and invariants first and add concurrency tests.
- Before review: remove redundant/obvious comments, keep prose concise, and prove user-facing behavior against the real built binary in isolated mode rather than relying on unit tests alone.
