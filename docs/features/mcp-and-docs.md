# MCP and docs

MCP and docs give the user a read-only overview of configured MCP servers (without exposing secret values) and allow viewing or editing agent instruction files such as `CLAUDE.md`.

## Sub-features

- `mcp-cli` lists configured MCP servers per agent while masking secret values (`tackroom mcp list --json`).
- `mcp-ui` renders the `MCP` page in `TackroomApp`.
- `docs-ui` renders the `文件` page listing global and project instruction files.

## How to get to it (user POV)

- Select `MCP` in the `TackroomApp` sidebar.
- Select `文件` in the `TackroomApp` sidebar to browse and edit instruction files.
- Run `tackroom mcp list [--project <folder>] [--json]` in a terminal.

## Driving it with scripts/verify-tackroom.sh

Preconditions:

- `./scripts/verify-tackroom.sh doctor` passes and `seed` has run.
- `$TACKROOM_VERIFY_DIR/home/.claude.json` defines `demo-mcp` and `$TACKROOM_VERIFY_DIR/home/.claude/CLAUDE.md` exists.

- **List MCP servers safely.** Query MCP inventory as JSON. Run `./scripts/verify-tackroom.sh cli -- mcp list --json`. Exit code `0` and stdout includes `"name": "demo-mcp"` for `"agent": "claude-code"` with `"variables": ["DEMO_TOKEN"]` and zero secret values.
- **Render MCP view.** Capture the MCP tab. Run `./scripts/verify-tackroom.sh snapshot "$TACKROOM_VERIFY_DIR/artifacts/mcp-and-docs/mcp.png" -- -selectMCP 1 -appearance light`. `sips` reports valid PNG dimensions.
- **Render Docs view.** Capture the Docs tab. Run `./scripts/verify-tackroom.sh snapshot "$TACKROOM_VERIFY_DIR/artifacts/mcp-and-docs/docs.png" -- -selectDocs 1 -appearance light`. `sips` reports valid PNG dimensions.

## Gotchas

- `MCPInventory` flags hardcoded credentials in `plaintext_secrets` by key name only; never place real tokens in seeded test fixtures.
- Project-scoped MCP servers require passing `--project <folder>` to `tackroom mcp list`.
