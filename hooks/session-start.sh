#!/usr/bin/env bash
# sessionstart hook: if an audit is active, print a short status line so claude sees it.
set -euo pipefail

DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/auto-audit}"
[ -f "$DATA/active.json" ] || exit 0

SLUG="$(jq -r .slug "$DATA/active.json" 2>/dev/null || true)"
[ -n "$SLUG" ] || exit 0

CFG="$DATA/repos/$SLUG/config.json"
[ -f "$CFG" ] || exit 0

URL="$(jq -r .url "$CFG")"
FINDINGS_DIR="$DATA/repos/$SLUG/findings"
TOTAL="$(find "$FINDINGS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
PENDING="$(find "$FINDINGS_DIR" -maxdepth 1 -name '*.json' 2>/dev/null -exec jq -r '.status' {} \; 2>/dev/null | grep -vcE '^(merged|false_positive|failed|skipped)$' || true)"

cat <<JSON
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[auto-audit] active on $URL — $TOTAL findings total, $PENDING still pending. Run /auto-audit:status for detail, /auto-audit:resume to restart the loop, /auto-audit:stop to halt."
  }
}
JSON
