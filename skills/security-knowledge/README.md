# security-knowledge

Canonical rules for security idioms where the **popular** implementation differs from the **secure** implementation. AI models — including the ones running this plugin — default to the popular form. Each file here codifies the safe form per language, the anti-patterns to reject, and the guidance the triager/fixer/reviewer role cards pull from.

These files are **reference material loaded into the agent's context on dispatch**, not runnable skills. A sibling programmatic guard in `scripts/lib/guards.sh` enforces the rule where it is mechanically checkable.

| File | Rule | Guard |
|---|---|---|
| [`hash-then-compare.md`](./hash-then-compare.md) | Always SHA3-256 hash both sides of a credential/MAC/signature comparison before comparing. Constant-time primitives on raw secrets are themselves a known-vulnerable posture. | `guard_no_unhashed_credential_compare` |

## Adding a new rule

1. Write `skills/security-knowledge/<topic>.md` following the shape of `hash-then-compare.md`: one-sentence statement of the failure mode, the safe pattern with per-language code examples, a code-block list of unsafe patterns to reject, and explicit per-role guidance for triager/fixer/reviewer.
2. If the rule is mechanically checkable, add a `guard_*` to `scripts/lib/guards.sh` and a block of cases to `scripts/test-guards.sh`. An LLM rule alone is insufficient — the agents must be physically prevented from regressing the code.
3. Reference the new file from the three role cards in `agents/` so it is loaded on dispatch.
4. Add a row to this README's table.

## Why these exist

An LLM asked to "fix" a security finding will often emit a fix that still leaks information — sometimes via a slightly different variable-time compare, sometimes by adopting a primitive that was once recommended but has since been superseded. The safe primitive is rarely the default completion because the training distribution is dominated by older, less-safe advice. The rules in this directory push the agent toward the current safe completion; the guards refuse any commit that regresses.
