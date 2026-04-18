#!/usr/bin/env bash
# git + gh helpers for auto-audit. Uses whatever auth gh + git already have
# configured in the environment (typically: gh's HTTPS oauth token, or an
# ssh-agent reachable via SSH_AUTH_SOCK if the user pushes over SSH).
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/common.sh"

ensure_clone() {
  # usage: ensure_clone <repo_url> [branch]
  local url="$1" branch="${2:-}"
  local slug; slug="$(slugify "$url")"
  local ws; ws="$AUTO_AUDIT_DATA/repos/$slug/workspace"
  if [ ! -d "$ws/.git" ]; then
    log "cloning $url -> $ws"
    mkdir -p "$(dirname "$ws")"
    # --no-recurse-submodules: a hostile repo must not trick us into fetching
    # arbitrary submodule urls during clone.
    git clone --no-recurse-submodules "$url" "$ws" 1>&2
    # Strip any repo-local identity the cloned repo may have baked in. The
    # fixer must commit as the machine's globally configured user, not
    # whatever the target repo put in .git/config.
    git -C "$ws" config --unset-all user.name 2>/dev/null || true
    git -C "$ws" config --unset-all user.email 2>/dev/null || true
    git -C "$ws" config --unset-all user.signingkey 2>/dev/null || true
  fi
  if [ -n "$branch" ]; then
    git -C "$ws" fetch origin "$branch":"$branch" 2>/dev/null || true
    git -C "$ws" checkout "$branch" 1>&2
  fi
  # always refresh the default branch
  local default
  default="$(git -C "$ws" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  [ -z "$default" ] && default="$(git -C "$ws" rev-parse --abbrev-ref HEAD)"
  git -C "$ws" fetch origin 1>&2
  git -C "$ws" checkout "$default" 1>&2
  git -C "$ws" reset --hard "origin/$default" 1>&2
  printf '%s' "$slug"
}

default_branch() {
  local ws; ws="$(workspace_dir)"
  local b
  b="$(git -C "$ws" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  [ -n "$b" ] || b="$(git -C "$ws" rev-parse --abbrev-ref HEAD)"
  printf '%s' "$b"
}

new_branch() {
  # usage: new_branch <finding_id>
  local fid="$1"
  local ws; ws="$(workspace_dir)"
  local base; base="$(default_branch)"
  local branch="autoaudit/${fid,,}"
  git -C "$ws" fetch origin "$base" 1>&2
  git -C "$ws" checkout "$base" 1>&2
  git -C "$ws" reset --hard "origin/$base" 1>&2
  # delete any prior local branch from a previous attempt
  git -C "$ws" branch -D "$branch" 2>/dev/null || true
  git -C "$ws" checkout -b "$branch" 1>&2
  printf '%s' "$branch"
}

commit_all() {
  # usage: commit_all <finding_id> <subject> [body]
  local fid="$1" subject="$2" body="${3:-}"
  local ws; ws="$(workspace_dir)"
  # Safety: must be on an autoaudit/* branch. Never add/commit while on the
  # default branch — the fixer role card enforces this too, but belt-and-braces.
  local cur; cur="$(git -C "$ws" rev-parse --abbrev-ref HEAD)"
  [[ "$cur" == autoaudit/* ]] || die "commit_all: refusing to commit on non-autoaudit branch '$cur'"
  git -C "$ws" add -A 1>&2
  if git -C "$ws" diff --cached --quiet; then
    err "nothing to commit for $fid"
    return 2
  fi
  local full
  if [ -n "$body" ]; then
    full="${subject}"$'\n\n'"${body}"
  else
    full="$subject"
  fi
  git -C "$ws" commit -m "$full" 1>&2
  git -C "$ws" rev-parse HEAD
}

push_branch() {
  # usage: push_branch <branch>
  # Refuses to push anything outside the autoaudit/* namespace. This is a
  # hard guarantee the plugin never touches main/develop/etc., even if a
  # corrupted finding JSON somehow puts an attacker-chosen branch name in
  # .fix.branch.
  local branch="$1"
  [[ "$branch" == autoaudit/* ]] || die "push_branch: refusing to push non-autoaudit branch '$branch'"
  local ws; ws="$(workspace_dir)"
  # --force-with-lease is safe on autoaudit/* branches (plugin owns them);
  # it prevents overwriting someone else's push if the ref moved since we fetched.
  git -C "$ws" push -u origin "$branch" --force-with-lease 1>&2
}

pr_open() {
  # usage: pr_open <branch> <title> <body_file>
  # Idempotent: if a PR already exists for <branch> (any state), return it
  # instead of trying to create a duplicate. This matters because a crash
  # between `gh pr create` succeeding and the state write leaves the finding
  # at status `fix_committed` with a PR already on the branch; a retry would
  # otherwise hit `gh pr create` and fail permanently.
  local branch="$1" title="$2" body_file="$3"
  local ws; ws="$(workspace_dir)"
  [ -f "$body_file" ] || die "pr_open: body file missing: $body_file"
  local existing
  existing="$(cd "$ws" && gh pr list --head "$branch" --state all --json url,number --jq '.[0] // empty' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    log "pr_open: reusing existing PR for $branch"
    printf '%s' "$existing"
    return 0
  fi
  local url
  url="$(cd "$ws" && gh pr create --head "$branch" --title "$title" --body-file "$body_file" 2>&1 | tail -1)"
  # gh pr create prints the PR URL on success. If the URL isn't present,
  # surface the error rather than letting the caller pass an empty value
  # into jq --argjson (which would crash).
  case "$url" in
    https://github.com/*/pull/*) ;;
    *) die "pr_open: unexpected gh output: $url" ;;
  esac
  (cd "$ws" && gh pr view "$url" --json url,number --jq '{url, number}')
}

pr_view() {
  # usage: pr_view <number>
  local n="$1"
  local ws; ws="$(workspace_dir)"
  (cd "$ws" && gh pr view "$n" --json number,state,title,body,headRefName,baseRefName,mergeable,url,reviewDecision)
}

pr_merge() {
  # usage: pr_merge <number> [--squash|--merge|--rebase]
  local n="$1" strat="${2:---squash}"
  local ws; ws="$(workspace_dir)"
  (cd "$ws" && gh pr merge "$n" "$strat" --delete-branch)
}

pr_close() {
  local n="$1" reason="${2:-abandoned}"
  local ws; ws="$(workspace_dir)"
  (cd "$ws" && gh pr close "$n" --comment "auto-audit: $reason" --delete-branch)
}

repo_describe() {
  # returns json describing the remote repo (name, default branch, visibility, languages, stars)
  local ws; ws="$(workspace_dir)"
  (cd "$ws" && gh repo view --json nameWithOwner,defaultBranchRef,visibility,languages,stargazerCount)
}
