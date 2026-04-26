#!/usr/bin/env bash
# Per-repo operator-feedback log. Append-only JSONL at
# ${repo_dir}/feedback.jsonl. Records human-supplied signal that should
# influence the triager and fixer's future runs on the same repo:
# - human_revert        : a previously-merged auto-audit PR was reverted
#                          (manually noted; auto-detection is a follow-up)
# - triage_override     : human flipped a triage verdict after the fact
# - fix_pattern_rejected: an architectural pattern the operator does not
#                          want the fixer to use again on this repo
# - fix_pattern_approved: an architectural pattern the operator wants the
#                          fixer to keep using on this repo
# - reviewer_disagreed  : the reviewer approved a fix the human later
#                          decided was wrong (or vice versa)
# - note                : free-form operator note
#
# Independence note: the reviewer subagent must NOT read this file. Its
# role card says so explicitly. Threading operator feedback to the
# reviewer would bias the independent-review checkpoint, which is the
# whole point of having a separate reviewer in the first place. The
# triager and fixer DO read it, because their job is to learn from
# operator preference; the reviewer's job is to catch regressions
# regardless of preference.

# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/common.sh"

feedback_file() {
  local slug="${1:-$(active_slug)}"
  printf '%s/feedback.jsonl' "$(repo_dir "$slug")"
}

# usage: feedback_record <kind> <note> [json-extra]
# Appends a single JSON line. The kind is validated against the allowed
# set; arbitrary kinds are rejected so the file stays machine-readable.
feedback_record() {
  local kind="$1" note="$2" extra="${3:-}"
  # Bash quirk: ${var:-{}} swallows a closing brace. Two-step default
  # avoids it.
  [ -z "$extra" ] && extra='{}'
  case "$kind" in
    human_revert|triage_override|fix_pattern_rejected|fix_pattern_approved|reviewer_disagreed|note) ;;
    *) die "feedback_record: unknown kind '$kind' (allowed: human_revert, triage_override, fix_pattern_rejected, fix_pattern_approved, reviewer_disagreed, note)" ;;
  esac
  guard_valid_json "$extra" "feedback extra"
  local f; f="$(feedback_file)"
  mkdir -p "$(dirname "$f")"
  jq -nc \
    --arg at "$(date -u +%FT%TZ)" \
    --arg kind "$kind" \
    --arg note "$note" \
    --argjson extra "$extra" \
    '{at:$at, kind:$kind, note:$note} + $extra' \
    >> "$f"
}

# Render a markdown-style summary of the last N entries for inclusion in
# triager / fixer prompts. Empty output if no feedback yet.
feedback_summary() {
  local slug="${1:-$(active_slug)}"
  local n="${2:-50}"
  local f; f="$(feedback_file "$slug")"
  [ -f "$f" ] || { printf ''; return 0; }
  tail -n "$n" "$f" | jq -r '
    "- [\(.at | sub("T.*Z$"; ""))] \(.kind): \(.note)" +
    (if .ref then " (ref: \(.ref | tojson))" else "" end)
  ' 2>/dev/null
}
