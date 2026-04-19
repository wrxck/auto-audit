#!/usr/bin/env bash
# Programmatic guardrails.
#
# Every claim the plugin makes about safety is enforced in two places:
#   1. An LLM-level instruction in the relevant agent role card or skill
#      prompt (tells the model *not* to do the unsafe thing)
#   2. A programmatic guard in this file (refuses, even if the model tries)
#
# The LLM layer covers judgment calls ("is this fix minimal?", "is this
# triage reasoning sound?"). The programmatic layer covers anything that
# can be mechanically checked: branch names, diff size, state-machine
# edges, keyword presence, etc. When a guard fails it exits the current
# process non-zero with a message prefixed `guard:` — callers must not
# catch and continue; a tripped guard means the invariant was violated
# and the tick should abort.

# shellcheck disable=SC1091
source "${BASH_SOURCE%/*}/common.sh"

# -- tunable limits. Override via env if your audited repos legitimately
# need larger fixes; defaults are tight on purpose.
: "${AUTO_AUDIT_MAX_FILES_CHANGED:=5}"
: "${AUTO_AUDIT_MAX_LINES_CHANGED:=400}"
: "${AUTO_AUDIT_MAX_COMMIT_MSG_BYTES:=8192}"

# -----------------------------------------------------------------------------
# branch / working-copy guards
# -----------------------------------------------------------------------------

guard_autoaudit_branch() {
  # usage: guard_autoaudit_branch <branch> [ctx]
  local branch="$1" ctx="${2:-branch}"
  [[ "$branch" == autoaudit/* ]] || die "guard: $ctx must start with 'autoaudit/' (got: '$branch')"
  # Disallow traversal or wildcard-ish names inside the autoaudit/ namespace.
  case "$branch" in
    *..*|*/./*|*' '*|*$'\t'*|*$'\n'*) die "guard: $ctx contains illegal characters: '$branch'" ;;
  esac
}

guard_not_default_branch() {
  # usage: guard_not_default_branch <workspace>
  # Refuses to operate on the target repo's default branch (main/master/etc).
  local ws="$1"
  local cur default
  cur="$(git -C "$ws" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  default="$(git -C "$ws" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  if [ -z "$default" ]; then
    # Fall back to a conservative list if origin/HEAD isn't set yet.
    case "$cur" in main|master|trunk|develop|development|default) die "guard: refusing to operate on likely-default branch '$cur'" ;; esac
    return 0
  fi
  [ "$cur" != "$default" ] || die "guard: refusing to operate on default branch '$default'"
}

# -----------------------------------------------------------------------------
# staged-diff guards (run immediately before commit)
# -----------------------------------------------------------------------------

guard_diff_not_empty() {
  local ws="$1"
  git -C "$ws" diff --cached --quiet && die "guard: nothing staged to commit"
  return 0
}

guard_max_files_changed() {
  # Counts every staged file. The fixer role card asks for a minimal diff;
  # this caps the blast radius even if the LLM misjudges "minimal".
  local ws="$1" max="${2:-$AUTO_AUDIT_MAX_FILES_CHANGED}"
  local n
  n="$(git -C "$ws" diff --cached --name-only | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$n" -le "$max" ] || die "guard: staged diff touches $n files, max is $max — fix is too broad for an auto-audit PR"
}

guard_max_lines_changed() {
  # Counts additions + deletions across the staged diff. A fix that
  # rewrites a whole file to "sanitise" something will trip this.
  local ws="$1" max="${2:-$AUTO_AUDIT_MAX_LINES_CHANGED}"
  local n
  n="$(git -C "$ws" diff --cached --numstat | awk '$1!="-"{a+=$1} $2!="-"{b+=$2} END{print a+b+0}')"
  [ "$n" -le "$max" ] || die "guard: staged diff changes $n lines, max is $max"
}

guard_no_poc_in_diff() {
  # PoC artefacts live outside the workspace, so they should never be
  # stageable. This is belt-and-braces: catches a fixer that copied a PoC
  # into the workspace by mistake.
  local ws="$1"
  local offenders
  offenders="$(git -C "$ws" diff --cached --name-only | grep -E '(^|/)pocs?(/|$)' || true)"
  [ -z "$offenders" ] || die "guard: PoC files staged for commit:
$offenders"
}

guard_no_secrets_in_diff() {
  # Scan only ADDED lines. A legitimate fix can *remove* a leaked secret
  # (e.g. deleting a hardcoded token); we do not want to block those.
  local ws="$1"
  local added pattern
  added="$(git -C "$ws" diff --cached -U0 | awk '/^\+\+\+/{next} /^\+/{print}' || true)"
  # shellcheck disable=SC2016
  pattern='AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|ghs_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN (RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY-----'
  if printf '%s' "$added" | grep -qE "$pattern"; then
    die "guard: staged diff introduces a string matching a known secret pattern — refusing commit"
  fi
}

guard_no_unhashed_credential_compare() {
  # Credential/MAC/signature comparisons must hash both sides with SHA3-256
  # before comparing. Constant-time primitives on RAW secrets (timingSafeEqual,
  # compare_digest, ConstantTimeCompare, MessageDigest.isEqual, secure_compare,
  # fixed_length_secure_compare, FixedTimeEquals, hash_equals, CRYPTO_memcmp)
  # are a known-vulnerable posture — compiler optimisations can strip the
  # constant-time property and the prefix structure of the raw secret is still
  # present for statistical timing attacks. Only hashing both inputs (SHA3-256)
  # removes the hangman-gameable prefix structure; after that any compare
  # operator is safe.
  #
  # Per-file heuristic: collect the staged diff's ADDED lines per file. If any
  # added line has both a credential-shaped identifier AND an unsafe compare
  # primitive AND the file's added lines do NOT include a SHA3-256 hash call,
  # die before the commit lands.
  local ws="$1"
  local files
  files="$(git -C "$ws" diff --cached --name-only | sed '/^$/d')"
  [ -n "$files" ] || return 0
  local cred='(password|passwd|token|secret|hmac|signature|digest|auth|session|cookie|csrf|credential|nonce|otp|bearer|apikey|api_key|api-key|pin_hash|pin_code)'
  # "unsafe compare" here now includes the old-school constant-time primitives,
  # because a constant-time compare on RAW secrets is itself the vulnerability.
  # Only hashed input makes ANY compare safe.
  local unsafe='(===|!==|[^=!]==[^=]|[^=!]!=[^=]|\.equals[[:space:]]*\(|strcmp[[:space:]]*\(|bcmp[[:space:]]*\(|memcmp[[:space:]]*\(|CRYPTO_memcmp[[:space:]]*\(|timingSafeEqual[[:space:]]*\(|compare_digest[[:space:]]*\(|ConstantTimeCompare[[:space:]]*\(|ConstantTimeEq[[:space:]]*\(|MessageDigest\.isEqual[[:space:]]*\(|secure_compare[[:space:]]*\(|fixed_length_secure_compare[[:space:]]*\(|FixedTimeEquals[[:space:]]*\(|hash_equals[[:space:]]*\()'
  # SHA3-256 call shape across languages. Case-insensitive, either separator.
  local sha3='[Ss][Hh][Aa]3[-_]256'
  local offender=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local added
    added="$(git -C "$ws" diff --cached -U0 -- "$f" | awk '/^\+\+\+/{next} /^\+/{sub(/^\+/,""); print}' || true)"
    [ -n "$added" ] || continue
    local hit
    hit="$(printf '%s\n' "$added" | grep -niE "$cred" 2>/dev/null | grep -iE "$unsafe" 2>/dev/null || true)"
    [ -n "$hit" ] || continue
    # Hit on cred+compare. The file's added lines must also include a
    # SHA3-256 hash call; otherwise the compare is operating on raw secrets.
    if ! printf '%s\n' "$added" | grep -qE "$sha3"; then
      offender="${f}:
${hit}"
      break
    fi
  done <<< "$files"
  if [ -n "$offender" ]; then
    die "guard: staged diff compares credential-shaped data without first hashing with SHA3-256.
${offender}
Hash BOTH sides with SHA3-256 before comparing. Constant-time primitives on raw secrets (timingSafeEqual, compare_digest, ConstantTimeCompare, MessageDigest.isEqual, secure_compare, fixed_length_secure_compare, FixedTimeEquals, hash_equals, CRYPTO_memcmp) are not sufficient — only hashing removes prefix structure and eliminates the hangman oracle. Wrap the compare in a named helper and keep the explanatory code comment so a future fixer does not 'optimise' it back. Full rule: skills/security-knowledge/hash-then-compare.md"
  fi
}

guard_no_submodule_change() {
  # A hostile target repo could ship a fixer trick that modifies
  # .gitmodules or a submodule pointer. Reject both.
  local ws="$1"
  local hits
  hits="$(git -C "$ws" diff --cached --name-only | grep -E '^\.gitmodules$' || true)"
  [ -z "$hits" ] || die "guard: staged diff modifies .gitmodules — refusing"
  local submod
  submod="$(git -C "$ws" diff --cached --submodule=short | grep -E '^Submodule ' || true)"
  [ -z "$submod" ] || die "guard: staged diff updates submodule pointer — refusing"
}

# -----------------------------------------------------------------------------
# commit / PR guards
# -----------------------------------------------------------------------------

guard_commit_msg_size() {
  local msg="$1" max="${2:-$AUTO_AUDIT_MAX_COMMIT_MSG_BYTES}"
  local n; n=${#msg}
  [ "$n" -le "$max" ] || die "guard: commit message is $n bytes, max is $max"
}

guard_commit_msg_clean() {
  # The commit body must not leak triage reasoning or fix-review notes.
  # The independent reviewer will see commit messages via the PR.
  local msg="$1"
  if printf '%s' "$msg" | grep -qiE '(triage reasoning|fixer reasoning|fix rationale|diff_summary|\.triage|\.fix\.)'; then
    die "guard: commit message references triage/fix reasoning — independent review would be compromised"
  fi
}

guard_pr_body_clean() {
  # Same idea as guard_commit_msg_clean but for the PR body file.
  local body_file="$1"
  [ -f "$body_file" ] || die "guard: PR body file missing: $body_file"
  if grep -qiE '(## ?Triage|## ?Fix summary|triage reasoning|fixer reasoning|diff_summary)' "$body_file"; then
    die "guard: PR body references triage/fix reasoning — independent review would be compromised"
  fi
  # Body must not be empty or template-only.
  local size; size="$(wc -c < "$body_file" | tr -d ' ')"
  [ "$size" -ge 80 ] || die "guard: PR body is suspiciously short ($size bytes)"
}

# -----------------------------------------------------------------------------
# PoC guards
# -----------------------------------------------------------------------------

guard_poc_outside_workspace() {
  # The PoC path (relative to repo_dir) must live under pocs/, not under
  # workspace/ — the latter would put a PoC into a commit.
  local poc_path="$1"
  case "$poc_path" in
    pocs/*) ;;
    */pocs/*) ;;
    *)
      die "guard: PoC path '$poc_path' is not under pocs/ — would land in a commit"
      ;;
  esac
  case "$poc_path" in
    *../*|../*|*/..|..) die "guard: PoC path '$poc_path' contains '..' traversal" ;;
  esac
}

guard_poc_no_network() {
  # Cheap static scan: reject PoC files that reference outbound network
  # primitives against non-local hosts. This is not a sandbox — a
  # determined PoC can hide calls — but it catches the obvious mistakes
  # the LLM is told not to make.
  local poc_file="$1"
  [ -f "$poc_file" ] || return 0
  case "$poc_file" in
    *.md|*.txt|*.markdown) return 0 ;;  # write-ups don't execute
  esac
  local hits
  hits="$(grep -niE 'curl[[:space:]]|wget[[:space:]]|https?://|requests\.(get|post|put|delete|patch)|fetch\(|http\.Client|net/http|axios\.|urllib|HttpClient|ClientBuilder' "$poc_file" 2>/dev/null \
    | grep -viE '(localhost|127\.0\.0\.1|0\.0\.0\.0|::1|example\.(com|org|net)|\.(test|local|invalid))' || true)"
  if [ -n "$hits" ]; then
    die "guard: PoC '$poc_file' appears to perform network I/O outside loopback/example hosts:
$hits"
  fi
}

# -----------------------------------------------------------------------------
# state-machine guard
# -----------------------------------------------------------------------------

# Allowed (from,to) edges in the finding lifecycle. Self-loops are allowed
# implicitly. Terminal statuses are merged / false_positive / failed / skipped.
_auto_audit_transitions() {
  cat <<'TABLE'
discovered     triaging
discovered     failed
discovered     skipped
triaging       confirmed
triaging       false_positive
triaging       discovered
triaging       failed
triaging       skipped
confirmed      poc_writing
confirmed      fixing
confirmed      failed
confirmed      skipped
poc_writing    poc_written
poc_writing    confirmed
poc_writing    failed
poc_writing    skipped
poc_written    fixing
poc_written    confirmed
poc_written    failed
poc_written    skipped
fixing         fix_committed
fixing         poc_written
fixing         failed
fixing         skipped
fix_committed  pr_opened
fix_committed  failed
fix_committed  skipped
pr_opened      reviewing
pr_opened      failed
pr_opened      skipped
reviewing      pr_approved
reviewing      pr_rejected
reviewing      pr_opened
reviewing      failed
reviewing      skipped
pr_approved    merged
pr_approved    skipped
pr_approved    failed
pr_rejected    confirmed
pr_rejected    failed
pr_rejected    skipped
TABLE
}

guard_status_transition() {
  # usage: guard_status_transition <from> <to>
  local from="$1" to="$2"
  [ -n "$from" ] && [ -n "$to" ] || die "guard: status transition needs both from and to"
  [ "$from" = "$to" ] && return 0  # self-loops always allowed (idempotent updates)
  local f t
  while read -r f t; do
    [ -z "$f" ] && continue
    if [ "$from" = "$f" ] && [ "$to" = "$t" ]; then
      return 0
    fi
  done < <(_auto_audit_transitions)
  die "guard: invalid status transition '$from' -> '$to' (not in allowed edge set)"
}

# -----------------------------------------------------------------------------
# generic guards
# -----------------------------------------------------------------------------

guard_not_empty() {
  local val="$1" name="$2"
  [ -n "$val" ] || die "guard: $name is empty"
}

guard_valid_json() {
  local val="$1" name="$2"
  printf '%s' "$val" | jq -e . >/dev/null 2>&1 || die "guard: $name is not valid JSON"
}

guard_gh_authenticated() {
  gh auth status >/dev/null 2>&1 || die "guard: gh is not authenticated — run 'gh auth login'"
}

guard_workspace_clean_of_untracked_dangerous() {
  # Some tests ship fixtures like .env, id_rsa etc. as part of reproducing
  # a vulnerability. Fail loudly if the workspace somehow contains
  # obviously-sensitive untracked files — the fixer should not be adding
  # these.
  local ws="$1"
  local offenders
  offenders="$(git -C "$ws" ls-files --others --exclude-standard 2>/dev/null | grep -E '(^|/)(id_[rdea]sa|\.env\.prod|\.env\.production|credentials\.json|secrets\.yml)$' || true)"
  [ -z "$offenders" ] || die "guard: dangerous untracked files present:
$offenders"
}
