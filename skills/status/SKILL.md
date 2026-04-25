---
name: status
description: "Show the current state of the autonomous audit: active repo, findings breakdown by status, recent activity, next pending finding. Use when the user asks 'what's auto-audit doing?', 'audit status', 'audit progress'."
argument-hint: "[--all | <slug>]"
allowed-tools: "Bash"
---

Pass-through to `print-status.sh`. Three forms:

- no args → status of the active repo
- `<slug>` → status of a specific repo (which may not be the active one)
- `--all` → one-line summary of every repo this plugin has ever initialised

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/print-status.sh" "$@"
```

If the script exits non-zero with "no active repo", tell the user to run `/auto-audit:start <repo-url>` first or pass an explicit slug.
