---
name: audit-accessibility
description: "Stub — accessibility (a11y) audits are planned but not yet implemented. Do not invoke."
disable-model-invocation: true
allowed-tools: "Bash"
---

Emit a clear error and stop. This skill is a placeholder.

```bash
echo "audit-accessibility is a stub and not yet implemented." >&2
echo "Only 'security' is live today. See README 'Extending with a new audit module'." >&2
exit 1
```

Intended scope (not yet active):
- axe-core scan of built site
- WCAG 2.2 AA rule coverage: alt text, heading order, form labels, colour contrast, focus management, aria-* misuse
- keyboard-nav path validation
- manual heuristics for common react-quality patterns

Add your implementation here following the same shape as `audit-security/SKILL.md`.
