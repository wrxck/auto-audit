#!/usr/bin/env bash
# human-readable status dump for the active repo
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"

slug="$(active_slug)" || exit 1
cfg="$(config_file "$slug")"
echo "=== auto-audit status ==="
echo "repo: $(jq -r '.url' "$cfg")"
echo "slug: $slug"
echo "modules: $(jq -r '.modules | join(",")' "$cfg")"
echo "merge_policy: $(jq -r '.merge_policy' "$cfg")"
echo "initialised: $(jq -r '.initialised_at' "$cfg")"
echo
echo "--- findings breakdown ---"
stats | jq -r 'to_entries | map("\(.key): \(.value)") | .[]'
echo
echo "--- recent iterations (last 15) ---"
if [ -f "$(iterations_log)" ]; then
  tail -n 15 "$(iterations_log)" | jq -r '"\(.at) \(.event) \(.finding_id) \(.note)"'
else
  echo "(none yet)"
fi
echo
echo "--- next pending finding ---"
next="$(finding_next_pending)"
if [ -n "$next" ]; then
  finding_get "$next" | jq -r '"\(.id) [\(.severity)/\(.status)] \(.title) (\(.file):\(.line))"'
else
  echo "(queue empty)"
fi

# Surface findings stuck in an intermediate (mid-tick) status. The tick is
# idempotent — the next /auto-audit:tick will fold these back to the
# matching entry status — but stale entries here are how a loop death is
# observable, so flag them prominently. Threshold defaults to 10 minutes;
# override with AUTO_AUDIT_STALE_SECONDS.
echo
echo "--- stale findings (>= ${AUTO_AUDIT_STALE_SECONDS:-600}s in an intermediate stage) ---"
stale_threshold="${AUTO_AUDIT_STALE_SECONDS:-600}"
now_epoch="$(date -u +%s)"
findings_dir="$AUTO_AUDIT_DATA/repos/$slug/findings"
stale_seen=0
if [ -d "$findings_dir" ]; then
  for f in "$findings_dir"/*.json; do
    [ -f "$f" ] || continue
    status="$(jq -r '.status' "$f")"
    case "$status" in triaging|poc_writing|fixing|reviewing) ;; *) continue ;; esac
    last_at="$(jq -r '.updated_at // .created_at // empty' "$f")"
    [ -n "$last_at" ] || continue
    last_epoch="$(iso_to_epoch "$last_at")"
    [ "$last_epoch" -gt 0 ] || continue
    age=$(( now_epoch - last_epoch ))
    if [ "$age" -ge "$stale_threshold" ]; then
      jq -r --arg a "${age}s" '"\(.id) [\(.severity)/\(.status)] stuck for \($a) — \(.title)"' "$f"
      stale_seen=$((stale_seen+1))
    fi
  done
fi
[ "$stale_seen" -eq 0 ] && echo "(none — loop is either healthy or idle)"
