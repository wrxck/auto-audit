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
