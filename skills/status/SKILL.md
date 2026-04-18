---
name: status
description: "Show the current state of the autonomous audit: active repo, findings breakdown by status, recent activity, next pending finding. Use when the user asks 'what's auto-audit doing?', 'audit status', 'audit progress'."
allowed-tools: "Bash"
---

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/print-status.sh"
```

If the script exits non-zero with "no active repo", tell the user to run `/auto-audit:start <repo-url>` first.
