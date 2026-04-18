#!/usr/bin/env bash
# findings crud — each finding lives in its own json file at findings/<id>.json
# valid statuses (lifecycle order):
#   discovered -> triaging -> (false_positive | confirmed)
#   confirmed  -> poc_writing -> poc_written -> fixing -> fix_committed
#   fix_committed -> pr_opened -> reviewing -> (pr_approved | pr_rejected)
#   pr_approved -> merged
#   (any) -> failed | skipped

# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/common.sh"
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/guards.sh"

finding_file() {
  local id="$1"
  printf '%s/%s.json' "$(findings_dir)" "$id"
}

# Allocate the next ID + create the finding file atomically. Holding a flock
# on the findings dir prevents two concurrent `add-findings.sh` invocations
# (e.g. initial scan + a rescan) from returning the same ID and clobbering
# each other.
_finding_next_id_unlocked() {
  local prefix="$1"
  local n=0
  local dir; dir="$(findings_dir)"
  shopt -s nullglob
  local files=("$dir"/"$prefix"-*.json)
  shopt -u nullglob
  local f
  for f in "${files[@]}"; do
    local id="${f##*/}"
    id="${id%.json}"
    local num="${id#"$prefix"-}"
    # 10# forces base-10 parsing so "0042" isn't interpreted as octal.
    num=$((10#$num))
    [ "$num" -gt "$n" ] && n=$num
  done
  printf '%s-%04d' "$prefix" "$((n+1))"
}

finding_create() {
  # usage: finding_create <module> <category> <severity> <title> <file> <line> <description> [code_snippet]
  local module="$1" category="$2" severity="$3" title="$4" file="$5" line="$6" desc="$7" snippet="${8:-}"
  local prefix
  case "$module" in
    security) prefix="SEC" ;;
    # Future modules should add their prefix here (see README "Extending
    # with a new audit module" for the contract).
    *) prefix="GEN" ;;
  esac
  local dir; dir="$(findings_dir)"
  mkdir -p "$dir"
  # Allocate id + write placeholder under flock so concurrent allocators
  # can't race to the same number.
  (
    flock -x 200
    local id now
    id="$(_finding_next_id_unlocked "$prefix")"
    now="$(date -u +%FT%TZ)"
    jq -n \
      --arg id "$id" --arg module "$module" --arg cat "$category" --arg sev "$severity" \
      --arg title "$title" --arg file "$file" --argjson line "${line:-0}" \
      --arg desc "$desc" --arg snip "$snippet" --arg now "$now" \
      '{
        id: $id, module: $module, category: $cat, severity: $sev,
        status: "discovered",
        title: $title, file: $file, line: $line,
        description: $desc, code_snippet: $snip,
        triage: null, poc: null, fix: null, pr: null, review: null, merge: null,
        discovered_at: $now,
        history: [ {at: $now, to: "discovered", note: "created"} ]
      }' > "$dir/$id.json"
    printf '%s' "$id"
  ) 200>"$dir/.id.lock"
}

finding_get() {
  local id="$1"
  cat "$(finding_file "$id")"
}

finding_list() {
  mkdir -p "$(findings_dir)"
  local d; d="$(findings_dir)"
  shopt -s nullglob
  local files=("$d"/*.json)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  jq -s '.' "${files[@]}"
}

finding_list_by_status() {
  local status="$1"
  finding_list | jq --arg s "$status" '[.[] | select(.status == $s)]'
}

finding_update_status() {
  local id="$1" new_status="$2" note="${3:-}"
  local f; f="$(finding_file "$id")"
  [ -f "$f" ] || die "finding_update_status: no such finding: $id"
  local old_status
  old_status="$(jq -r '.status // "discovered"' "$f")"
  # Mechanically reject any transition not in the allowed edge set. An
  # agent that tries to skip stages (e.g. discovered -> fix_committed) is
  # refused before its update lands.
  guard_status_transition "$old_status" "$new_status"
  local now; now="$(date -u +%FT%TZ)"
  local tmp; tmp="$(mktemp)"
  jq --arg s "$new_status" --arg at "$now" --arg note "$note" \
    '.status = $s | .history += [{at: $at, to: $s, note: $note}]' \
    "$f" > "$tmp" && mv "$tmp" "$f"
}

finding_set_field() {
  # usage: finding_set_field <id> <top_level_key> <json_value>
  # key must be a simple identifier — avoids jq filter injection.
  local id="$1" key="$2" value="$3"
  [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "finding_set_field: invalid key '$key'"
  [ -n "$value" ] || die "finding_set_field: empty value for key '$key' (would crash jq --argjson)"
  # Validate that $value parses as JSON before feeding to --argjson. If an
  # upstream helper returned an empty string on failure, fail loudly here
  # rather than letting jq die with a cryptic error.
  printf '%s' "$value" | jq -e . >/dev/null 2>&1 || die "finding_set_field: value for '$key' is not valid JSON: $value"
  local f; f="$(finding_file "$id")"
  local tmp; tmp="$(mktemp)"
  jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$f" > "$tmp" && mv "$tmp" "$f"
}

# Pick next finding to work on, priority: highest severity, oldest first.
# Returns findings that are either at an entry state (discovered, confirmed,
# poc_written, fix_committed, pr_opened, pr_rejected, pr_approved) or stuck
# at an intermediate state (triaging, poc_writing, fixing, reviewing) —
# because a crashed subagent may have left the finding at an intermediate
# status, and the tick's dispatch table recovers these back to the matching
# entry state.
finding_next_pending() {
  finding_list | jq -r '
    def rank(s): if s=="critical" then 0
      elif s=="high" then 1 elif s=="medium" then 2
      elif s=="low" then 3 else 4 end;
    [ .[] | select(.status | IN("merged","false_positive","failed","skipped") | not) ]
    | sort_by(rank(.severity), .discovered_at)
    | .[0].id // empty
  '
}

iterations_append() {
  # usage: iterations_append <event> <finding_id> <note>
  local event="$1" fid="${2:-}" note="${3:-}"
  mkdir -p "$(repo_dir)"
  local line
  line="$(jq -cn --arg at "$(date -u +%FT%TZ)" --arg e "$event" --arg fid "$fid" --arg note "$note" \
    '{at:$at, event:$e, finding_id:$fid, note:$note}')"
  iterations_append_raw "$(iterations_log)" "$line"
}

stats() {
  finding_list | jq '
    def count(s): [ .[] | select(.status==s) ] | length;
    {
      total: length,
      discovered: count("discovered"),
      triaging: count("triaging"),
      confirmed: count("confirmed"),
      false_positive: count("false_positive"),
      poc_written: count("poc_written"),
      fixing: count("fixing"),
      fix_committed: count("fix_committed"),
      pr_opened: count("pr_opened"),
      reviewing: count("reviewing"),
      pr_approved: count("pr_approved"),
      pr_rejected: count("pr_rejected"),
      merged: count("merged"),
      failed: count("failed"),
      skipped: count("skipped")
    }'
}
