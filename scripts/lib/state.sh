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

finding_file() {
  local id="$1"
  printf '%s/%s.json' "$(findings_dir)" "$id"
}

finding_next_id() {
  local prefix="$1"
  mkdir -p "$(findings_dir)"
  local n=0
  for f in "$(findings_dir)"/"$prefix"-*.json; do
    [ -f "$f" ] || continue
    local id="${f##*/}"
    id="${id%.json}"
    local num="${id#"$prefix"-}"
    num="${num#0}"; num="${num#0}"; num="${num#0}"
    [ -n "$num" ] && [ "$num" -gt "$n" ] 2>/dev/null && n=$num
  done
  printf '%s-%04d' "$prefix" "$((n+1))"
}

finding_create() {
  # usage: finding_create <module> <category> <severity> <title> <file> <line> <description> [code_snippet]
  local module="$1" category="$2" severity="$3" title="$4" file="$5" line="$6" desc="$7" snippet="${8:-}"
  local prefix
  case "$module" in
    security) prefix="SEC" ;;
    accessibility) prefix="A11Y" ;;
    performance) prefix="PERF" ;;
    *) prefix="GEN" ;;
  esac
  local id; id="$(finding_next_id "$prefix")"
  local now; now="$(date -u +%FT%TZ)"
  mkdir -p "$(findings_dir)"
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
    }' > "$(finding_file "$id")"
  printf '%s' "$id"
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
  local now; now="$(date -u +%FT%TZ)"
  local tmp; tmp="$(mktemp)"
  jq --arg s "$new_status" --arg at "$now" --arg note "$note" \
    '.status = $s | .history += [{at: $at, to: $s, note: $note}]' \
    "$f" > "$tmp" && mv "$tmp" "$f"
}

finding_set_field() {
  # usage: finding_set_field <id> <top_level_key> <json_value>
  # key is a simple identifier; avoids jq filter injection.
  local id="$1" key="$2" value="$3"
  [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "finding_set_field: invalid key '$key'"
  local f; f="$(finding_file "$id")"
  local tmp; tmp="$(mktemp)"
  jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$f" > "$tmp" && mv "$tmp" "$f"
}

# pick next finding to work on, priority: highest severity, oldest first.
# only returns findings that are actionable (not terminal).
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
  jq -cn --arg at "$(date -u +%FT%TZ)" --arg e "$event" --arg fid "$fid" --arg note "$note" \
    '{at:$at, event:$e, finding_id:$fid, note:$note}' \
    >> "$(iterations_log)"
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
