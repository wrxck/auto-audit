#!/usr/bin/env bash
# tracks fix attempts per finding so we can abort after max_fix_iterations.
# usage:
#   finding-attempts.sh get <id>      -> prints integer
#   finding-attempts.sh inc <id>      -> increments and prints new value
#   finding-attempts.sh reset <id>    -> resets to 0
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"

cmd="${1:-}"; id="${2:-}"
[ -n "$cmd" ] && [ -n "$id" ] || die "usage: $0 get|inc|reset <id>"

f="$(finding_file "$id")"
[ -f "$f" ] || die "no such finding: $id"

cur="$(jq -r '.fix_attempts // 0' "$f")"
case "$cmd" in
  get) echo "$cur" ;;
  inc)
    new=$((cur + 1))
    tmp="$(mktemp)"
    jq --argjson n "$new" '.fix_attempts = $n' "$f" > "$tmp" && mv "$tmp" "$f"
    echo "$new"
    ;;
  reset)
    tmp="$(mktemp)"
    jq '.fix_attempts = 0' "$f" > "$tmp" && mv "$tmp" "$f"
    echo "0"
    ;;
  *) die "unknown subcommand: $cmd" ;;
esac
