#!/usr/bin/env bash
# prints the next actionable finding's json (or empty if queue is done)
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"

id="$(finding_next_pending)"
if [ -z "$id" ]; then
  echo ""
  exit 0
fi
finding_get "$id"
