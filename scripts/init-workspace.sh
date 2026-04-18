#!/usr/bin/env bash
# usage: init-workspace.sh <repo_url> [modules_csv=security] [merge_policy=auto|manual]
# sets up workspace, config, and marks repo active.
set -euo pipefail
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/common.sh"
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/git.sh"

url="${1:-}"
modules="${2:-security}"
merge_policy="${3:-manual}"

[ -n "$url" ] || die "usage: init-workspace.sh <repo_url> [modules] [merge_policy]"
case "$merge_policy" in auto|manual) ;; *) die "merge_policy must be auto|manual, got $merge_policy" ;; esac

# verify auth + that repo is reachable
gh auth status >/dev/null 2>&1 || die "gh not authenticated. run: gh auth login"

slug="$(slugify "$url")"

# reject slugs with path-traversal components (defence in depth — github urls
# should never contain these, but someone might pipe in a non-github url).
case "$slug" in
  *..*|*/*|"") die "refusing suspicious slug '$slug' — is this a github url?" ;;
esac

# block a concurrent start: if there is already an active audit on a different
# repo, stop and tell the user to finish or /auto-audit:stop first.
if [ -f "$AUTO_AUDIT_DATA/active.json" ]; then
  existing="$(jq -r '.slug' "$AUTO_AUDIT_DATA/active.json" 2>/dev/null || echo '')"
  if [ -n "$existing" ] && [ "$existing" != "$slug" ]; then
    die "active audit already running on '$existing'. run /auto-audit:stop first, or /auto-audit:resume $existing to continue it."
  fi
fi

log "initialising workspace for $url (slug=$slug, modules=$modules, merge=$merge_policy)"

ensure_clone "$url" >/dev/null

# confirm access via api
if ! (cd "$AUTO_AUDIT_DATA/repos/$slug/workspace" && gh repo view >/dev/null 2>&1); then
  die "cannot access repo $url via gh — check perms"
fi

mkdir -p "$AUTO_AUDIT_DATA/repos/$slug/findings"

jq -n \
  --arg url "$url" --arg slug "$slug" --arg modules "$modules" \
  --arg merge "$merge_policy" --arg now "$(date -u +%FT%TZ)" \
  '{
    url: $url, slug: $slug,
    modules: ($modules | split(",")),
    merge_policy: $merge,
    max_fix_iterations: 3,
    rescan_after_n_merges: 5,
    sandbox_mode: "strict",
    allow_network_for_repos: [],
    initialised_at: $now
  }' > "$AUTO_AUDIT_DATA/repos/$slug/config.json"

set_active_slug "$slug"

# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/lib/state.sh"
iterations_append "initialised" "" "repo=$url modules=$modules merge=$merge_policy"

log "workspace ready: $(repo_dir "$slug")"
jq -c . "$AUTO_AUDIT_DATA/repos/$slug/config.json"
