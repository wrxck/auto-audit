#!/usr/bin/env bash
# git + gh helpers. always sets ssh_auth_sock for github pushes.
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
    # strip any repo-local identity the cloned repo may have baked in. the
    # fixer must commit as the machine's configured user, not whatever the
    # target repo put in .git/config.
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
  local branch="$1"
  local ws; ws="$(workspace_dir)"
  [ -S "${SSH_AUTH_SOCK:-}" ] || die "SSH_AUTH_SOCK not set; push will fail. See CLAUDE.md ssh agent notes."
  git -C "$ws" push -u origin "$branch" --force-with-lease 1>&2
}

pr_open() {
  # usage: pr_open <branch> <title> <body_file>
  local branch="$1" title="$2" body_file="$3"
  local ws; ws="$(workspace_dir)"
  (cd "$ws" && gh pr create --head "$branch" --title "$title" --body-file "$body_file" --json url,number --jq '{url, number}')
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
