#!/usr/bin/env bash
# Record an operator feedback entry against the active repo's feedback log.
#
# Usage:
#   record-feedback.sh <kind> <note> [json-extra]
#
# Examples:
#   record-feedback.sh fix_pattern_rejected "regex sanitisers — use DOMParser allowlist"
#   record-feedback.sh human_revert "broke prod auth flow" '{"ref":{"finding_id":"SEC-0042","pr_number":79}}'
#   record-feedback.sh triage_override "this *is* reachable via the cron handler" '{"ref":{"finding_id":"SEC-0010"}}'
#
# kind ∈ { human_revert, triage_override, fix_pattern_rejected,
#          fix_pattern_approved, reviewer_disagreed, note }
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/feedback.sh"

KIND="${1:-}"
NOTE="${2:-}"
EXTRA="${3:-}"
# Bash quirk: ${var:-{}} consumes one of the closing braces. Two-step
# default avoids it; explicit {} when caller passed no extra.
[ -z "$EXTRA" ] && EXTRA='{}'

[ -n "$KIND" ] || die "usage: $0 <kind> <note> [json-extra]"
[ -n "$NOTE" ] || die "note is required"

feedback_record "$KIND" "$NOTE" "$EXTRA"
log "recorded ${KIND}: ${NOTE}"
