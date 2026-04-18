#!/usr/bin/env bash
# common env + helpers for auto-audit
# source this from any script: source "$(dirname "$0")/lib/common.sh"
set -euo pipefail

: "${CLAUDE_PLUGIN_DATA:=$HOME/.claude/plugins/data/auto-audit}"
: "${CLAUDE_PLUGIN_ROOT:=$HOME/auto-audit}"

export AUTO_AUDIT_DATA="$CLAUDE_PLUGIN_DATA"
export AUTO_AUDIT_ROOT="$CLAUDE_PLUGIN_ROOT"
mkdir -p "$AUTO_AUDIT_DATA/repos"

# SSH agent — required for github pushes (see ~/.claude startup hook)
if [ -S /tmp/fleet-ssh-agent.sock ]; then
  export SSH_AUTH_SOCK=/tmp/fleet-ssh-agent.sock
fi

log()  { printf '[auto-audit %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
err()  { printf '[auto-audit ERROR] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need() { command -v "$1" >/dev/null || die "missing dep: $1"; }
need jq
need git
need gh

# repo slug from url: owner/name -> owner--name
slugify() {
  local url="$1"
  # strip protocol + .git
  url="${url#https://github.com/}"
  url="${url#git@github.com:}"
  url="${url%.git}"
  printf '%s' "${url//\//--}"
}

active_slug() {
  local f="$AUTO_AUDIT_DATA/active.json"
  [ -f "$f" ] || { err "no active repo; run /auto-audit:start <repo>"; return 1; }
  jq -r '.slug' "$f"
}

set_active_slug() {
  local slug="$1"
  printf '{"slug":"%s","set_at":"%s"}\n' "$slug" "$(date -u +%FT%TZ)" \
    > "$AUTO_AUDIT_DATA/active.json"
}

repo_dir() {
  local slug="${1:-$(active_slug)}"
  printf '%s/repos/%s' "$AUTO_AUDIT_DATA" "$slug"
}

workspace_dir() {
  printf '%s/workspace' "$(repo_dir "$@")"
}

findings_dir() {
  printf '%s/findings' "$(repo_dir "$@")"
}

config_file() {
  printf '%s/config.json' "$(repo_dir "$@")"
}

iterations_log() {
  printf '%s/iterations.jsonl' "$(repo_dir "$@")"
}

lock_file() {
  # pass the slug explicitly so the lock path is stable for the whole tick,
  # even if active.json is overwritten mid-run by a concurrent start.
  local slug="${1:?lock_file: slug required}"
  printf '%s/repos/%s/tick.lock' "$AUTO_AUDIT_DATA" "$slug"
}

with_lock() {
  # usage: with_lock <slug>
  local slug="${1:?with_lock: slug required}"
  local lock; lock="$(lock_file "$slug")"
  if [ -f "$lock" ]; then
    local age_s=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || echo 0) ))
    if [ "$age_s" -lt 900 ]; then
      die "lock held ($(cat "$lock" 2>/dev/null)); another tick in progress. Wait or delete $lock after verifying."
    fi
    log "stale lock ($age_s s old) — taking over"
    rm -f "$lock"
  fi
  printf 'pid=%s slug=%s started=%s\n' "$$" "$slug" "$(date -u +%FT%TZ)" > "$lock"
  trap 'rm -f '"'$lock'" EXIT
}
