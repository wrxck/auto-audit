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

# Detect findings stuck in an intermediate stage (the previous loop died
# mid-tick) and fold them back to the matching entry status so the next
# tick picks them up cleanly. The tick already does this lazily on
# pickup; doing it eagerly here gives the resume command a clear signal
# of how much state was recovered.
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/state.sh"
recovered=0
findings_dir="$AUTO_AUDIT_DATA/repos/$SLUG/findings"
if [ -d "$findings_dir" ]; then
  for f in "$findings_dir"/*.json; do
    [ -f "$f" ] || continue
    fid="$(jq -r .id "$f")"
    status="$(jq -r .status "$f")"
    case "$status" in
      triaging)    finding_update_status "$fid" "discovered"  "resume: recovering from interrupted triage";    recovered=$((recovered+1)) ;;
      poc_writing) finding_update_status "$fid" "confirmed"   "resume: recovering from interrupted poc";       recovered=$((recovered+1)) ;;
      fixing)      finding_update_status "$fid" "poc_written" "resume: recovering from interrupted fix";       recovered=$((recovered+1)) ;;
      reviewing)   finding_update_status "$fid" "pr_opened"   "resume: recovering from interrupted review";    recovered=$((recovered+1)) ;;
    esac
  done
fi
if [ "$recovered" -gt 0 ]; then
  echo "recovered $recovered finding(s) stuck mid-tick"
fi

bash "$CLAUDE_PLUGIN_ROOT/scripts/print-status.sh"
```

Then tell the user "resumed. run `/loop /auto-audit:tick` to restart the autonomous processor, or just wait for the next tick if a loop is already running." If you recovered any stuck findings, mention the count so the user knows the loop didn't lose progress silently.
