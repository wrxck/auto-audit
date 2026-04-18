# auto-audit

An autonomous auditor for Claude Code. Point it at a GitHub repo; it scans for security vulnerabilities, triages false positives, writes a proof of concept, fixes each confirmed bug in its own PR, independently reviews the fix, and merges when the review is clean. It keeps doing that until the queue is drained, then rescans, until you stop it or the session ends.

Modular by design: `audit-security` is the only live module today. `audit-accessibility` and `audit-performance` exist as stub skills that error out until someone fills them in — see the extension section below.

## How it works

```
1. /auto-audit:start <repo>
2. init workspace -> audit-security (subagent scans repo) -> findings queue
3. /loop /auto-audit:tick -> pick next pending finding

one lifecycle stage per tick:
    discovered      -> triaging     (security-triage subagent)
    triaging        -> confirmed or false_positive
    confirmed       -> poc_written  (poc-builder subagent)
    poc_written     -> fix_committed (security-fixer subagent; new branch, commit)
    fix_committed   -> pr_opened   (branch push + gh pr create)
    pr_opened       -> reviewing   (security-reviewer subagent, independent, no prior context)
    reviewing       -> pr_approved or pr_rejected
    pr_approved     -> merged      (gh pr merge --squash; if merge_policy=auto)
    pr_approved     -> skipped     (if merge_policy=manual; left for a human to merge)
    pr_rejected     -> confirmed   (fixer gets another go, bounded by max_fix_iterations)

tick ends after one stage; the /loop invokes it again.
```

Each tick advances exactly **one** finding by **one** stage. That makes the loop cheap to interrupt and makes the independent-review checkpoint a real checkpoint rather than theatre.

## Commands

| Command | Purpose |
|---|---|
| `/auto-audit:start <repo> [modules=security] [policy=auto\|manual]` | Clone, scan, start the loop |
| `/auto-audit:tick` | Advance one finding by one stage. Normally the `/loop` calls this for you. |
| `/auto-audit:status` | Show breakdown of findings and recent activity |
| `/auto-audit:resume [slug]` | Resume after `/auto-audit:stop` or session restart |
| `/auto-audit:stop` | Drop the active-repo pointer; press Esc to cancel the `/loop` |

## Arguments

- `repo` — GitHub URL (`https://github.com/owner/name`, `git@github.com:owner/name.git`) or shorthand `owner/name`.
- `modules` — comma-separated. Today only `security` is implemented.
- `policy`:
  - `auto` — merge each PR automatically after an independent reviewer approves.
  - `manual` — stop at `pr_approved` and mark the finding `skipped`. A human must merge.

## Design choices worth knowing

### Independent review is the load-bearing safety net

The reviewer subagent receives **only** the raw finding description and the PR diff. It does not see the triage reasoning or the fixer's notes. The point is that if the fixer rationalised a bad fix ("this filters the exploit string"), a fresh reviewer without that bias is more likely to catch it. If the reviewer rejects, the fixer gets another attempt up to `max_fix_iterations` (default 3), after which the finding is marked `failed` and the loop moves on.

### One stage per tick

Ticks are short, idempotent, and resumable. If a session dies mid-fix, the finding stays at `fixing` and the next tick retries (with the attempts counter preventing runaway retries).

### Minimal fixes or no fix

Both the fixer and the reviewer are told to insist on minimal diffs. A fix that reformats 400 lines is rejected. A fix that touches 5+ files is flagged as too large for auto-PR and the finding is marked `failed`.

### PoCs live outside the workspace

`${CLAUDE_PLUGIN_DATA}/repos/<slug>/pocs/<id>/` — deliberately outside the git workspace so a PoC file never lands in a commit. The PoC content is persisted in the finding JSON for the PR body.

### Dedupe on (file, line, title)

Findings with matching `file`, `line`, and `title` are dropped on second insert. Rescans after N merges will not spam the queue with the same items.

### State is a directory tree of JSON files

One file per finding at `${CLAUDE_PLUGIN_DATA}/repos/<slug>/findings/<id>.json`, plus an append-only `iterations.jsonl`. No database — easy to inspect, diff, or hand-edit.

## Install (local dev)

```bash
# clone or copy the plugin into a convenient path
cp -r /path/to/auto-audit ~/auto-audit  # (or wherever)

# start claude code with the plugin loaded
claude --plugin-dir ~/auto-audit
```

Confirm it is loaded:

```
/plugin list
```

You should see `auto-audit` and the five skills (`start`, `tick`, `status`, `resume`, `stop`).

## Install (as a marketplace plugin)

```
/plugin install auto-audit@<your-marketplace>
```

The plugin has no `marketplace.json` yet; publish that when ready.

## Requirements

- `gh` CLI, authenticated (`gh auth status` must succeed)
- `git`, `jq`
- A working git push path to GitHub. If you push over SSH, make sure an agent holding your GitHub key is reachable — on this author's machines that's `/tmp/fleet-ssh-agent.sock`; elsewhere the plugin just inherits whatever `SSH_AUTH_SOCK` is set in your shell.
- Write access to the target repo (so `gh pr create` and `gh pr merge` work)

## Extending with a new audit module

1. Create `skills/audit-<module>/SKILL.md`, copying the shape of `audit-security/SKILL.md`. The contract: the skill scans, builds a JSON array of findings, pipes that array into `scripts/add-findings.sh`. That's it.
2. Make sure the findings use a distinct `module` value (`"accessibility"`, `"performance"`) so the ID prefix is distinct (A11Y-xxxx, PERF-xxxx).
3. Add the module name to the `modules` argument when starting: `/auto-audit:start <repo> security,accessibility`.
4. If the module needs distinct triage/fix/review agents, add them under `agents/` and reference them in the tick skill's dispatch. The security pipeline is a reasonable default for most code-level issues.

## State layout

```
${CLAUDE_PLUGIN_DATA}/
  active.json              (which repo is currently active)
  repos/
    <slug>/                (e.g. wrxck--my-app)
      config.json          (repo url, modules, merge_policy, limits)
      workspace/           (the git clone)
      findings/
        <id>.json          (one per finding, full lifecycle state)
      pocs/
        <id>/              (poc artefacts, never committed)
      iterations.jsonl     (append-only activity log)
      scan-cursor.json     (where the last scan left off)
```

## Safety and limits

- The plugin never pushes to the default branch.
- The plugin never `--force`-pushes to anything but its own `autoaudit/*` branches (and only `--force-with-lease`).
- The plugin never runs PoCs that make live network requests or exfiltrate real secrets.
- Clones use `--no-recurse-submodules`; after clone, the plugin unsets any repo-local `user.name`, `user.email`, and `user.signingkey` so a hostile `.git/config` cannot spoof the commit author.
- Commits use your global git config; pre-commit hooks are respected (`--no-verify` is never passed).
- The fixer runs the target repo's test suite (e.g. `npm test`, `pytest`). Only point the plugin at repos whose test commands you trust — a malicious repo can run arbitrary code through its own tests.
- The fixer gives up after `max_fix_iterations` attempts on a single finding.
- Scans are bounded: 60 files per scan, files over 1500 lines are skipped, files over 300 kB are skipped.
- Concurrent starts are refused: running `/auto-audit:start` with a different repo while one is already active will error out until you `/auto-audit:stop`.

## When something goes wrong

- **`no active repo`** — run `/auto-audit:start <url>` first. If you stopped earlier, `/auto-audit:resume` will re-point to the last active repo.
- **gh push fails** — the shared `scripts/lib/common.sh` sets `SSH_AUTH_SOCK=/tmp/fleet-ssh-agent.sock` only when that socket exists; otherwise it inherits the shell's value. Verify the agent is running (`ls -l /tmp/fleet-ssh-agent.sock` or `ssh-add -l`). See the fleet notes in `~/.claude/CLAUDE.md` if you need to recreate the agent.
- **loop seems stuck** — `/auto-audit:status` to check. If a tick is mid-flight and errored, the finding will usually be left at an intermediate status; the next tick re-tries. If a finding cycles between `confirmed` and `pr_rejected` forever, it will hit `max_fix_iterations` and be marked `failed`.
- **false positive flood** — lower severity threshold in `audit-security/SKILL.md` or add regex exclusions. The LLM scanner is deliberately tuned to prefer recall over precision; the triage subagent trims aggressively.

## Roadmap (not yet built)

- Accessibility and performance modules (stubs exist)
- Web dashboard for status (today: CLI only)
- Slack webhook for merged PRs
- Configurable cost ceiling per session (spend limit)
