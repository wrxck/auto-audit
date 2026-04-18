---
name: audit-performance
description: "Stub — performance audits are planned but not yet implemented. Do not invoke."
disable-model-invocation: true
allowed-tools: "Bash"
---

Emit a clear error and stop. This skill is a placeholder.

```bash
echo "audit-performance is a stub and not yet implemented." >&2
echo "Only 'security' is live today. See README 'Extending with a new audit module'." >&2
exit 1
```

Intended scope (not yet active):
- Lighthouse perf budget checks (LCP, CLS, INP, TBT)
- bundle size analysis via webpack-bundle-analyzer or next/bundle-analyzer
- N+1 query detection in ORMs
- react-specific: missing memoisation, oversized re-renders, unbounded effects
- node backend: missing connection pooling, sync IO in hot paths

Add your implementation here following the same shape as `audit-security/SKILL.md`.
