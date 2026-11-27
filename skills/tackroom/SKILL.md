---
name: tackroom
description: Look up which skills each agent on this Mac has, and propose installing, enabling, disabling or removing skills through Tackroom. Use when the user asks you to add, change or remove a skill, or asks which skills are installed. Never edit skill folders directly.
---

# Working with skills through Tackroom

The user manages agent skills with Tackroom. You can look things up and make
proposals. **You cannot change skills yourself**: the user approves every
change in the Tackroom app. Do not create, edit, move or delete files in skill
folders (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`,
`~/.gemini/config/skills`, `~/.dsh/skills`, or a project's `.claude/skills`,
`.agents/skills`, `.dsh/skills`) even if you have permission to.

## Look things up

```bash
tackroom list --json                 # every agent's skills and whether they load
tackroom status <skill> --json       # where one skill lives, who uses it, managed or not
tackroom list --project <folder>     # including a project's own skills
```

## Propose a change

Always say who you are with `--as` (your agent id) and why with `--reason`,
in one plain sentence the user will read.

```bash
tackroom propose install <owner/repo | github URL | local folder> [--skill <name>] --for claude-code --for codex [--project <folder>] --as <you> --reason "..."
tackroom propose enable <skill> --for <agent> --as <you> --reason "..."
tackroom propose disable <skill> --for <agent> --as <you> --reason "..."
tackroom propose remove <skill> [--project <folder>] --as <you> --reason "..."
tackroom propose adopt <skill> --as <you> --reason "..."
```

Agent ids: `claude-code`, `codex`, `antigravity`, `deepseek`, `opencode`,
`gemini-cli`, `cursor`, and (read-only, do not propose for them) `copilot`, `devin`.

After proposing, tell the user a proposal is waiting in Tackroom (Agent 請求)
and what it does. Check the result later with:

```bash
tackroom proposals --json            # pending / approved / rejected / failed
```

If a proposal was rejected, do not resubmit it unless the user asks.
