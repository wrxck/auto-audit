#!/usr/bin/env bash
# Smoke test for every guard in lib/guards.sh.
#
# Each case either (a) confirms a legitimate input passes, or (b)
# confirms an illegitimate input is rejected with exit != 0. The test
# script itself exits 0 iff every assertion holds; any mismatch exits
# non-zero with the failing assertion printed.
#
# Run: bash scripts/test-guards.sh
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
export CLAUDE_PLUGIN_ROOT
# Use a throwaway data dir so we don't step on a real active audit.
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT
export CLAUDE_PLUGIN_DATA="$WORK_ROOT"
mkdir -p "$CLAUDE_PLUGIN_DATA/repos/test--guards/findings"
printf '{"slug":"test--guards"}\n' > "$CLAUDE_PLUGIN_DATA/active.json"

# shellcheck disable=SC1090,SC1091
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/guards.sh"

PASS=0
FAIL=0
FAILURES=()

ok()   { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  FAIL %s\n' "$1"; }

# Helper: run a guard in a subshell and record whether it exited 0 or >0.
# Usage: expect_pass "<label>" guard_name args...
expect_pass() {
  local label="$1"; shift
  if ( "$@" ) 2>/dev/null; then ok "$label"; else bad "$label (expected pass, died)"; fi
}
expect_fail() {
  local label="$1"; shift
  if ( "$@" ) 2>/dev/null; then bad "$label (expected die, passed)"; else ok "$label"; fi
}

# ---------------------------------------------------------------------------
printf '\n[guard_autoaudit_branch]\n'
expect_pass "accepts autoaudit/foo"                guard_autoaudit_branch "autoaudit/sec-0001"
expect_pass "accepts autoaudit/nested/path"        guard_autoaudit_branch "autoaudit/a/b"
expect_fail "rejects plain main"                   guard_autoaudit_branch "main"
expect_fail "rejects develop"                      guard_autoaudit_branch "develop"
expect_fail "rejects empty"                        guard_autoaudit_branch ""
expect_fail "rejects traversal"                    guard_autoaudit_branch "autoaudit/../main"

# ---------------------------------------------------------------------------
printf '\n[guard_status_transition]\n'
expect_pass "discovered->triaging"                 guard_status_transition discovered triaging
expect_pass "triaging->confirmed"                  guard_status_transition triaging confirmed
expect_pass "pr_approved->merged"                  guard_status_transition pr_approved merged
expect_pass "pr_rejected->confirmed"               guard_status_transition pr_rejected confirmed
expect_pass "recovery: triaging->discovered"       guard_status_transition triaging discovered
expect_pass "recovery: reviewing->pr_opened"       guard_status_transition reviewing pr_opened
expect_pass "self-loop idempotent"                 guard_status_transition confirmed confirmed
expect_fail "reject discovered->merged"            guard_status_transition discovered merged
expect_fail "reject confirmed->pr_opened"          guard_status_transition confirmed pr_opened
expect_fail "reject merged->anything"              guard_status_transition merged confirmed

# ---------------------------------------------------------------------------
printf '\n[guard_poc_outside_workspace]\n'
expect_pass "accepts pocs/X/file"                  guard_poc_outside_workspace "pocs/SEC-0001/exploit.py"
expect_pass "accepts nested pocs path"             guard_poc_outside_workspace "repos/foo/pocs/SEC-0001/a.md"
expect_fail "rejects workspace path"               guard_poc_outside_workspace "workspace/src/exploit.py"
expect_fail "rejects traversal"                    guard_poc_outside_workspace "pocs/SEC-0001/../workspace/x"

# ---------------------------------------------------------------------------
printf '\n[guard_poc_no_network]\n'
NET_OK="$WORK_ROOT/poc-ok.sh"
printf '#!/bin/bash\ncurl http://localhost:8080/x\n' > "$NET_OK"
expect_pass "accepts localhost"                    guard_poc_no_network "$NET_OK"

NET_LOOP="$WORK_ROOT/poc-loop.py"
printf 'import requests\nrequests.get("http://127.0.0.1/x")\n' > "$NET_LOOP"
expect_pass "accepts 127.0.0.1"                    guard_poc_no_network "$NET_LOOP"

NET_BAD="$WORK_ROOT/poc-bad.py"
printf 'import requests\nrequests.get("https://evil.example.invalid/x")\n' > "$NET_BAD"
# example.invalid is explicitly excluded; let's use a real-looking non-loopback host
printf 'import requests\nrequests.get("https://attacker-controlled.tld/x")\n' > "$NET_BAD"
expect_fail "rejects arbitrary https host"         guard_poc_no_network "$NET_BAD"

MD_POC="$WORK_ROOT/writeup.md"
printf 'Writeup. curl http://attacker.example/evil\n' > "$MD_POC"
expect_pass ".md write-ups are not scanned"        guard_poc_no_network "$MD_POC"

# ---------------------------------------------------------------------------
printf '\n[guard_not_empty / guard_valid_json]\n'
expect_pass "non-empty passes"                     guard_not_empty "x" "name"
expect_fail "empty dies"                           guard_not_empty "" "name"
expect_pass "valid json passes"                    guard_valid_json '{"a":1}' "obj"
expect_fail "invalid json dies"                    guard_valid_json "not-json" "obj"
expect_fail "empty json dies"                      guard_valid_json "" "obj"

# ---------------------------------------------------------------------------
printf '\n[guard_commit_msg_clean]\n'
expect_pass "clean subject passes"                 guard_commit_msg_clean "fix(sec): parameterise query [SEC-0001]"
expect_fail "leaks triage reasoning"               guard_commit_msg_clean "fix: x

triage reasoning: the attacker..."
expect_fail "leaks diff_summary"                   guard_commit_msg_clean "fix: x

diff_summary: 3 files changed"

# ---------------------------------------------------------------------------
printf '\n[guard_pr_body_clean]\n'
BODY_OK="$WORK_ROOT/body-ok.md"
cat > "$BODY_OK" <<'MD'
**Auto-audit finding: SEC-0001** — severity: high

### Title
Location: foo.go:42

## Description
Plain description of the issue without any reviewer-compromising context.
MD
expect_pass "clean body passes"                    guard_pr_body_clean "$BODY_OK"

BODY_LEAK="$WORK_ROOT/body-leak.md"
cat > "$BODY_LEAK" <<'MD'
## Triage
Reasoning: the attacker would...
MD
expect_fail "body with Triage section dies"        guard_pr_body_clean "$BODY_LEAK"

BODY_SHORT="$WORK_ROOT/body-short.md"
printf 'too short\n' > "$BODY_SHORT"
expect_fail "body < 80 bytes dies"                 guard_pr_body_clean "$BODY_SHORT"

# ---------------------------------------------------------------------------
# Diff-based guards need an actual git repo. Set one up.
printf '\n[guard_no_poc_in_diff / guard_max_files_changed / guard_max_lines_changed / guard_no_secrets_in_diff]\n'
REPO="$WORK_ROOT/wsrepo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email 'test@example.com'
git -C "$REPO" config user.name 'test'
printf 'initial\n' > "$REPO/README"
git -C "$REPO" add README
git -C "$REPO" commit -q -m init

# clean single-file change
printf 'line\n' >> "$REPO/README"
git -C "$REPO" add README
expect_pass "single-file edit passes"              guard_max_files_changed "$REPO" 5
expect_pass "small line count passes"              guard_max_lines_changed "$REPO" 400
expect_pass "no pocs in diff"                      guard_no_poc_in_diff "$REPO"
expect_pass "no secrets in diff"                   guard_no_secrets_in_diff "$REPO"
git -C "$REPO" reset -q HEAD README

# too many files
for i in $(seq 1 7); do printf 'x\n' > "$REPO/f$i"; done
git -C "$REPO" add "$REPO"/f*
expect_fail "7 files dies at max 5"                guard_max_files_changed "$REPO" 5
git -C "$REPO" reset -q HEAD

# poc in diff
mkdir -p "$REPO/pocs"
printf 'poc\n' > "$REPO/pocs/exploit.py"
git -C "$REPO" add "$REPO/pocs/exploit.py"
expect_fail "pocs/ path in diff dies"              guard_no_poc_in_diff "$REPO"
git -C "$REPO" reset -q HEAD
rm -rf "$REPO/pocs"

# secret in added lines
printf 'apikey = "AKIAIOSFODNN7REALKEYY"\n' > "$REPO/secret.py"
git -C "$REPO" add "$REPO/secret.py"
expect_fail "AKIA-looking secret added dies"       guard_no_secrets_in_diff "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/secret.py"

# ---------------------------------------------------------------------------
# guard_no_timing_unsafe_regression: dies if the fix introduces a plain
# equality operator on a credential-ish variable. Models tend to "fix" auth
# findings by replacing a constant-time primitive with ===/.equals, which
# creates the timing-attack vulnerability the finding was supposed to stop.
printf '\n[guard_no_timing_unsafe_regression]\n'

# unrelated change passes
printf 'export function add(a, b) { return a + b; }\n' > "$REPO/math.js"
git -C "$REPO" add "$REPO/math.js"
expect_pass "unrelated diff passes"                guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/math.js"

# safe primitive on a credential-named var passes
printf 'import crypto from "crypto";\nexport const check = (token, expected) => crypto.timingSafeEqual(Buffer.from(token), Buffer.from(expected));\n' > "$REPO/auth.js"
git -C "$REPO" add "$REPO/auth.js"
expect_pass "safe primitive on token passes"       guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/auth.js"

# variable that happens to match keyword but isn't a credential keyword passes
printf 'const count = total === 0 ? 0 : total;\n' > "$REPO/count.js"
git -C "$REPO" add "$REPO/count.js"
expect_pass "non-credential var passes"            guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/count.js"

# === on a password var dies
printf 'if (password === userInput) { return true; }\n' > "$REPO/login.js"
git -C "$REPO" add "$REPO/login.js"
expect_fail "=== on password dies"                 guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/login.js"

# == on a token var dies
printf 'if token == provided_token:\n    return True\n' > "$REPO/check.py"
git -C "$REPO" add "$REPO/check.py"
expect_fail "== on token dies"                     guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/check.py"

# Java .equals on hmac dies
printf 'if (hmac.equals(provided)) { return true; }\n' > "$REPO/Verify.java"
git -C "$REPO" add "$REPO/Verify.java"
expect_fail ".equals on hmac var dies"             guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/Verify.java"

# strcmp on a secret dies
printf 'if (strcmp(secret, input) == 0) { return 1; }\n' > "$REPO/verify.c"
git -C "$REPO" add "$REPO/verify.c"
expect_fail "strcmp on secret dies"                guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/verify.c"

# property access on a credential still caught
printf 'if (user.password === candidate) { grant(); }\n' > "$REPO/prop.js"
git -C "$REPO" add "$REPO/prop.js"
expect_fail "property password === dies"           guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/prop.js"

# signature compare dies
printf 'return signature === expectedSig;\n' > "$REPO/sig.js"
git -C "$REPO" add "$REPO/sig.js"
expect_fail "signature === dies"                   guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/sig.js"

# bearer token compare dies
printf 'if (bearer == provided) { return; }\n' > "$REPO/bearer.js"
git -C "$REPO" add "$REPO/bearer.js"
expect_fail "bearer == dies"                       guard_no_timing_unsafe_regression "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/bearer.js"

# removal of an unsafe compare does NOT trigger (only added lines are scanned)
# we simulate this by first committing an unsafe compare, then removing it
printf 'if (password === input) return 1;\n' > "$REPO/old.js"
git -C "$REPO" add "$REPO/old.js"
git -C "$REPO" commit -q -m 'old unsafe compare'
git -C "$REPO" rm -q "$REPO/old.js"
expect_pass "removing unsafe line passes (only + scanned)"  guard_no_timing_unsafe_regression "$REPO"
# drop both the staged deletion and the seed commit so later tests start clean
git -C "$REPO" reset -q --hard HEAD~1

# ---------------------------------------------------------------------------
# guard_no_safe_primitive_removal: a fix that deletes a known safe comparison
# primitive (crypto.timingSafeEqual, hmac.compare_digest, etc.) without
# replacing it with another safe primitive in the same file dies.
printf '\n[guard_no_safe_primitive_removal]\n'

# seed a file with a safe primitive call on the target repo
printf 'import crypto from "crypto";\nexport const check = (a, b) => crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));\n' > "$REPO/hsafe.js"
git -C "$REPO" add "$REPO/hsafe.js"
git -C "$REPO" commit -q -m 'seed: safe primitive'

# diff that preserves the primitive (unrelated edit) passes
printf 'import crypto from "crypto";\nexport const check = (a, b) => crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));\n// keepalive\n' > "$REPO/hsafe.js"
git -C "$REPO" add "$REPO/hsafe.js"
expect_pass "unrelated edit preserves primitive"   guard_no_safe_primitive_removal "$REPO"
git -C "$REPO" reset -q HEAD
git -C "$REPO" checkout -q -- "$REPO/hsafe.js"

# diff that removes timingSafeEqual entirely dies
printf 'export const check = (a, b) => a === b;\n' > "$REPO/hsafe.js"
git -C "$REPO" add "$REPO/hsafe.js"
expect_fail "removing timingSafeEqual dies"        guard_no_safe_primitive_removal "$REPO"
git -C "$REPO" reset -q HEAD
git -C "$REPO" checkout -q -- "$REPO/hsafe.js"

# diff that refactors around the safe primitive but keeps one call passes.
# Models sometimes restructure the import / wrapper without removing the
# primitive call itself — that's fine.
printf 'import { timingSafeEqual } from "crypto";\nexport const check = (a, b) => timingSafeEqual(Buffer.from(a), Buffer.from(b));\n' > "$REPO/hsafe.js"
git -C "$REPO" add "$REPO/hsafe.js"
expect_pass "refactor keeps timingSafeEqual call passes"  guard_no_safe_primitive_removal "$REPO"
git -C "$REPO" reset -q HEAD
git -C "$REPO" checkout -q -- "$REPO/hsafe.js"

# python: seed hmac.compare_digest then remove it -> dies
printf 'import hmac\ndef verify(a, b):\n    return hmac.compare_digest(a, b)\n' > "$REPO/v.py"
git -C "$REPO" add "$REPO/v.py"
git -C "$REPO" commit -q -m 'seed: py safe primitive'
printf 'def verify(a, b):\n    return a == b\n' > "$REPO/v.py"
git -C "$REPO" add "$REPO/v.py"
expect_fail "removing hmac.compare_digest dies"    guard_no_safe_primitive_removal "$REPO"
git -C "$REPO" reset -q HEAD
git -C "$REPO" checkout -q -- "$REPO/v.py"

# go: seed subtle.ConstantTimeCompare then remove -> dies
printf 'package x\nimport "crypto/subtle"\nfunc Check(a, b []byte) bool {\n  return subtle.ConstantTimeCompare(a, b) == 1\n}\n' > "$REPO/c.go"
git -C "$REPO" add "$REPO/c.go"
git -C "$REPO" commit -q -m 'seed: go safe primitive'
printf 'package x\nfunc Check(a, b []byte) bool {\n  return string(a) == string(b)\n}\n' > "$REPO/c.go"
git -C "$REPO" add "$REPO/c.go"
expect_fail "removing ConstantTimeCompare dies"    guard_no_safe_primitive_removal "$REPO"
git -C "$REPO" reset -q HEAD
git -C "$REPO" checkout -q -- "$REPO/c.go"

# java: seed MessageDigest.isEqual then remove -> dies
printf 'import java.security.MessageDigest;\nclass V { static boolean v(byte[] a, byte[] b) { return MessageDigest.isEqual(a, b); } }\n' > "$REPO/V.java"
git -C "$REPO" add "$REPO/V.java"
git -C "$REPO" commit -q -m 'seed: java safe primitive'
printf 'class V { static boolean v(byte[] a, byte[] b) { return java.util.Arrays.equals(a, b); } }\n' > "$REPO/V.java"
git -C "$REPO" add "$REPO/V.java"
expect_fail "removing MessageDigest.isEqual dies"  guard_no_safe_primitive_removal "$REPO"
git -C "$REPO" reset -q HEAD
git -C "$REPO" checkout -q -- "$REPO/V.java"

# ruby: seed ActiveSupport::SecurityUtils.secure_compare then remove -> dies
printf "require 'active_support/security_utils'\ndef v(a, b)\n  ActiveSupport::SecurityUtils.secure_compare(a, b)\nend\n" > "$REPO/v.rb"
git -C "$REPO" add "$REPO/v.rb"
git -C "$REPO" commit -q -m 'seed: ruby safe primitive'
printf "def v(a, b)\n  a == b\nend\n" > "$REPO/v.rb"
git -C "$REPO" add "$REPO/v.rb"
expect_fail "removing secure_compare dies"         guard_no_safe_primitive_removal "$REPO"
git -C "$REPO" reset -q HEAD
git -C "$REPO" checkout -q -- "$REPO/v.rb"

# ---------------------------------------------------------------------------
printf '\n---\n'
if [ "$FAIL" -eq 0 ]; then
  printf 'test-guards: %d passed, 0 failed\n' "$PASS"
  exit 0
else
  printf 'test-guards: %d passed, %d FAILED\n' "$PASS" "$FAIL"
  for msg in "${FAILURES[@]}"; do printf '  - %s\n' "$msg"; done
  exit 1
fi
