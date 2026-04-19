#!/usr/bin/env bash
# Emit the shields.io-compatible status JSON for the active repo to stdout.
# Schema: the top-level fields (schemaVersion, label, message, color,
# namedLogo, cacheSeconds) are what shields.io's endpoint adapter reads;
# the `autoAudit` nested object is our own metadata for consumers who
# want the full picture.
#
# usage: status-json.sh
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"

s="$(stats)"
open_critical="$(printf '%s' "$s" | jq '.discovered + .triaging + .confirmed + .poc_written + .fixing + .fix_committed + .pr_opened + .reviewing + .pr_approved')"
# count by severity among OPEN findings (not merged/false_positive/failed/skipped)
open_by_sev="$(finding_list | jq '
  def is_open: .status | IN("merged","false_positive","failed","skipped") | not;
  [ .[] | select(is_open) | .severity ]
  | group_by(.)
  | map({ (.[0]): length })
  | add // {}
')"

critical="$(printf '%s' "$open_by_sev" | jq -r '.critical // 0')"
high="$(printf '%s' "$open_by_sev" | jq -r '.high // 0')"
medium="$(printf '%s' "$open_by_sev" | jq -r '.medium // 0')"
low="$(printf '%s' "$open_by_sev" | jq -r '.low // 0')"
merged="$(printf '%s' "$s" | jq -r '.merged')"
false_positive="$(printf '%s' "$s" | jq -r '.false_positive')"
total_open=$((critical + high + medium + low))

# shields.io message + colour
if [ "$critical" -gt 0 ]; then
  message="critical"
  color="red"
elif [ "$high" -gt 0 ]; then
  message="$total_open findings"
  color="orange"
elif [ "$total_open" -gt 0 ]; then
  message="$total_open findings"
  color="yellow"
else
  message="clean"
  color="brightgreen"
fi

plugin_version="$(jq -r '.version // "unknown"' "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo unknown)"

jq -n \
  --arg message "$message" \
  --arg color "$color" \
  --arg version "$plugin_version" \
  --arg scanned_at "$(date -u +%FT%TZ)" \
  --argjson critical "$critical" \
  --argjson high "$high" \
  --argjson medium "$medium" \
  --argjson low "$low" \
  --argjson merged "$merged" \
  --argjson false_positive "$false_positive" \
  --argjson total_open "$total_open" \
  '{
    schemaVersion: 1,
    label: "auto-audit",
    message: $message,
    color: $color,
    namedLogo: "github",
    logoColor: "white",
    cacheSeconds: 3600,
    autoAudit: {
      schemaVersion: 1,
      pluginVersion: $version,
      scannedAt: $scanned_at,
      findingsOpen: {
        total: $total_open,
        critical: $critical,
        high: $high,
        medium: $medium,
        low: $low
      },
      findingsResolved: {
        merged: $merged,
        falsePositive: $false_positive
      },
      pluginHomepage: "https://auto-audit.hesketh.pro"
    }
  }'
