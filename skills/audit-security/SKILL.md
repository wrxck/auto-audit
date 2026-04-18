---
name: audit-security
description: "Scan the active auto-audit workspace for security vulnerabilities and add any new findings to the queue. Run as part of /auto-audit:start or periodically via /auto-audit:tick rescans. Uses LLM-based code review plus available CLI scanners (npm audit, pip-audit, gitleaks-like regexes)."
allowed-tools: "Bash Read Glob Grep"
---

# Security audit module

You are performing a **security-focused** audit of the repo at the active auto-audit workspace. Your output is a **JSON array of findings** that gets fed to `add-findings.sh`, which dedupes and persists them.

## Setup

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/state.sh"

WORKSPACE="$(workspace_dir)"
cd "$WORKSPACE"
```

## Phase A — recon

Detect the stack with a few cheap checks (in parallel via a single bash call where possible):

- `test -f package.json && jq -r .name package.json`
- `test -f requirements.txt || test -f pyproject.toml`
- `test -f go.mod`
- `test -f composer.json`
- `test -f Gemfile`
- `test -f Cargo.toml`
- look for Dockerfile, compose file
- `git log --oneline -20` for recent activity

Record what you find in one short paragraph and choose which scanners apply.

## Phase B — automated scanners (fast, high-signal)

Run the scanners that apply. For each, capture output and convert to findings.

### Node/npm
```bash
if [ -f package.json ]; then
  npm audit --json 2>/dev/null || true
fi
```

Parse the output. Each advisory with severity `high` or `critical` becomes a finding:
- `module: "security"`
- `category: "dependency-cve"`
- `severity`: map npm's level to the plugin's enum — **`moderate` → `medium`**; `low`, `high`, `critical` pass through unchanged. The plugin does not recognise `moderate` and will rank it last if emitted raw.
- `title`: `"Vulnerable dependency: <name>@<range> — <cve>"`
- `file: "package.json"`, `line: 0`
- `description`: include the advisory URL + recommended range

### Python
```bash
if command -v pip-audit >/dev/null && [ -f requirements.txt -o -f pyproject.toml ]; then
  pip-audit --format json 2>/dev/null || true
fi
```

Same mapping.

### Secret scan (use the Grep tool, not bash grep)

Raw `grep -r` over the workspace is blocked on some hosts by secret-leak hooks. Use the **Grep tool** directly — it runs ripgrep under the hood, faster, safer. Run each pattern as its own Grep call with `path: $(workspace_dir)`, `output_mode: "content"`, and a `glob` that excludes the usual vendored dirs.

Patterns to check (run each as a separate Grep call):

- `AKIA[0-9A-Z]{16}` — AWS access key id
- `ghp_[A-Za-z0-9]{36}` — GitHub personal access token
- `gho_[A-Za-z0-9]{36}` — GitHub oauth token
- `sk-ant-[A-Za-z0-9_-]{20,}` — Anthropic api key
- `xox[baprs]-[A-Za-z0-9-]{10,}` — Slack token
- `-----BEGIN (RSA\|OPENSSH\|EC\|DSA) PRIVATE KEY-----` — private key pem

Any hit becomes a `critical`/`secrets` finding. Exclude obvious fakes: placeholders in `*.example`, `*.sample`, test fixtures, and the well-known `AKIAIOSFODNN7EXAMPLE` placeholder from AWS docs.

## Phase C — LLM code review (the meat)

This is where real bugs come from. Proceed in **batches** to keep per-prompt context manageable.

### C.1 — enumerate high-risk files

Use Glob to find files by category, bounded to reasonable sizes (skip huge generated files):

- **Routes / HTTP handlers**: `**/routes/**`, `**/controllers/**`, `**/api/**`, `**/handlers/**`, `**/pages/api/**` (Next.js), `**/app/**/route.{ts,js}` (Next.js app router)
- **Auth / session / token**: files matching `auth|session|token|jwt|passport|login|signin|signup|register|password|oauth`
- **Database / query**: files matching `db|database|query|repo|repository|dao|model|schema|migrations|sql`
- **Crypto / signing**: files matching `crypto|hash|encrypt|decrypt|sign|verify|keypair|secret`
- **Templating / rendering**: files matching `template|render|view|html` (XSS risk)
- **File upload / fs**: files matching `upload|file|fs|download|export|import`
- **Deserialization**: files matching `parse|deserial|unmarshal|yaml\.load|pickle\.load`
- **Shell / exec**: any file using `exec`, `spawn`, `child_process`, `subprocess.call`, `os.system`, `eval`, `Function(`, `setTimeout(string)`

Glob each pattern, filter to files < 1500 lines and not in `node_modules|vendor|dist|build|.next|target`. Collect into buckets.

### C.2 — review in batches

For each bucket, pick up to ~10 files. Read them with parallel `Read` tool calls (one file_path per call — issue them in a single turn so they run concurrently). For each file, look for the **bug classes relevant to that bucket**:

| Bucket | Bug classes to look for |
|---|---|
| Routes | Missing auth, IDOR, mass assignment, SSRF, open redirect, prototype pollution, rate-limit gaps |
| Auth | Weak session config, missing csrf, insecure cookie flags, timing attacks on compare, password policy, OAuth state missing, JWT alg=none/none confusion, refresh-token replay |
| Database | SQLi (string-concat queries), unparameterised raw queries, ORM misuse (findOne w/ user input as full filter), missing tenant isolation, TOCTOU |
| Crypto | Weak algo (MD5/SHA1 for auth, ECB), hardcoded keys/IVs, `Math.random()` for secrets, missing HMAC verification, predictable tokens |
| Templating | Unescaped user input (dangerouslySetInnerHTML, v-html, {{{ }}}, safe filters), template injection |
| Upload/FS | Path traversal (../), untrusted zipfile extraction (zip-slip), unrestricted file type, symlink attacks |
| Deserialization | Unsafe YAML/pickle/java-serialization, prototype pollution via Object.assign/merge, XXE |
| Shell/exec | Command injection (user input in shell string), unsafe `eval`, VM2/node vm escape patterns |

Be specific. For each real vulnerability, extract:
- exact file path (relative to workspace)
- line number (best you can)
- ~10 line code snippet
- one-sentence title
- 2-4 sentence description explaining **data flow**: where untrusted input enters, how it reaches the sink, and what an attacker could do

**Prefer recall over precision.** Emit a finding whenever you can trace a plausible path from untrusted input to a dangerous sink — the triage subagent later will reject anything not truly exploitable. Skip a finding only when you can already describe why it is not reachable; do not sit on borderline cases.

### C.3 — emit findings

After each batch, write out an array of findings to a temp file, then append:

```bash
FINDINGS_TMP="$(mktemp --suffix=.json)"
cat > "$FINDINGS_TMP" <<'JSON'
[
  {
    "module": "security",
    "category": "injection",
    "severity": "high",
    "title": "SQL injection in search endpoint",
    "file": "src/routes/search.ts",
    "line": 42,
    "description": "The `q` query parameter is concatenated directly into a raw SQL string on line 42. An attacker can append `' OR 1=1 --` to dump arbitrary rows. No parameterisation, no allowlist.",
    "code_snippet": "const rows = await db.query(`SELECT * FROM items WHERE name LIKE '%${req.query.q}%'`);"
  }
]
JSON
bash "${CLAUDE_PLUGIN_ROOT}/scripts/add-findings.sh" < "$FINDINGS_TMP"
rm -f "$FINDINGS_TMP"
```

The script dedupes against existing findings (same file+line+title).

## Phase D — wrap up

The orchestrator (`/auto-audit:start` or the tick rescan) requires the **last line of stdout** to be `findings_added=<integer>`. Count what was actually added by diffing `stats.discovered` before and after the scan, or just count the lines `add-findings.sh` emitted (one id per added finding). Emit the summary for humans above that contract line:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/state.sh"
echo "security scan complete: $(stats | jq -c .)"
echo "findings_added=${ADDED_COUNT:-0}"
```

Keep `$ADDED_COUNT` tracked across the batches in Phase C (accumulate the number of non-blank lines returned from each `add-findings.sh` invocation).

## Bounds

- Hard stop after reviewing **60 files** across all buckets in one scan.
- If a file is over 1500 lines, skip it — the signal/token ratio is bad.
- Prioritise buckets in this order: auth, routes, database, shell, deserialization, crypto, templating, upload.
- Never read files over 300kb.
- Resumable scans (via a `scan-cursor.json`) are a roadmap item; this version re-scans from scratch each rescan and relies on `add-findings.sh` to dedupe.
