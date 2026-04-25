---
name: stop
description: "Halt the autonomous audit loop. Drops the active-repo pointer so ticks become no-ops, and advises the user to press Esc to cancel the running /loop. Use when the user says 'stop auto-audit', 'halt the audit', 'cancel'."
argument-hint: "[slug]"
allowed-tools: "Bash"
---

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"

# If a slug is given and it matches the active pointer, drop the pointer.
# If a slug is given but a different one is active, leave the active
# pointer alone (this command's intent is "stop the audit on <slug>",
# which when <slug> is not active is already true). The other repo's
# state is on disk regardless and reachable via --slug arguments.
ARG_SLUG="$1"
if [ -f "$AUTO_AUDIT_DATA/active.json" ]; then
  ACTIVE="$(jq -r .slug "$AUTO_AUDIT_DATA/active.json" 2>/dev/null || echo '')"
  if [ -z "$ARG_SLUG" ] || [ "$ARG_SLUG" = "$ACTIVE" ]; then
    mv "$AUTO_AUDIT_DATA/active.json" "$AUTO_AUDIT_DATA/active.json.stopped.$(date +%s)"
    echo "active-repo pointer removed (was '$ACTIVE'); ticks are now no-ops."
  else
    echo "stop requested for '$ARG_SLUG' but active is '$ACTIVE' — active pointer left in place."
    echo "the '$ARG_SLUG' workspace state is preserved at $AUTO_AUDIT_DATA/repos/$ARG_SLUG/."
  fi
else
  echo "no active audit."
fi
echo
echo "to cancel the running loop, press Esc in the main chat."
echo "state is preserved at $AUTO_AUDIT_DATA/repos/ — you can resume later with /auto-audit:resume [slug]."
```
