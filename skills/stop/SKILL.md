---
name: stop
description: "Halt the autonomous audit loop. Drops the active-repo pointer so ticks become no-ops, and advises the user to press Esc to cancel the running /loop. Use when the user says 'stop auto-audit', 'halt the audit', 'cancel'."
allowed-tools: "Bash"
---

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
if [ -f "$AUTO_AUDIT_DATA/active.json" ]; then
  mv "$AUTO_AUDIT_DATA/active.json" "$AUTO_AUDIT_DATA/active.json.stopped.$(date +%s)"
  echo "active-repo pointer removed; ticks are now no-ops."
else
  echo "no active audit."
fi
echo
echo "to cancel the running loop, press Esc in the main chat."
echo "state is preserved at $AUTO_AUDIT_DATA/repos/ — you can resume later with /auto-audit:resume."
```
