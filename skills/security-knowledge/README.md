# security-knowledge

Canonical rules for security idioms where the **popular** implementation differs from the **secure** implementation. AI models — including the ones running this plugin — default to the popular form. Each file here codifies the safe form per language, the anti-patterns to reject, and the guidance the triager/fixer/reviewer role cards pull from.

These files are **reference material loaded into the agent's context on dispatch**, not runnable skills. A sibling programmatic guard in `scripts/lib/guards.sh` enforces the rule where it is mechanically checkable.

| File | Safe primitive(s) | Guard |
|---|---|---|
| [`constant-time-compare.md`](./constant-time-compare.md) | `crypto.timingSafeEqual`, `hmac.compare_digest`, `subtle.ConstantTimeCompare`, `MessageDigest.isEqual`, `ActiveSupport::SecurityUtils.secure_compare`, `CryptographicOperations.FixedTimeEquals`, `hash_equals` | `guard_no_timing_unsafe_regression`, `guard_no_safe_primitive_removal` |

## Adding a new rule

1. Write `skills/security-knowledge/<topic>.md` following the shape of `constant-time-compare.md`: one-sentence statement of the failure mode, per-language table of safe primitives, code-block list of unsafe patterns to reject, and explicit per-role guidance for triager/fixer/reviewer.
2. If the rule is mechanically checkable, add a `guard_*` to `scripts/lib/guards.sh` and a block of cases to `scripts/test-guards.sh`. An LLM rule alone is insufficient — the agents must be physically prevented from regressing the code.
3. Reference the new file from the three role cards in `agents/` so it is loaded on dispatch.
4. Add a row to this README's table.

## Why these exist

An LLM asked to "fix" `password === input` will often emit a "fix" that still leaks timing information — sometimes via a slightly different variable-time compare, sometimes by introducing a filter that inadvertently widens the attack. The safe primitive is not the default completion because the training distribution is dominated by unsafe code. The rules in this directory push the agent toward the safe completion; the guards refuse any commit that regresses back.
