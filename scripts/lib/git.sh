#!/usr/bin/env bash
# git + gh helpers for auto-audit. Uses whatever auth gh + git already have
# configured in the environment (typically: gh's HTTPS oauth token, or an
# ssh-agent reachable via SSH_AUTH_SOCK if the user pushes over SSH).
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/common.sh"
# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/guards.sh"

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
  # ${fid,,} is bash 4+ only (breaks on macOS's stock bash 3.2). tr is portable.
  local branch
  branch="autoaudit/$(printf '%s' "$fid" | tr '[:upper:]' '[:lower:]')"
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
  # Belt-and-braces: enforce every invariant before touching the index.
  local cur; cur="$(git -C "$ws" rev-parse --abbrev-ref HEAD)"
  guard_autoaudit_branch "$cur" "current HEAD"
  guard_not_default_branch "$ws"
  git -C "$ws" add -A 1>&2
  guard_diff_not_empty "$ws"
  guard_no_poc_in_diff "$ws"
  guard_no_submodule_change "$ws"
  guard_no_secrets_in_diff "$ws"
  guard_max_files_changed "$ws"
  guard_max_lines_changed "$ws"
  local full
  if [ -n "$body" ]; then
    full="${subject}"$'\n\n'"${body}"
  else
    full="$subject"
  fi
  guard_commit_msg_size "$full"
  guard_commit_msg_clean "$full"
  git -C "$ws" commit -m "$full" 1>&2
  git -C "$ws" rev-parse HEAD
}

push_branch() {
  # usage: push_branch <branch>
  local branch="$1"
  guard_autoaudit_branch "$branch" "push target"
  guard_gh_authenticated
  local ws; ws="$(workspace_dir)"
  # --force-with-lease is safe on autoaudit/* branches (plugin owns them);
  # it prevents overwriting someone else's push if the ref moved since we fetched.
  git -C "$ws" push -u origin "$branch" --force-with-lease 1>&2
}

pr_open() {
  # usage: pr_open <branch> <title> <body_file>
  # Idempotent: if a PR already exists for <branch> (any state), return it
  # instead of trying to create a duplicate.
  local branch="$1" title="$2" body_file="$3"
  guard_autoaudit_branch "$branch" "PR head"
  guard_pr_body_clean "$body_file"
  guard_gh_authenticated
  local ws; ws="$(workspace_dir)"
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
