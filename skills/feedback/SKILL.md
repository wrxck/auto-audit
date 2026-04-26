---
name: feedback
description: "Record operator feedback against the active repo's audit so future triager and fixer runs incorporate it. Use when the user says 'don't write that pattern again', 'I reverted that PR because X', 'the triager got this one wrong', or 'remember this for next time'. The reviewer is independent and does NOT read this log — that's deliberate."
argument-hint: "<kind> <note> [json-extra]"
allowed-tools: "Bash"
---

## Record operator feedback

Append a single line to `${repo_dir}/feedback.jsonl`. The triager and fixer subagents read this file on each future tick and weigh past entries when forming their verdicts and fixes. The reviewer **does not** read it — its independence is the safety net.

## Allowed kinds

| Kind | When to use |
|---|---|
| `fix_pattern_rejected` | "Don't ever use this pattern on this repo again." Example: regex-based HTML sanitisation in a project where DOMParser allowlist is the agreed approach. |
| `fix_pattern_approved` | "Keep using this pattern when this class of finding comes up." Example: SHA3-256 hash-then-compare in this codebase, even if alternatives look superficially shorter. |
| `human_revert` | A previously-merged auto-audit PR was manually reverted because it broke something. Include the finding_id and PR number in the json-extra ref. |
| `triage_override` | The triager's verdict was wrong and a human reversed it. The next triage on a similar finding should weigh this. |
| `reviewer_disagreed` | The reviewer approved a fix the human later decided was wrong (or vice versa). Generic flag for "the LLM-layer review was off here". |
| `note` | Free-form context that doesn't fit the others. Avoid over-using; specific kinds are more useful for the agents. |

## Form

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-feedback.sh" "$1" "$2" "${3:-{}}"
```

Where `$1` is the kind, `$2` is the human-readable note, and `$3` (optional) is extra structured JSON. Common shapes for `$3`:

```json
{"ref": {"finding_id": "SEC-0042", "pr_number": 79}}
{"ref": {"category": "xss"}, "pattern": "regex sanitiser", "preferred": "DOMParser allowlist"}
```

After recording:

1. Show the user the appended line so they can confirm it's correct.
2. Tell them the entry will affect future triager and fixer runs on this repo (not the reviewer — independence is preserved).

## Reviewer-blindness invariant

This is the same rule that keeps `.triage` and `.fix.diff_summary` out of the PR body. The reviewer must not see operator preferences any more than it sees the fixer's reasoning, otherwise the independent-review checkpoint becomes "the reviewer agrees with the operator", which is not what we want. The reviewer's role card says explicitly: do not read `feedback.jsonl`. The fixer and triager role cards say explicitly: do read it.
