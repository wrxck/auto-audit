---
name: resume
description: "Resume a stopped or previously-interrupted autonomous audit without re-initialising the workspace. Re-establishes the active repo pointer and kicks off the loop again. Use when the user says 'resume auto-audit', 'continue the audit', or after a session restart."
argument-hint: "[repo-slug]"
allowed-tools: "Bash"
---

## Resume the autonomous audit

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"

SLUG="$1"

# if no slug given, see if there's a stopped active file or exactly one repo in data
if [ -z "$SLUG" ]; then
  if ls "$AUTO_AUDIT_DATA"/active.json.stopped.* >/dev/null 2>&1; then
    LATEST="$(ls -t "$AUTO_AUDIT_DATA"/active.json.stopped.* | head -1)"
    SLUG="$(jq -r .slug "$LATEST")"
  elif [ "$(ls "$AUTO_AUDIT_DATA/repos" 2>/dev/null | wc -l)" = "1" ]; then
    SLUG="$(ls "$AUTO_AUDIT_DATA/repos" | head -1)"
  fi
fi

if [ -z "$SLUG" ]; then
  echo "no slug given and could not infer one. available repos:"
  ls "$AUTO_AUDIT_DATA/repos" 2>/dev/null || echo "  (none)"
  exit 1
fi

if [ ! -d "$AUTO_AUDIT_DATA/repos/$SLUG" ]; then
  echo "no such repo: $SLUG"
  exit 1
fi

set_active_slug "$SLUG"
echo "resumed: $SLUG"
bash "$CLAUDE_PLUGIN_ROOT/scripts/print-status.sh"
```

Then tell the user "resumed. run `/loop /auto-audit:tick` to restart the autonomous processor, or just wait for the next tick if a loop is already running."
