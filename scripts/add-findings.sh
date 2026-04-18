#!/usr/bin/env bash
# reads a json array of findings from stdin and creates them.
# each element: {module, category, severity, title, file, line, description, code_snippet}
# prints the new ids, one per line.
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"

input="$(cat)"
[ -n "$input" ] || { err "no json on stdin"; exit 1; }

# validate it's an array
echo "$input" | jq -e 'type == "array"' >/dev/null || die "stdin must be a json array"

count="$(echo "$input" | jq 'length')"
log "adding $count findings"

echo "$input" | jq -c '.[]' | while IFS= read -r row; do
  mod="$(echo "$row" | jq -r '.module')"
  cat="$(echo "$row" | jq -r '.category // "unknown"')"
  sev="$(echo "$row" | jq -r '.severity // "medium"')"
  title="$(echo "$row" | jq -r '.title')"
  # normalise severity to the plugin's enum. npm audit uses 'moderate';
  # other scanners sometimes use 'info'/'warning'. anything unknown maps
  # to medium but we log loudly so the user sees the scanner's mistake.
  case "$sev" in
    moderate) sev="medium" ;;
    info|warning) sev="low" ;;
    low|medium|high|critical) ;;
    *) err "unknown severity '$sev' for '$title' — mapping to medium"; sev="medium" ;;
  esac
  file="$(echo "$row" | jq -r '.file // ""')"
  line="$(echo "$row" | jq -r '.line // 0')"
  desc="$(echo "$row" | jq -r '.description // ""')"
  snip="$(echo "$row" | jq -r '.code_snippet // ""')"

  # dedupe: skip if an identical (file,line,title) already exists
  existing_id="$(finding_list | jq -r --arg f "$file" --argjson l "$line" --arg t "$title" \
    '[.[] | select(.file==$f and .line==$l and .title==$t)] | .[0].id // ""')"
  if [ -n "$existing_id" ]; then
    log "skip duplicate $existing_id: $title @ $file:$line"
    continue
  fi

  id="$(finding_create "$mod" "$cat" "$sev" "$title" "$file" "$line" "$desc" "$snip")"
  iterations_append "finding_added" "$id" "$sev $cat"
  printf '%s\n' "$id"
done
