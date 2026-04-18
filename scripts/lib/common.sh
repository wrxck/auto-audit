#!/usr/bin/env bash
# common env + helpers for auto-audit
# source this from any script: source "$(dirname "$0")/lib/common.sh"
set -euo pipefail

# claude_plugin_data falls back to the legacy path if that directory already
# exists (so existing installs keep finding their state), otherwise xdg.
_auto_audit_default_data() {
  local legacy="$HOME/.claude/plugins/data/auto-audit"
  if [ -d "$legacy" ]; then
    printf '%s' "$legacy"
  else
    printf '%s/claude/auto-audit' "${XDG_DATA_HOME:-$HOME/.local/share}"
  fi
}
: "${CLAUDE_PLUGIN_DATA:=$(_auto_audit_default_data)}"
: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

export AUTO_AUDIT_DATA="$CLAUDE_PLUGIN_DATA"
export AUTO_AUDIT_ROOT="$CLAUDE_PLUGIN_ROOT"
mkdir -p "$AUTO_AUDIT_DATA/repos"

# Git pushes use whatever credentials gh/git already have configured. The
# plugin does not manage an ssh-agent for you. If you push over HTTPS (the
# default for `gh auth login`), nothing extra is needed. If you push over
# SSH, make sure SSH_AUTH_SOCK is set in your shell before invoking Claude
# Code so child processes inherit it.

log()  { printf '[auto-audit %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
err()  { printf '[auto-audit ERROR] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Dependency check with platform-aware install hints. If something is
# missing, tell the user exactly how to install it on macOS / Debian /
# Fedora / Arch / Alpine — no guessing required.
_install_hint() {
  local pkg="$1" brew="${2:-$pkg}" apt="${3:-$pkg}" dnf="${4:-$pkg}" pacman="${5:-$pkg}" apk="${6:-$pkg}"
  cat >&2 <<HINT
  macOS (Homebrew):  brew install $brew
  Debian / Ubuntu:   sudo apt-get update && sudo apt-get install -y $apt
  Fedora / RHEL:     sudo dnf install -y $dnf
  Arch:              sudo pacman -S --needed $pacman
  Alpine:            sudo apk add --no-cache $apk
HINT
}
need() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  err "missing required command: $cmd"
  case "$cmd" in
    jq)  _install_hint jq ;;
    git) _install_hint git ;;
    gh)  _install_hint gh gh gh gh github-cli github-cli
         err "after installing, run:  gh auth login   (choose GitHub.com + HTTPS + browser)" ;;
    flock)
         err "flock(1) is part of util-linux."
         cat >&2 <<HINT
  macOS:             brew install util-linux   # then add to your shell rc:
                     export PATH="\$(brew --prefix util-linux)/sbin:\$PATH"
  Debian / Ubuntu:   already installed with util-linux (apt-get install util-linux)
  Fedora / RHEL:     sudo dnf install -y util-linux
  Arch:              already installed with util-linux
  Alpine:            sudo apk add --no-cache util-linux-misc
HINT
         ;;
    *)   err "install '$cmd' using your system's package manager." ;;
  esac
  exit 1
}
need jq
need git
need gh
need flock

# Portable timestamp -> epoch. GNU date supports `date -d`, BSD/macOS needs
# `date -j -f <fmt>`. Feed an ISO-8601-ish "%FT%TZ" string.
iso_to_epoch() {
  local ts="$1"
  # Try GNU first; fall back to BSD. Echo 0 if both fail (caller decides).
  date -u -d "$ts" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || echo 0
}

# gh must also be authenticated. Check once per process rather than on
# every source — AUTO_AUDIT_GH_AUTH_OK is a cheap in-process cache.
if [ -z "${AUTO_AUDIT_GH_AUTH_OK:-}" ]; then
  if ! gh auth status >/dev/null 2>&1; then
    err "gh is installed but not authenticated."
    err "run:  gh auth login   (choose GitHub.com, HTTPS, authenticate via browser)"
    exit 1
  fi
  export AUTO_AUDIT_GH_AUTH_OK=1
fi

# repo slug from url: owner/name -> owner--name
# Accepts:
#   https://github.com/owner/name(.git)?
#   git@github.com:owner/name(.git)?
#   owner/name   (shorthand — caller should have already prefixed https://github.com/)
# Rejects anything else so path-traversal and non-github URLs cannot slip through.
slugify() {
  local url="$1"
  local path=""
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    git@github.com:*)     path="${url#git@github.com:}" ;;
    *)
      die "refusing non-GitHub URL: $url (expected https://github.com/owner/name or git@github.com:owner/name)" ;;
  esac
  path="${path%.git}"
  path="${path%/}"
  # must be exactly owner/name — one slash, no dots, no traversal
  case "$path" in
    */*/*|*..*|*/|/*|"") die "malformed GitHub repo path: '$path'" ;;
    */*)                 ;;
    *)                   die "malformed GitHub repo path: '$path' (expected owner/name)" ;;
  esac
  printf '%s' "${path//\//--}"
}

# Resolve the slug to operate on. Prefers AUTO_AUDIT_SLUG (pinned by the
# tick at entry) over active.json — this prevents a concurrent
# /auto-audit:start from redirecting shared-helper writes to a different
# repo mid-tick.
active_slug() {
  if [ -n "${AUTO_AUDIT_SLUG:-}" ]; then
    printf '%s' "$AUTO_AUDIT_SLUG"
    return 0
  fi
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
  local slug="${1:?lock_file: slug required}"
  printf '%s/repos/%s/tick.lock' "$AUTO_AUDIT_DATA" "$slug"
}

# Atomic, non-blocking tick lock using flock(1). Exits immediately if another
# tick on the same slug is running. Stale locks caused by a hard-killed
# process are released by the kernel when the holder's fd closes — no manual
# staleness timer, no check-then-write race.
with_lock() {
  local slug="${1:?with_lock: slug required}"
  local lock; lock="$(lock_file "$slug")"
  mkdir -p "$(dirname "$lock")"
  # Open fd 9 on the lock file and flock it non-blocking. If someone else
  # holds it, exit 0 so the tick is a no-op (the next /loop iteration will
  # try again). Dying with a non-zero status would make /loop back off too
  # aggressively and miss legitimate work.
  exec 9>"$lock"
  if ! flock -n 9; then
    log "tick lock held by another process on slug=$slug — skipping"
    exit 0
  fi
  printf 'pid=%s slug=%s started=%s\n' "$$" "$slug" "$(date -u +%FT%TZ)" >&9
  # fd 9 stays open for the life of this process; flock releases on exit.
  export AUTO_AUDIT_SLUG="$slug"
}

# Serialised append to iterations.jsonl so concurrent writers don't
# interleave half-lines. Cheap flock on a sidecar; no coordination needed
# beyond the one call site.
iterations_append_raw() {
  local path="$1" line="$2"
  mkdir -p "$(dirname "$path")"
  (
    flock -x 200
    printf '%s\n' "$line" >> "$path"
  ) 200>"$path.lock"
}
