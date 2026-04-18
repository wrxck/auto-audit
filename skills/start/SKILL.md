---
name: start
description: "Autonomously audit a GitHub repo. Clones the repo, runs a full audit scan (security by default), then kicks off a continuous loop that triages findings, writes proofs of concept, fixes issues in PRs, independently reviews, and merges. Use when the user says things like 'audit my repo', 'scan repo X for security issues', 'start auto-audit on <repo>'."
argument-hint: "<repo-url> [modules=security] [merge-policy=auto|manual]"
allowed-tools: "Bash Read Edit Write Glob Grep Agent"
---

# /auto-audit:start — bootstrap the autonomous auditor

You are the orchestrator. Your job is to **set up** the audit then **kick off** a self-sustaining loop that will run until the session ends or the user stops it.

## Arguments

- `$1` (required): GitHub repo URL — e.g. `https://github.com/wrxck/my-app` or `git@github.com:wrxck/my-app.git` or `owner/name` shorthand.
- `$2` (optional, default `security`): comma-separated modules to run. Today only `security` is implemented. Future: `accessibility`, `performance`.
- `$3` (optional, default `auto`): merge policy. `auto` = auto-merge on positive independent review. `manual` = leave PR open for human review.

If `$1` is missing, tell the user the usage and stop.

## Phase 1 — bootstrap

Run the init script to clone the repo and write config. The script uses whatever git/`gh` credentials are already configured in the environment — typically the HTTPS oauth token from `gh auth login`. No extra ssh-agent setup is required.

```bash
REPO_URL="$1"
# normalise shorthand owner/name -> full url
if [[ "$REPO_URL" != *://* && "$REPO_URL" != git@* ]]; then
  REPO_URL="https://github.com/$REPO_URL"
fi
MODULES="${2:-security}"
MERGE_POLICY="${3:-auto}"

# only security is implemented today; reject others loudly so the user does
# not think a stub module is doing something.
IFS=',' read -r -a _mods <<<"$MODULES"
for m in "${_mods[@]}"; do
  case "$m" in
    security) ;;
    accessibility|performance)
      echo "module '$m' is a stub and not yet implemented — drop it or use 'security' only." >&2
      exit 1 ;;
    *) echo "unknown module '$m'; valid: security" >&2; exit 1 ;;
  esac
done

bash "${CLAUDE_PLUGIN_ROOT}/scripts/init-workspace.sh" "$REPO_URL" "$MODULES" "$MERGE_POLICY"
```

Report the config back to the user in one short line (repo + modules + merge policy).

## Phase 2 — initial scan

Only `audit-security` is active today. Invoke it as a subagent so the heavy scanning does not pollute your context.

Resolve the workspace path in your own bash first, then call the Agent tool:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
WORKSPACE="$(workspace_dir)"
echo "dispatching audit-security on $WORKSPACE"
```

Then use the `Agent` tool with `subagent_type: general-purpose` and this prompt verbatim (substitute `<WORKSPACE>` and `<PLUGIN_ROOT>` with the resolved values):

> You are running the audit-security scan of the auto-audit plugin.
> Read `<PLUGIN_ROOT>/skills/audit-security/SKILL.md` and follow it exactly.
> Active workspace: `<WORKSPACE>`.
> Plugin root: `<PLUGIN_ROOT>`.
> The LAST line of your stdout must be: `findings_added=<integer>`.

Then show the user the breakdown via:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/print-status.sh"
```

## Phase 3 — start the loop

Kick off the continuous processor. Use `/loop` with **dynamic pacing** so Claude self-paces based on how much work remains. The loop invokes the `tick` skill, which processes one finding per iteration.

Output this literal text to the user (it will be auto-interpreted by Claude Code as the loop command):

```
/loop /auto-audit:tick
```

Then tell the user in one line: "autonomous audit running — `/auto-audit:status` to check progress, `/auto-audit:stop` to halt."

## Safety

- Never run the init if the user didn't supply a repo URL.
- If `gh auth status` fails, report it and stop — don't try to proceed.
- Never commit or push here; that's the tick skill's job.
- Do not make up or invent a repo URL — require user input.
