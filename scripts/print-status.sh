#!/usr/bin/env bash
# human-readable status dump.
# usage: print-status.sh                    # active repo only
#        print-status.sh <slug>             # specific repo
#        print-status.sh --all              # one-line summary for every audited repo
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"

if [ "${1:-}" = "--all" ]; then
  active="$(active_slug 2>/dev/null || echo '')"
  echo "=== auto-audit repos (active: ${active:-none}) ==="
  if [ ! -d "$AUTO_AUDIT_DATA/repos" ] || [ -z "$(ls -A "$AUTO_AUDIT_DATA/repos" 2>/dev/null)" ]; then
    echo "(no repos initialised)"
    exit 0
  fi
  printf '%-30s %-10s %s\n' "slug" "merged" "url"
  # set +e for the loop body so a single broken repo dir doesn't kill the listing.
  set +e
  for d in "$AUTO_AUDIT_DATA"/repos/*/; do
    s="$(basename "$d")"
    [ -f "$d/config.json" ] || continue
    url="$(jq -r '.url // "?"' "$d/config.json" 2>/dev/null || echo '?')"
    merged=0
    total=0
    if [ -d "$d/findings" ]; then
      for fj in "$d"/findings/*.json; do
        [ -f "$fj" ] || continue
        total=$((total+1))
        st="$(jq -r .status "$fj" 2>/dev/null || echo unknown)"
        [ "$st" = "merged" ] && merged=$((merged+1))
      done
    fi
    marker=" "
    [ "$s" = "$active" ] && marker="*"
    printf '%s %-29s %4d/%-5d %s\n' "$marker" "$s" "$merged" "$total" "$url"
  done
  set -e
  exit 0
fi

if [ -n "${1:-}" ]; then
  slug="$1"
  [ -d "$AUTO_AUDIT_DATA/repos/$slug" ] || { echo "no such repo: $slug" >&2; exit 1; }
else
  slug="$(active_slug)" || exit 1
fi
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
