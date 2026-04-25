#!/usr/bin/env bash
# Repoint the installed_plugins.json entry for auto-audit at the highest
# version directory present in its plugin-cache directory. Use this after
# the marketplace bumps to pick up the new release in the live session
# without restarting Claude Code or hand-editing the JSON.
#
# Why this exists: Claude Code resolves the plugin's installPath from
# `~/.claude/plugins/installed_plugins.json` at session start. When the
# marketplace publishes a new version the cache picks it up but the
# installed-plugins pointer stays at whatever version was active when the
# session started. Editing that file by hand is fiddly; this script
# automates it.
#
# Usage:
#   bash scripts/refresh-installed.sh              # auto-audit, default scopes
#   bash scripts/refresh-installed.sh /custom/path # override CLAUDE_PLUGIN_DATA root
#
# Safe: only edits the auto-audit@wrxck-claude-plugins entry. Other
# plugins in installed_plugins.json are untouched. Operates on user-scope
# unless the entry was installed at a different scope.
set -euo pipefail

PLUGIN_KEY="auto-audit@wrxck-claude-plugins"
ROOT="${1:-${HOME}/.claude/plugins}"
INSTALLED="${ROOT}/installed_plugins.json"
CACHE_DIR="${ROOT}/cache/wrxck-claude-plugins/auto-audit"

[ -f "$INSTALLED" ] || { echo "no installed_plugins.json at $INSTALLED" >&2; exit 1; }
[ -d "$CACHE_DIR" ] || { echo "no plugin cache at $CACHE_DIR" >&2; exit 1; }

# pick the highest-version directory: collect, sort by version segments,
# take the tail. Skip anything that isn't a semver-shaped directory name.
LATEST="$(
  find "$CACHE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V \
  | tail -n1
)"
[ -n "$LATEST" ] || { echo "no semver directories under $CACHE_DIR" >&2; exit 1; }

LATEST_PATH="${CACHE_DIR}/${LATEST}"
NOW="$(date -u +%FT%TZ)"

CURRENT="$(jq -r --arg k "$PLUGIN_KEY" '.plugins[$k][0].version // empty' "$INSTALLED")"
if [ "$CURRENT" = "$LATEST" ]; then
  echo "$PLUGIN_KEY already at $LATEST"
  exit 0
fi

# atomic swap via tmp file
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
jq --arg k "$PLUGIN_KEY" --arg v "$LATEST" --arg p "$LATEST_PATH" --arg now "$NOW" \
  '.plugins[$k][0].installPath = $p
 | .plugins[$k][0].version = $v
 | .plugins[$k][0].lastUpdated = $now' \
  "$INSTALLED" > "$TMP"
mv "$TMP" "$INSTALLED"
trap - EXIT

echo "${PLUGIN_KEY}: ${CURRENT:-unset} -> $LATEST"
echo "installPath: $LATEST_PATH"
